//! T09 scheduler contract, fairness, concurrency, cancellation, and failure tests.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const memory = @import("zcr_memory");
const scheduling = @import("zcr_executor");
const queues = @import("zcr_queue");
const darwin = @import("zcr_darwin");
const t = std.testing;
const backends = if (builtin.os.tag == .macos) [_]scheduling.Backend{ .bounded_threaded, .darwin_gcd } else [_]scheduling.Backend{.bounded_threaded};

fn session(n: u8, workspace: u8, task: u8) core.SessionContext {
    return .{ .session_id = .{ .uuid = @splat(n) }, .security_domain = .{ .id = 1 }, .policy_digest = @splat(0), .bound_workspace = .{ .registry_uuid = @splat(workspace), .incarnation = @splat(1) }, .bound_task = .{ .uuid = @splat(task) }, .capability_handle = .none };
}
fn budgetFor(counters: *memory.accounting.Counters) memory.Budget {
    return memory.Budget.init(9, .{ .bytes = 1024 * 1024, .fds = 100, .cpu = 100, .output_bytes = 4096 }, counters);
}
fn noop(_: *core.JobEnvelope) void {}
fn envelope(id: u64, context: core.SessionContext, cancel: *const std.atomic.Value(bool), qos: core.QosIntent) core.JobEnvelope {
    return .{ .request_id = id, .context = context, .cancel = .{ .requested = cancel }, .scratch_reservation = .{ .budget_id = 9, .bytes = 0, .fd = 0, .cpu = 0, .output = 0 }, .callback = noop, .qos_intent = qos };
}
const available: queues.Resources = .{ .cpu = 8, .non_short_cpu = 8, .io = 8 };

test "IO-004 native scheduler rejects an expired deadline without taking ownership" {
    var counters: memory.accounting.Counters = .{};
    var budget = budgetFor(&counters);
    var executor: scheduling.Executor = undefined;
    try executor.init(t.allocator, &budget, .{ .cpu_permits = 1, .io_permits = 1, .usable_physical_cpus = 1 });
    defer executor.deinit();
    var probe: Probe = .{};
    defer probe.deinit();
    var flag: std.atomic.Value(bool) = .init(false);
    const job = try makeJob(&budget, &flag, &probe, 1, .fg_short, false);
    defer rejectCleanup(&budget, job);
    job.cancel = job.cancel.withTimeout(t.io, 0);
    try t.expectError(error.DeadlineExceeded, executor.submit(job));
    try t.expectEqual(@as(u32, 0), probe.calls.load(.acquire));
    try t.expect(!flag.load(.acquire));
}

test "SC-001 foreground dependencies retain USER_INITIATED and pending work promotes" {
    try t.expectEqual(core.limits.QosClass.user_initiated, darwin.qosClass(.fg_short));
    try t.expectEqual(core.limits.QosClass.user_initiated, darwin.qosClass(.fg_bulk));
    try t.expectEqual(core.limits.QosClass.utility, darwin.qosClass(.maintenance));
    try t.expectEqual(core.limits.QosClass.background, darwin.qosClass(.idle));
    var cancelled: std.atomic.Value(bool) = .init(false);
    var dependency = envelope(1, session(1, 1, 1), &cancelled, .maintenance);
    var scan = envelope(2, session(2, 2, 2), &cancelled, .maintenance);
    var queue: queues.Queue = .{};
    try queue.push(&scan, .{ .id = 2 });
    try queue.push(&dependency, .{ .id = 1 });
    try t.expect(queue.promote(.{ .id = 1 }));
    try t.expectEqual(core.QosIntent.fg_bulk, dependency.qos_intent);
    try t.expectEqual(@as(u64, 1), queue.pop(available).?.handle.id);
    try t.expectEqual(core.limits.QosClass.user_initiated, darwin.qosClass(dependency.qos_intent));
    try t.expect(!queue.promote(.{ .id = 1 }));
}

test "SC-002 four foreground chunks then maintenance with workspace and task rotation" {
    var cancelled: std.atomic.Value(bool) = .init(false);
    var jobs: [18]core.JobEnvelope = undefined;
    var queue: queues.Queue = .{};
    // Workspace 1 floods two tasks; workspace 2 still receives equal turns.
    for (&jobs, 0..) |*job, i| {
        const ws: u8 = if (i < 8) 1 else 2;
        const task: u8 = if (i % 2 == 0) 1 else 2;
        job.* = envelope(i + 1, session(@intCast(i / 8 + 1), ws, task), &cancelled, if (i >= 16) .maintenance else .fg_bulk);
        try queue.push(job, .{ .id = i + 1 });
    }
    var fg_count: usize = 0;
    var maintenance_count: usize = 0;
    var workspaces: [4]u8 = undefined;
    var tasks: [4]u8 = undefined;
    for (0..10) |i| {
        const entry = queue.pop(available).?;
        if (entry.job.qos_intent == .maintenance) {
            maintenance_count += 1;
            try t.expectEqual(@as(usize, 4), fg_count);
            fg_count = 0;
        } else {
            fg_count += 1;
            if (i < 4) {
                workspaces[i] = entry.job.context.bound_workspace.registry_uuid[0];
                tasks[i] = entry.job.context.bound_task.uuid[0];
            }
        }
    }
    try t.expectEqual(@as(usize, 2), maintenance_count);
    try t.expectEqualSlices(u8, &.{ 1, 2, 1, 2 }, &workspaces);
    try t.expectEqualSlices(u8, &.{ 1, 1, 2, 2 }, &tasks);
}

const Gate = struct {
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    open: bool = false,
    fn wait(self: *Gate) void {
        check(std.c.pthread_mutex_lock(&self.mutex));
        while (!self.open) check(std.c.pthread_cond_wait(&self.cond, &self.mutex));
        check(std.c.pthread_mutex_unlock(&self.mutex));
    }
    fn release(self: *Gate) void {
        check(std.c.pthread_mutex_lock(&self.mutex));
        self.open = true;
        check(std.c.pthread_cond_broadcast(&self.cond));
        check(std.c.pthread_mutex_unlock(&self.mutex));
    }
    fn isOpen(self: *Gate) bool {
        check(std.c.pthread_mutex_lock(&self.mutex));
        defer check(std.c.pthread_mutex_unlock(&self.mutex));
        return self.open;
    }
    fn deinit(self: *Gate) void {
        check(std.c.pthread_cond_destroy(&self.cond));
        check(std.c.pthread_mutex_destroy(&self.mutex));
    }
};
fn check(e: std.c.E) void {
    if (e != .SUCCESS) @panic("pthread test primitive failed");
}
const Probe = struct {
    gate: ?*Gate = null,
    calls: std.atomic.Value(u32) = .init(0),
    cancelled: std.atomic.Value(u32) = .init(0),
    entered: Gate = .{},
    fn callback(job: *core.JobEnvelope) void {
        const self: *Probe = @ptrCast(@alignCast(job.userdata.?));
        self.entered.release();
        if (self.gate) |gate| gate.wait();
        if (job.cancel.isRequested()) _ = self.cancelled.fetchAdd(1, .monotonic);
        _ = self.calls.fetchAdd(1, .release);
    }
    fn deinit(self: *Probe) void {
        self.entered.deinit();
    }
};
fn makeJob(budget: *memory.Budget, cancel: *const std.atomic.Value(bool), probe: *Probe, id: u64, qos: core.QosIntent, io: bool) !*core.JobEnvelope {
    return makeWeightedJob(budget, cancel, probe, id, qos, io, 1);
}
fn makeWeightedJob(budget: *memory.Budget, cancel: *const std.atomic.Value(bool), probe: *Probe, id: u64, qos: core.QosIntent, io: bool, cpu: u8) !*core.JobEnvelope {
    const context = session(@intCast(id % 8 + 1), @intCast(id % 2 + 1), @intCast(id % 8 + 1));
    var reservation = try budget.reserve(context, .{ .scratch_bytes = 256, .fds = if (io) 1 else 0, .cpu_permits = cpu });
    errdefer budget.release(&reservation) catch unreachable;
    const job = try t.allocator.create(core.JobEnvelope);
    job.* = envelope(id, context, cancel, qos);
    job.scratch_reservation = reservation.take();
    job.callback = Probe.callback;
    job.userdata = probe;
    return job;
}
fn rejectCleanup(budget: *memory.Budget, job: *core.JobEnvelope) void {
    budget.release(&job.scratch_reservation) catch unreachable;
    t.allocator.destroy(job);
}

test "SC-002 eight mixed tasks obey CPU IO and reserved foreground permits before dispatch" {
    for (backends) |backend| {
        var counters: memory.accounting.Counters = .{};
        var budget = budgetFor(&counters);
        var executor: scheduling.Executor = undefined;
        try executor.init(t.allocator, &budget, .{ .backend = backend, .cpu_permits = 4, .io_permits = 1, .usable_physical_cpus = 8 });
        defer executor.deinit();
        var blocked: Gate = .{};
        defer blocked.deinit();
        var probe: Probe = .{ .gate = &blocked };
        defer probe.deinit();
        var cancelled: std.atomic.Value(bool) = .init(false);
        for (0..8) |i| _ = try executor.submit(try makeJob(&budget, &cancelled, &probe, i + 1, .maintenance, true));
        probe.entered.wait();
        const stats = executor.snapshot();
        try t.expectEqual(@as(u32, 1), stats.cpu_in_use);
        try t.expectEqual(@as(u32, 1), stats.io_in_use);
        try t.expectEqual(@as(usize, 7), stats.queued);
        try t.expect(stats.non_short_cpu_in_use <= 2);
        var foreground: Probe = .{};
        defer foreground.deinit();
        _ = try executor.submit(try makeJob(&budget, &cancelled, &foreground, 99, .fg_short, false));
        foreground.entered.wait();
        blocked.release();
        try executor.drain();
        try t.expectEqual(@as(u32, 8), probe.calls.load(.acquire));
        try t.expect(executor.snapshot().peak_cpu <= 4);
        try t.expect(executor.snapshot().peak_io <= 1);
        try t.expectEqual(@as(u32, if (backend == .bounded_threaded) 4 else 0), executor.snapshot().worker_threads);
        try t.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
    }
}

test "SC-003 cancellation races callback teardown and drain keeps all owned jobs alive" {
    for (backends) |backend| {
        for (0..20) |_| {
            var counters: memory.accounting.Counters = .{};
            var budget = budgetFor(&counters);
            var executor: scheduling.Executor = undefined;
            try executor.init(t.allocator, &budget, .{ .backend = backend, .cpu_permits = 2, .io_permits = 2, .usable_physical_cpus = 8 });
            defer executor.deinit();
            var gate: Gate = .{};
            defer gate.deinit();
            var probe: Probe = .{ .gate = &gate };
            defer probe.deinit();
            var cancel: std.atomic.Value(bool) = .init(false);
            for (0..16) |i| _ = try executor.submit(try makeJob(&budget, &cancel, &probe, i + 1, .fg_short, false));
            probe.entered.wait();
            const Drainer = struct {
                fn run(e: *scheduling.Executor) void {
                    e.drain() catch @panic("drain failed");
                }
            };
            const drainer = try std.Thread.spawn(.{}, Drainer.run, .{&executor});
            cancel.store(true, .release);
            gate.release();
            drainer.join();
            try t.expectEqual(@as(u32, 16), probe.calls.load(.acquire));
            try t.expectEqual(@as(u32, 16), probe.cancelled.load(.acquire));
            try t.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
            try t.expectEqual(@as(u64, 0), counters.snapshot().double_releases);
            try t.expectEqual(@as(u32, 0), executor.snapshot().cpu_in_use);
        }
    }
}

test "SC-004 nested submit uses the same bounded executor and drain detects self wait" {
    for (backends) |backend| {
        var counters: memory.accounting.Counters = .{};
        var budget = budgetFor(&counters);
        var executor: scheduling.Executor = undefined;
        try executor.init(t.allocator, &budget, .{ .backend = backend, .cpu_permits = 1, .io_permits = 1, .usable_physical_cpus = 2 });
        defer executor.deinit();
        var cancel: std.atomic.Value(bool) = .init(false);
        var child_probe: Probe = .{};
        defer child_probe.deinit();
        const child = try makeJob(&budget, &cancel, &child_probe, 2, .fg_bulk, false);
        const Nested = struct {
            executor: *scheduling.Executor,
            child: *core.JobEnvelope,
            submitted: Gate = .{},
            submit_ok: bool = false,
            deadlock_detected: bool = false,
            nested_pool_refused: bool = false,
            fn run(job: *core.JobEnvelope) void {
                const self: *@This() = @ptrCast(@alignCast(job.userdata.?));
                var nested_executor: scheduling.Executor = undefined;
                self.nested_pool_refused = if (nested_executor.init(t.allocator, self.executor.budget, self.executor.options)) |_| blk: {
                    nested_executor.deinit();
                    break :blk false;
                } else |err| err == error.ResourceExhausted;
                self.deadlock_detected = if (self.executor.drain()) |_| false else |err| err == error.WouldDeadlock;
                if (self.executor.submit(self.child)) |_| {
                    self.submit_ok = true;
                } else |_| {}
                self.submitted.release();
            }
        };
        var nested: Nested = .{ .executor = &executor, .child = child };
        defer nested.submitted.deinit();
        var parent_probe: Probe = .{};
        defer parent_probe.deinit();
        const parent = try makeJob(&budget, &cancel, &parent_probe, 1, .fg_bulk, false);
        parent.callback = Nested.run;
        parent.userdata = &nested;
        _ = try executor.submit(parent);
        nested.submitted.wait();
        try executor.drain();
        try t.expect(nested.submit_ok);
        try t.expect(nested.deadlock_detected);
        try t.expect(nested.nested_pool_refused);
        try t.expectEqual(@as(u32, 1), child_probe.calls.load(.acquire));
        try t.expectEqual(@as(u32, if (backend == .bounded_threaded) 1 else 0), executor.snapshot().worker_threads);
        try t.expectEqual(@as(u32, 1), executor.snapshot().peak_cpu);
        try t.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
    }
}

test "SC-002 queue saturation cancellation and invalid reservations preserve caller ownership" {
    var cancel: std.atomic.Value(bool) = .init(false);
    var queue: queues.Queue = .{};
    var jobs: [65]core.JobEnvelope = undefined;
    for (&jobs, 0..) |*job, i| job.* = envelope(i, session(@intCast(i / 16 + 1), 1, 1), &cancel, .fg_bulk);
    for (0..16) |i| try queue.push(&jobs[i], .{ .id = i });
    jobs[64].context = session(1, 1, 1);
    try t.expectError(error.Busy, queue.push(&jobs[64], .{ .id = 64 }));
    for (16..64) |i| try queue.push(&jobs[i], .{ .id = i });
    jobs[64].context = session(5, 1, 1);
    try t.expectError(error.Busy, queue.push(&jobs[64], .{ .id = 64 }));
    var counters: memory.accounting.Counters = .{};
    var budget = budgetFor(&counters);
    var executor: scheduling.Executor = undefined;
    try executor.init(t.allocator, &budget, .{ .cpu_permits = 1, .io_permits = 1, .usable_physical_cpus = 2 });
    defer executor.deinit();
    var probe: Probe = .{};
    defer probe.deinit();
    const job = try makeJob(&budget, &cancel, &probe, 1, .fg_bulk, false);
    defer rejectCleanup(&budget, job);
    cancel.store(true, .release);
    try t.expectError(error.Cancelled, executor.submit(job));
    try t.expect(!job.scratch_reservation.released);
    cancel.store(false, .release);
    job.scratch_reservation.budget_id = 88;
    try t.expectError(error.ResourceExhausted, executor.submit(job));
    job.scratch_reservation.budget_id = 9;
    try executor.drain();
    try t.expectError(error.Busy, executor.submit(job));
    try t.expectEqual(@as(u32, 0), probe.calls.load(.acquire));
}

test "SC-004 Darwin public callback QoS and teardown or explicit unsupported status" {
    var counters: memory.accounting.Counters = .{};
    var budget = budgetFor(&counters);
    var executor: scheduling.Executor = undefined;
    if (builtin.os.tag != .macos) {
        try t.expectError(error.Unsupported, executor.init(t.allocator, &budget, .{ .backend = .darwin_gcd, .cpu_permits = 1, .io_permits = 1, .usable_physical_cpus = 2 }));
    } else {
        try executor.init(t.allocator, &budget, .{ .backend = .darwin_gcd, .cpu_permits = 2, .io_permits = 1, .usable_physical_cpus = 8 });
        defer executor.deinit();
        var cancel: std.atomic.Value(bool) = .init(false);
        const Observation = struct {
            observed: std.atomic.Value(u32) = .init(0),
            calls: std.atomic.Value(u32) = .init(0),
            fn run(job: *core.JobEnvelope) void {
                const self: *@This() = @ptrCast(@alignCast(job.userdata.?));
                self.observed.store(darwin.currentQos() catch unreachable, .release);
                _ = self.calls.fetchAdd(1, .release);
            }
        };
        var observations: [3]Observation = @splat(.{});
        for ([_]core.QosIntent{ .fg_bulk, .maintenance, .idle }, 0..) |intent, i| {
            var probe: Probe = .{};
            defer probe.deinit();
            const job = try makeJob(&budget, &cancel, &probe, i + 1, intent, true);
            job.callback = Observation.run;
            job.userdata = &observations[i];
            _ = try executor.submit(job);
        }
        try executor.drain();
        for (&observations) |*observation| {
            try t.expectEqual(@as(u32, 1), observation.calls.load(.acquire));
            try t.expect(observation.observed.load(.acquire) != 0);
        }
        // Public Darwin QOS_CLASS_USER_INITIATED is 0x19; higher effective QoS
        // is allowed when libdispatch temporarily promotes a dependency.
        try t.expect(observations[0].observed.load(.acquire) >= 0x19);
        try t.expectEqual(@as(u32, 0), executor.snapshot().worker_threads);
        try t.expect(executor.snapshot().peak_io <= 1);
        try t.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
    }
}

test "SC-002 concurrent producers saturate bounded workers without losing jobs" {
    for (backends) |backend| {
        var counters: memory.accounting.Counters = .{};
        var budget = budgetFor(&counters);
        var executor: scheduling.Executor = undefined;
        try executor.init(t.allocator, &budget, .{ .backend = backend, .cpu_permits = 3, .io_permits = 2, .usable_physical_cpus = 8 });
        defer executor.deinit();
        var cancel: std.atomic.Value(bool) = .init(false);
        var hold: Gate = .{};
        defer hold.deinit();
        var starters: [3]Probe = @splat(.{});
        defer for (&starters) |*probe| probe.deinit();
        for (&starters, 0..) |*probe, i| {
            probe.gate = &hold;
            _ = try executor.submit(try makeJob(&budget, &cancel, probe, i + 1, .fg_short, false));
        }
        for (&starters) |*probe| probe.entered.wait();
        try t.expectEqual(@as(u32, 3), executor.snapshot().cpu_in_use);
        var probe: Probe = .{};
        defer probe.deinit();
        const Producer = struct {
            executor: *scheduling.Executor,
            budget: *memory.Budget,
            cancel: *const std.atomic.Value(bool),
            probe: *Probe,
            failures: std.atomic.Value(u32) = .init(0),
            fn run(self: *@This(), n: u64) void {
                for (0..32) |i| {
                    const job = makeJob(self.budget, self.cancel, self.probe, n * 32 + i, if (i % 2 == 0) .fg_short else .maintenance, i % 3 == 0) catch {
                        _ = self.failures.fetchAdd(1, .monotonic);
                        return;
                    };
                    while (true) {
                        if (self.executor.submit(job)) |_| break else |err| {
                            if (err != error.Busy) {
                                _ = self.failures.fetchAdd(1, .monotonic);
                                rejectCleanup(self.budget, job);
                                return;
                            }
                            std.Thread.yield() catch {};
                        }
                    }
                }
            }
        };
        var producer: Producer = .{ .executor = &executor, .budget = &budget, .cancel = &cancel, .probe = &probe };
        var threads: [8]std.Thread = undefined;
        for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Producer.run, .{ &producer, i + 1 });
        hold.release();
        for (threads) |thread| thread.join();
        try executor.drain();
        try t.expectEqual(@as(u32, 0), producer.failures.load(.acquire));
        try t.expectEqual(@as(u32, 256), probe.calls.load(.acquire));
        const snapshot = executor.snapshot();
        try t.expectEqual(@as(u32, 3), snapshot.peak_cpu);
        try t.expect(snapshot.peak_io <= 2);
        try t.expectEqual(@as(u64, 259), snapshot.completed);
        try t.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
    }
}

test "SC-002 executor full queue rejects without consuming its reservation" {
    var counters: memory.accounting.Counters = .{};
    var budget = budgetFor(&counters);
    var executor: scheduling.Executor = undefined;
    try executor.init(t.allocator, &budget, .{ .cpu_permits = 1, .io_permits = 1, .usable_physical_cpus = 2 });
    defer executor.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var hold: Gate = .{};
    defer hold.deinit();
    var probe: Probe = .{ .gate = &hold };
    defer probe.deinit();
    _ = try executor.submit(try makeJob(&budget, &cancel, &probe, 1, .fg_short, false));
    probe.entered.wait();
    for (0..64) |i| _ = try executor.submit(try makeJob(&budget, &cancel, &probe, i + 2, .fg_short, false));
    const rejected = try makeJob(&budget, &cancel, &probe, 99, .fg_short, false);
    defer rejectCleanup(&budget, rejected);
    try t.expectError(error.Busy, executor.submit(rejected));
    try t.expect(!rejected.scratch_reservation.released);
    try t.expectEqual(@as(usize, 64), executor.snapshot().queued);
    hold.release();
    try executor.drain();
    try t.expectEqual(@as(u32, 65), probe.calls.load(.acquire));
    try t.expectEqual(@as(u64, 1), counters.snapshot().active_reservations);
}

test "SC-001 idle work waits behind blocked dependencies and impossible permits reject" {
    var cancel: std.atomic.Value(bool) = .init(false);
    var queue: queues.Queue = .{};
    var foreground = envelope(1, session(1, 1, 1), &cancel, .fg_bulk);
    foreground.scratch_reservation.fd = 1;
    var idle = envelope(2, session(2, 2, 2), &cancel, .idle);
    try queue.push(&idle, .{ .id = 2 });
    try queue.push(&foreground, .{ .id = 1 });
    try t.expectEqual(@as(?queues.Entry, null), queue.pop(.{ .cpu = 1, .non_short_cpu = 1, .io = 0 }));
    try t.expectEqual(@as(u64, 1), queue.pop(available).?.handle.id);
    try t.expectEqual(@as(u64, 2), queue.pop(available).?.handle.id);
    var counters: memory.accounting.Counters = .{};
    var budget = budgetFor(&counters);
    var executor: scheduling.Executor = undefined;
    try t.expectError(error.InvalidArgument, executor.init(t.allocator, &budget, .{ .cpu_permits = 9, .io_permits = 2, .usable_physical_cpus = 32 }));
    try t.expectError(error.InvalidArgument, executor.init(t.allocator, &budget, .{ .cpu_permits = 3, .io_permits = 2, .usable_physical_cpus = 2 }));
    try t.expectError(error.InvalidArgument, executor.init(t.allocator, &budget, .{ .cpu_permits = 1, .io_permits = 0, .usable_physical_cpus = 2 }));
    try executor.init(t.allocator, &budget, .{ .cpu_permits = 1, .io_permits = 1, .usable_physical_cpus = 2 });
    defer executor.deinit();
    var probe: Probe = .{};
    defer probe.deinit();
    const job = try makeJob(&budget, &cancel, &probe, 1, .fg_bulk, false);
    defer rejectCleanup(&budget, job);
    const saved = job.scratch_reservation.cpu;
    job.scratch_reservation.cpu = 2;
    try t.expectError(error.ResourceExhausted, executor.submit(job));
    job.scratch_reservation.cpu = saved;
}

test "SC-004 partial worker creation failure joins started workers and permits retry" {
    var counters: memory.accounting.Counters = .{};
    var budget = budgetFor(&counters);
    for (0..3) |fail_after| {
        var executor: scheduling.Executor = undefined;
        try t.expectError(error.ResourceExhausted, executor.init(t.allocator, &budget, .{ .cpu_permits = 3, .io_permits = 2, .usable_physical_cpus = 8, .fail_spawn_after = @intCast(fail_after) }));
        try t.expectEqual(@as(u32, 0), executor.thread_count);
        try executor.init(t.allocator, &budget, .{ .cpu_permits = 1, .io_permits = 1, .usable_physical_cpus = 2 });
        defer executor.deinit();
        var cancel: std.atomic.Value(bool) = .init(false);
        var probe: Probe = .{};
        defer probe.deinit();
        _ = try executor.submit(try makeJob(&budget, &cancel, &probe, 1, .fg_bulk, false));
        try executor.drain();
        try t.expectEqual(@as(u32, 1), probe.calls.load(.acquire));
    }
    try t.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
}

test "SC-003 callback IO failure returns scratch and execution permits before idle barrier" {
    for (backends) |backend| {
        var counters: memory.accounting.Counters = .{};
        var budget = budgetFor(&counters);
        var executor: scheduling.Executor = undefined;
        try executor.init(t.allocator, &budget, .{ .backend = backend, .cpu_permits = 1, .io_permits = 1, .usable_physical_cpus = 2 });
        defer executor.deinit();
        var cancel: std.atomic.Value(bool) = .init(false);
        var probe: Probe = .{};
        defer probe.deinit();
        var failed = false;
        const Failure = struct {
            fn run(job: *core.JobEnvelope) void {
                const result: *bool = @ptrCast(@alignCast(job.userdata.?));
                var buffer: [1]u8 = undefined;
                result.* = std.c.read(-1, &buffer, buffer.len) == -1;
            }
        };
        const job = try makeJob(&budget, &cancel, &probe, 1, .fg_short, true);
        job.callback = Failure.run;
        job.userdata = &failed;
        _ = try executor.submit(job);
        try executor.waitIdle();
        try t.expect(failed);
        try t.expectEqual(@as(u32, 0), executor.snapshot().cpu_in_use);
        try t.expectEqual(@as(u32, 0), executor.snapshot().io_in_use);
        try t.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
        // waitIdle does not close admission; a subsequent job still executes.
        _ = try executor.submit(try makeJob(&budget, &cancel, &probe, 2, .fg_short, false));
        try executor.drain();
        try t.expectEqual(@as(u32, 1), probe.calls.load(.acquire));
    }
}

fn waitForGate(gate: *Gate) !void {
    for (0..2000) |_| {
        if (gate.isOpen()) return;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedGateProgress;
}
fn waitForCompleted(executor: *scheduling.Executor, count: u64) !void {
    for (0..2000) |_| {
        if (executor.snapshot().completed >= count) return;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedCompletionProgress;
}

test "SC-002 R1 multi-permit waiter progresses under staggered foreground refill" {
    for (backends) |backend| {
        for ([_]core.QosIntent{ .maintenance, .fg_bulk, .fg_short }) |waiting_intent| {
            var counters: memory.accounting.Counters = .{};
            var budget = budgetFor(&counters);
            var cancel: std.atomic.Value(bool) = .init(false);
            var holds: [10]Gate = @splat(.{});
            defer for (&holds) |*hold| hold.deinit();
            var foreground: [10]Probe = @splat(.{});
            defer for (&foreground) |*probe| probe.deinit();
            for (&foreground, &holds) |*probe, *hold| probe.gate = hold;
            var waiter_hold: Gate = .{};
            defer waiter_hold.deinit();
            var waiter: Probe = .{ .gate = &waiter_hold };
            defer waiter.deinit();
            var executor: scheduling.Executor = undefined;
            try executor.init(t.allocator, &budget, .{ .backend = backend, .cpu_permits = 4, .io_permits = 2, .usable_physical_cpus = 8 });
            defer executor.deinit();
            // Also unwind blocked callbacks when a regression assertion fails.
            defer {
                for (&holds) |*hold| hold.release();
                waiter_hold.release();
            }
            for (0..2) |i| _ = try executor.submit(try makeJob(&budget, &cancel, &foreground[i], i + 1, .fg_bulk, false));
            for (0..2) |i| try waitForGate(&foreground[i].entered);
            _ = try executor.submit(try makeWeightedJob(&budget, &cancel, &waiter, 100, waiting_intent, false, if (waiting_intent == .fg_short) 4 else 2));
            for (2..foreground.len) |i| _ = try executor.submit(try makeJob(&budget, &cancel, &foreground[i], i + 1, .fg_bulk, false));

            var released: [10]bool = @splat(false);
            // There is always more queued one-permit work. Terminate individual
            // foreground callbacks one at a time, never release the whole pair.
            // A fair turn must reserve the multi-permit grant within four service
            // turns plus the two foreground chunks already in flight.
            for (0..6) |completed| {
                if (waiter.entered.isOpen()) break;
                var next: ?usize = null;
                for (0..2000) |_| {
                    for (&foreground, 0..) |*probe, i| {
                        if (!released[i] and probe.entered.isOpen()) {
                            next = i;
                            break;
                        }
                    }
                    if (next != null or waiter.entered.isOpen()) break;
                    try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
                }
                if (waiter.entered.isOpen()) break;
                const index = next orelse return error.TestExpectedForegroundProgress;
                released[index] = true;
                holds[index].release();
                try waitForCompleted(&executor, completed + 1);
            }
            try waitForGate(&waiter.entered);
            const active = executor.snapshot();
            try t.expectEqual(@as(u32, if (waiting_intent == .fg_short) 0 else 2), active.non_short_cpu_in_use);
            try t.expect(active.peak_cpu <= 4);
            try t.expect(active.queued <= core.limits.values.global_queue);
            for (&holds) |*hold| hold.release();
            waiter_hold.release();
            try executor.drain();
            try t.expectEqual(@as(u32, 1), waiter.calls.load(.acquire));
            for (&foreground) |*probe| try t.expectEqual(@as(u32, 1), probe.calls.load(.acquire));
            try t.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
        }
    }
}

test "SC-001 R2 idle dispatch waits for active foreground callback completion" {
    for (backends) |backend| {
        for ([_]core.QosIntent{ .fg_short, .fg_bulk }) |foreground_intent| {
            var counters: memory.accounting.Counters = .{};
            var budget = budgetFor(&counters);
            var cancel: std.atomic.Value(bool) = .init(false);
            var hold: Gate = .{};
            defer hold.deinit();
            var foreground: Probe = .{ .gate = &hold };
            defer foreground.deinit();
            var idle: Probe = .{};
            defer idle.deinit();
            var executor: scheduling.Executor = undefined;
            try executor.init(t.allocator, &budget, .{ .backend = backend, .cpu_permits = 4, .io_permits = 2, .usable_physical_cpus = 8 });
            defer executor.deinit();
            defer hold.release();
            _ = try executor.submit(try makeJob(&budget, &cancel, &foreground, 1, foreground_intent, false));
            try waitForGate(&foreground.entered);
            _ = try executor.submit(try makeJob(&budget, &cancel, &idle, 2, .idle, false));
            // submit/pump finish under the same mutex read by snapshot: this
            // asserts dispatch state without depending on callback timing.
            const while_foreground_active = executor.snapshot();
            try t.expectEqual(@as(usize, 1), while_foreground_active.queued);
            try t.expectEqual(@as(u32, 1), while_foreground_active.cpu_in_use);
            try t.expect(!idle.entered.isOpen());
            hold.release();
            try executor.drain();
            try t.expectEqual(@as(u32, 1), foreground.calls.load(.acquire));
            try t.expectEqual(@as(u32, 1), idle.calls.load(.acquire));
            try t.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
        }
    }
}
