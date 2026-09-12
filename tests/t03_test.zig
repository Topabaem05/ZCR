//! T03 tests: budgets, reservation-bound allocation, request arenas and
//! admission (ME-001, ME-002, ME-003, ME-007).
//!
//! Run: `zig build test -Dtest-group=memory`.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const memory = @import("zcr_memory");
const admission = @import("zcr_admission");

const testing = std.testing;
const io = testing.io;
const KiB = core.limits.KiB;
const MiB = core.limits.MiB;
const GiB = core.limits.GiB;

const eight_gib_profile = &core.limits.memory_profiles[0];

fn session(n: u8) core.SessionContext {
    return .{
        .session_id = .{ .uuid = @splat(n) },
        .security_domain = .{ .id = 1 },
        .policy_digest = @splat(0),
        .bound_workspace = .{ .registry_uuid = @splat(1), .incarnation = @splat(2) },
        .bound_task = .{ .uuid = @splat(3) },
        .capability_handle = .none,
    };
}

fn inflightBudget(counters: *memory.accounting.Counters) memory.Budget {
    return memory.Budget.init(1, memory.capsFor(eight_gib_profile, .inflight), counters);
}

// ------------------------------------------------------------------ ME-003

test "ME-003 oversized requests are refused at admission and the tracked cap stays untouched" {
    var counters: memory.accounting.Counters = .{};
    var budget = inflightBudget(&counters);
    try testing.expectEqual(@as(u64, 32 * MiB), budget.caps.bytes);

    var evictions: u32 = 0;
    const Counting = struct {
        fn evict(context: *anyopaque, bytes_needed: u64) u64 {
            _ = bytes_needed;
            const count: *u32 = @ptrCast(@alignCast(context));
            count.* += 1;
            return 0;
        }
    };
    var gate = admission.Admission.init(&budget, .{ .context = &evictions, .evict_fn = Counting.evict });

    // An 8 MiB patch needs frame + decoded replacements + old + new bytes: more than the 32 MiB in-flight share.
    const patch_cost = try admission.estimate(.{
        .operation = .patch,
        .frame_bytes = 16 * MiB,
        .decoded_bytes = 8 * MiB,
        .file_bytes = 8 * MiB,
        .output_bytes = 256 * KiB,
    });
    try testing.expect((try patch_cost.totalBytes()) > 32 * MiB);
    try testing.expectError(error.ResourceExhausted, gate.reserve(session(1), patch_cost));
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
    try testing.expectEqual(@as(u32, 0), evictions); // a request that can never fit is not worth evicting for
    try testing.expectEqual(@as(u32, 0), gate.inFlight());

    // Contract limits are argument errors before any budget is consulted.
    try testing.expectError(error.InvalidArgument, admission.estimate(.{ .operation = .patch, .frame_bytes = 1 * KiB, .file_bytes = 9 * MiB, .output_bytes = 1 * KiB }));
    try testing.expectError(error.InvalidArgument, admission.estimate(.{ .operation = .read, .frame_bytes = 16 * MiB + 1, .output_bytes = 1 * KiB }));
    try testing.expectError(error.InvalidArgument, admission.estimate(.{ .operation = .batch_read, .frame_bytes = 1 * KiB, .items = 33, .output_bytes = 1 * KiB }));
    try testing.expectError(error.InvalidArgument, admission.estimate(.{ .operation = .batch_read, .frame_bytes = 1 * KiB, .items = 8, .output_bytes = 2 * MiB + 1 }));

    // A batch reserves one shared output budget, not one per item.
    const batch = try admission.estimate(.{ .operation = .batch_read, .frame_bytes = 4 * KiB, .items = 32, .output_bytes = 2 * MiB, .worker_concurrency = 2 });
    try testing.expectEqual(@as(u64, 2 * MiB), batch.output_bytes);
    try testing.expect(batch.scratch_bytes <= 2 * core.limits.values.chunk_bytes);
}

test "ME-003 output beyond the budget's output share is refused" {
    var counters: memory.accounting.Counters = .{};
    var budget = memory.Budget.init(7, .{ .bytes = 64 * MiB, .fds = 32, .cpu = 4, .output_bytes = 1 * MiB }, &counters);
    try testing.expectError(error.OutputBudgetExceeded, budget.reserve(session(1), .{ .output_bytes = 2 * MiB }));
    try testing.expectEqual(@as(u64, 0), budget.usage().output_bytes);
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
}

// Coverage-only boundaries: the byte-cap hammer cannot independently exhaust these resources.
fn expectIsolatedReservationCap(comptime dimension: enum { fds, cpu }) !void {
    const is_fd = dimension == .fds;
    var counters: memory.accounting.Counters = .{};
    var budget = memory.Budget.init(8, .{
        .bytes = 64 * MiB,
        .fds = if (is_fd) 3 else 32,
        .cpu = if (is_fd) 32 else 3,
        .output_bytes = 32 * MiB,
    }, &counters);
    const empty: memory.Caps = .{ .bytes = 0, .fds = 0, .cpu = 0, .output_bytes = 0 };
    const one: core.ResourceCost = .{ .input_bytes = 1 * KiB, .output_bytes = 1 * KiB, .fds = 1, .cpu_permits = 1 };
    var two = one;
    var oversized = one;
    if (is_fd) {
        two.fds = 2;
        oversized.fds = 4;
    } else {
        two.cpu_permits = 2;
        oversized.cpu_permits = 4;
    }

    try testing.expectError(error.ResourceExhausted, budget.reserve(session(1), oversized));
    try testing.expectEqualDeep(empty, budget.usage());
    try testing.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);

    var first = try budget.reserve(session(1), two);
    defer if (!first.released) budget.release(&first) catch @panic("first reservation cleanup failed");
    var second = try budget.reserve(session(2), one);
    defer if (!second.released) budget.release(&second) catch @panic("second reservation cleanup failed");
    const at_limit: memory.Caps = .{
        .bytes = 4 * KiB,
        .fds = if (is_fd) 3 else 2,
        .cpu = if (is_fd) 2 else 3,
        .output_bytes = 2 * KiB,
    };
    try testing.expectEqualDeep(at_limit, budget.usage());
    try testing.expectEqual(@as(u64, 2), counters.snapshot().active_reservations);

    // This otherwise-affordable request exceeds only the selected cumulative cap.
    const counters_at_limit = counters.snapshot();
    try testing.expectError(error.ResourceExhausted, budget.reserve(session(3), one));
    try testing.expectEqualDeep(at_limit, budget.usage());
    try testing.expectEqualDeep(counters_at_limit, counters.snapshot());

    try budget.release(&first);
    try testing.expectEqualDeep(memory.Caps{ .bytes = 2 * KiB, .fds = 1, .cpu = 1, .output_bytes = 1 * KiB }, budget.usage());
    try testing.expectEqual(@as(u64, 1), counters.snapshot().active_reservations);
    var replacement = try budget.reserve(session(3), two);
    defer if (!replacement.released) budget.release(&replacement) catch @panic("replacement reservation cleanup failed");
    try testing.expectEqualDeep(at_limit, budget.usage());

    try budget.release(&second);
    try budget.release(&replacement);
    try testing.expectEqualDeep(empty, budget.usage());
    try testing.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
    try testing.expectEqual(@as(u64, 0), counters.snapshot().double_releases);
}

test "ME-003 FD reservations grant the exact cap, reject exhaustion and restore capacity" {
    try expectIsolatedReservationCap(.fds);
}

test "ME-003 CPU reservations grant the exact cap, reject exhaustion and restore capacity" {
    try expectIsolatedReservationCap(.cpu);
}

const HammerContext = struct {
    budget: *memory.Budget,
    cost: core.ResourceCost,
    successes: std.atomic.Value(u64) = .init(0),
    refusals: std.atomic.Value(u64) = .init(0),
    violations: std.atomic.Value(u64) = .init(0),

    fn run(ctx: *HammerContext, id: u8) void {
        var i: usize = 0;
        while (i < 500) : (i += 1) {
            var r = ctx.budget.reserve(session(id), ctx.cost) catch {
                _ = ctx.refusals.fetchAdd(1, .monotonic);
                continue;
            };
            if (ctx.budget.usage().bytes > ctx.budget.caps.bytes) _ = ctx.violations.fetchAdd(1, .monotonic);
            _ = ctx.successes.fetchAdd(1, .monotonic);
            ctx.budget.release(&r) catch {
                _ = ctx.violations.fetchAdd(1, .monotonic);
            };
        }
    }
};

test "ME-003 concurrent reservations never exceed the hard tracked cap" {
    var counters: memory.accounting.Counters = .{};
    var budget = inflightBudget(&counters);
    var ctx: HammerContext = .{ .budget = &budget, .cost = .{ .input_bytes = 12 * MiB, .output_bytes = 256 * KiB, .fds = 1 } };

    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, HammerContext.run, .{ &ctx, @as(u8, @intCast(i + 1)) });
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u64, 0), ctx.violations.load(.acquire));
    try testing.expect(ctx.successes.load(.acquire) > 0);
    try testing.expect(budget.peakBytes() <= budget.caps.bytes);
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
    try testing.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
}

test "ME-003 reservation-bound allocation never falls back to an untracked allocator" {
    var counters: memory.accounting.Counters = .{};
    var budget = memory.Budget.init(2, .{ .bytes = 64 * KiB, .fds = 4, .cpu = 1, .output_bytes = 64 * KiB }, &counters);
    var reservation = try budget.reserve(session(1), .{ .scratch_bytes = 64 * KiB });

    var child = testing.FailingAllocator.init(testing.allocator, .{});
    var reserved = memory.ReservedAllocator.init(child.allocator(), &reservation, &counters, null);
    const a = reserved.allocator();

    try testing.expectError(error.OutOfMemory, a.alloc(u8, 65 * KiB));
    try testing.expectEqual(@as(usize, 0), child.alloc_index); // refused before touching any allocator

    const first = try a.alloc(u8, 60 * KiB);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 8 * KiB));
    try testing.expectEqual(@as(usize, 1), child.alloc_index);
    try testing.expect(reserved.liveBytes() <= reservation.bytes);
    a.free(first);
    try testing.expectEqual(@as(u64, 0), reserved.liveBytes());

    try budget.release(&reservation);
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
}

const HeldEvictor = struct {
    budget: *memory.Budget,
    held: ?core.Reservation,
    calls: u32 = 0,

    fn evict(context: *anyopaque, bytes_needed: u64) u64 {
        _ = bytes_needed;
        const self: *HeldEvictor = @ptrCast(@alignCast(context));
        self.calls += 1;
        var held = self.held orelse return 0;
        const freed = held.bytes;
        self.budget.release(&held) catch return 0;
        self.held = null;
        return freed;
    }
};

test "ME-003 admission evicts once and then reports exhaustion" {
    var counters: memory.accounting.Counters = .{};
    var budget = inflightBudget(&counters);

    // A cache entry holds most of the budget.
    var cache: HeldEvictor = .{ .budget = &budget, .held = try budget.reserve(session(9), .{ .parser_bytes = 30 * MiB }) };
    var gate = admission.Admission.init(&budget, .{ .context = &cache, .evict_fn = HeldEvictor.evict });
    var r = try gate.reserve(session(1), .{ .input_bytes = 8 * MiB });
    try testing.expectEqual(@as(u32, 1), cache.calls);
    try gate.release(session(1), &r);

    // Nothing left to evict: exactly one retry, then E_RESOURCE.
    var filler = try budget.reserve(session(9), .{ .parser_bytes = 30 * MiB });
    try testing.expectError(error.ResourceExhausted, gate.reserve(session(1), .{ .input_bytes = 8 * MiB }));
    try testing.expectEqual(@as(u32, 2), cache.calls);
    try testing.expectEqual(@as(u32, 0), gate.inFlight());
    try budget.release(&filler);
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
}

test "ME-003 admission bounds in-flight requests per session and globally" {
    var counters: memory.accounting.Counters = .{};
    var budget = memory.Budget.init(3, .{ .bytes = 1 * GiB, .fds = 1024, .cpu = 255, .output_bytes = 1 * GiB }, &counters);
    var gate = admission.Admission.init(&budget, null);
    const per_session = core.limits.values.session_queue;
    const global = core.limits.values.global_queue;

    var held: [64]core.Reservation = undefined;
    var count: usize = 0;
    for (0..global / per_session) |s| {
        for (0..per_session) |_| {
            held[count] = try gate.reserve(session(@intCast(s + 1)), .{ .input_bytes = 1 * KiB });
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, global), count);
    try testing.expectError(error.Busy, gate.reserve(session(1), .{ .input_bytes = 1 * KiB })); // session full
    try testing.expectError(error.Busy, gate.reserve(session(50), .{ .input_bytes = 1 * KiB })); // global full

    try gate.release(session(2), &held[per_session]);
    try testing.expectError(error.Busy, gate.reserve(session(1), .{ .input_bytes = 1 * KiB }));
    var again = try gate.reserve(session(2), .{ .input_bytes = 1 * KiB });
    try gate.release(session(2), &again);

    for (held[0..count], 0..) |*r, i| {
        if (i == per_session) continue;
        try gate.release(session(@intCast(i / per_session + 1)), r);
    }
    try testing.expectEqual(@as(u32, 0), gate.inFlight());
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
}

// ------------------------------------------------------------------ ME-001

/// A write pipeline shaped like zcr_patch: decode input, read the original,
/// build new bytes, write a temp file, then publish by rename (commit point).
const Pipeline = struct {
    dir: std.Io.Dir,
    gate: *admission.Admission,
    budget: *memory.Budget,
    counters: *memory.accounting.Counters,

    fn run(p: Pipeline, fault: *memory.FaultPlan) !void {
        const cost = try admission.estimate(.{ .operation = .patch, .frame_bytes = 4 * KiB, .decoded_bytes = 1 * KiB, .file_bytes = 64 * KiB, .output_bytes = 4 * KiB });
        var reservation = try p.gate.reserve(session(1), cost);
        var request: memory.RequestArena = undefined;
        request.init(testing.allocator, &reservation, p.counters, fault);
        defer _ = request.release(p.budget, &reservation) catch |err| std.debug.panic("release failed: {t}", .{err});
        defer p.gate.releaseSlot(session(1));
        const a = request.allocator();

        // Phase: decode.
        const frame = try a.alloc(u8, 4 * KiB);
        @memset(frame, 'x');
        const replacement = try a.dupe(u8, "patched\n");

        // Phase: read original.
        const original = try p.dir.readFileAlloc(io, "target.txt", a, .limited(64 * KiB));

        // Phase: build.
        const new_bytes = try std.mem.concat(a, u8, &.{ replacement, original });

        // Phase: write temp (not visible as target until rename).
        const temp_name = try std.fmt.allocPrint(a, ".target.txt.{d}.tmp", .{new_bytes.len});
        errdefer p.dir.deleteFile(io, temp_name) catch {};
        try p.dir.writeFile(io, .{ .sub_path = temp_name, .data = new_bytes });
        _ = try a.alloc(u8, 1 * KiB); // receipt buffer, still before the commit point

        // Commit point.
        try p.dir.rename(temp_name, p.dir, "target.txt", io);
    }
};

test "ME-001 an Nth allocation failure in any phase leaves the original and returns every reservation" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var counters: memory.accounting.Counters = .{};
    var budget = inflightBudget(&counters);
    var gate = admission.Admission.init(&budget, null);
    const pipeline: Pipeline = .{ .dir = tmp.dir, .gate = &gate, .budget = &budget, .counters = &counters };
    const original = "original contents\n";

    // Count the allocations of a clean run.
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = original });
    var probe: memory.FaultPlan = .{};
    try pipeline.run(&probe);
    const total = probe.seen.load(.acquire);
    try testing.expect(total >= 5);

    var failures: u64 = 0;
    for (1..total + 1) |n| {
        try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = original });
        var fault: memory.FaultPlan = .{ .fail_at = n };
        pipeline.run(&fault) catch |err| {
            try testing.expect(err == error.OutOfMemory);
            failures += 1;
        };
        const now = try tmp.dir.readFileAlloc(io, "target.txt", testing.allocator, .limited(1 * MiB));
        defer testing.allocator.free(now);
        try testing.expectEqualStrings(original, now);
        try testing.expectEqual(@as(u64, 1), fault.injected.load(.acquire));
        try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
        try testing.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
        try testing.expectEqual(@as(u64, 0), counters.snapshot().live_bytes);
        try testing.expectEqual(@as(u32, 0), gate.inFlight());
        var it = tmp.dir.iterate();
        while (try it.next(io)) |entry| try testing.expectEqualStrings("target.txt", entry.name);
    }
    try testing.expectEqual(total, failures);

    // After all injected failures the next normal request succeeds.
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = original });
    var clean: memory.FaultPlan = .{};
    try pipeline.run(&clean);
    const after = try tmp.dir.readFileAlloc(io, "target.txt", testing.allocator, .limited(1 * MiB));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("patched\n" ++ original, after);
}

// ------------------------------------------------------------------ ME-002

test "ME-002 a request arena is not freed while a child is pending, even after cancellation" {
    var counters: memory.accounting.Counters = .{};
    var budget = inflightBudget(&counters);
    var reservation = try budget.reserve(session(1), .{ .scratch_bytes = 1 * MiB });

    var request: memory.RequestArena = undefined;
    request.init(testing.allocator, &reservation, &counters, null);
    const child = try request.beginChild();
    const buffer = try request.allocator().alloc(u8, 4 * KiB);
    @memset(buffer, 0xA5);

    request.requestCancel();
    try testing.expect(request.isCancelRequested());
    try testing.expectError(error.Cancelled, request.beginChild());
    try testing.expectError(error.ChildrenPending, request.release(&budget, &reservation));
    try testing.expect(!reservation.released);
    try testing.expect(budget.usage().bytes > 0);

    // The pending child still owns valid memory.
    @memset(buffer, 0x5A);
    for (buffer) |byte| try testing.expectEqual(@as(u8, 0x5A), byte);

    request.endChild(child);
    const report = try request.release(&budget, &reservation);
    try testing.expect(report.capacity_before_bytes >= 4 * KiB);
    try testing.expect(reservation.released);
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
    try testing.expectEqual(@as(u64, 0), counters.snapshot().live_bytes);
}

const ChildThread = struct {
    request: *memory.RequestArena,
    token: memory.ChildToken,
    buffer: []u8,
    go: std.atomic.Value(bool) = .init(false),
    // Published by go: setup/assertion failure can join without using a possibly released buffer.
    write_buffer: bool = false,

    fn run(ctx: *ChildThread) void {
        while (!ctx.go.load(.acquire)) std.Thread.yield() catch {};
        if (ctx.write_buffer) for (0..64) |round| {
            @memset(ctx.buffer, @intCast(round));
        };
        ctx.request.endChild(ctx.token);
    }
};

test "ME-002 release waits for a child on another thread to drain" {
    var counters: memory.accounting.Counters = .{};
    var budget = inflightBudget(&counters);
    var reservation = try budget.reserve(session(1), .{ .scratch_bytes = 1 * MiB });
    var request: memory.RequestArena = undefined;
    request.init(testing.allocator, &reservation, &counters, null);
    defer if (!reservation.released) {
        _ = request.release(&budget, &reservation) catch @panic("request cleanup failed");
    };

    const buffer = try request.allocator().alloc(u8, 64 * KiB);
    const token = try request.beginChild();
    var child_owned_by_test = true;
    defer if (child_owned_by_test) request.endChild(token);
    var ctx: ChildThread = .{ .request = &request, .token = token, .buffer = buffer };
    const thread = try std.Thread.spawn(.{}, ChildThread.run, .{&ctx});
    child_owned_by_test = false;
    defer {
        ctx.go.store(true, .release);
        thread.join();
    }
    request.requestCancel();

    // The child cannot drain before this refusal, regardless of thread scheduling.
    try testing.expectError(error.ChildrenPending, request.release(&budget, &reservation));
    try testing.expectEqual(@as(u32, 1), request.pendingChildren());
    try testing.expect(!reservation.released);
    try testing.expect(budget.usage().bytes > 0);
    try testing.expect(counters.snapshot().live_bytes > 0);

    ctx.write_buffer = true;
    ctx.go.store(true, .release);
    for (0..2000) |_| {
        _ = request.release(&budget, &reservation) catch |err| switch (err) {
            error.ChildrenPending => {
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
                continue;
            },
            else => return err,
        };
        break;
    } else return error.TestExpectedChildDrain;
    try testing.expectEqual(@as(u32, 0), request.pendingChildren());
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
    try testing.expectEqual(@as(u64, 0), counters.snapshot().active_reservations);
    try testing.expectEqual(@as(u64, 0), counters.snapshot().live_bytes);
}

// ------------------------------------------------------------------ ME-007

/// Read requests with a child job cancelled every third cycle.
fn readCancelCycles(child: std.mem.Allocator, counters: *memory.accounting.Counters, budget: *memory.Budget, gate: *admission.Admission, first: usize, count: usize) !void {
    const cost = try admission.estimate(.{ .operation = .read, .frame_bytes = 2 * KiB, .output_bytes = 64 * KiB });
    for (first..first + count) |i| {
        const who = session(@intCast(i % 4 + 1));
        var reservation = try gate.reserve(who, cost);
        var request: memory.RequestArena = undefined;
        request.init(child, &reservation, counters, null);
        _ = try request.allocator().alloc(u8, 16 * KiB);
        _ = try request.allocator().alloc(u8, 3 * KiB + (i % 97));
        if (i % 3 == 0) {
            const token = try request.beginChild();
            request.requestCancel();
            try testing.expectError(error.ChildrenPending, request.release(budget, &reservation));
            request.endChild(token);
        }
        _ = try request.release(budget, &reservation);
        gate.releaseSlot(who);
    }
}

test "ME-007 10k read and cancel cycles return to idle without leak growth" {
    var counters: memory.accounting.Counters = .{};
    var budget = inflightBudget(&counters);
    var gate = admission.Admission.init(&budget, null);

    // Leak detection: testing.allocator fails the test on any unreturned allocation.
    try readCancelCycles(testing.allocator, &counters, &budget, &gate, 0, 1_000);
    const peak_after_1k = budget.peakBytes();
    try readCancelCycles(testing.allocator, &counters, &budget, &gate, 1_000, 9_000);

    const snapshot = counters.snapshot();
    try testing.expectEqual(@as(u64, 0), snapshot.live_bytes);
    try testing.expectEqual(@as(u64, 0), snapshot.active_reservations);
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
    try testing.expectEqual(@as(u32, 0), gate.inFlight());
    try testing.expectEqual(peak_after_1k, budget.peakBytes());
    try testing.expectEqual(snapshot.allocations, snapshot.frees);

    // Footprint observation with a production child allocator. testing.allocator keeps its
    // own debug bookkeeping (about 15 MiB over 9k cycles here), so it cannot show growth.
    if (builtin.os.tag == .macos) {
        try readCancelCycles(std.heap.smp_allocator, &counters, &budget, &gate, 0, 1_000);
        const before = memory.accounting.processFootprint().physical_bytes.?;
        try readCancelCycles(std.heap.smp_allocator, &counters, &budget, &gate, 1_000, 9_000);
        const after = memory.accounting.processFootprint().physical_bytes.?;
        try testing.expect(after <= before + 1 * MiB);
        try testing.expectEqual(@as(u64, 0), counters.snapshot().live_bytes);
    }

    // The next normal request succeeds.
    const cost = try admission.estimate(.{ .operation = .read, .frame_bytes = 2 * KiB, .output_bytes = 64 * KiB });
    var next = try gate.reserve(session(1), cost);
    try gate.release(session(1), &next);
}

// ------------------------------------------------------------------ profiles and accounting

test "T03 profiles map RAM to caps and budgets release exactly once" {
    try testing.expectEqual(@as(?u32, 8), memory.profileForRam(8 * GiB).ram_upper_gib);
    try testing.expectEqual(@as(?u32, 16), memory.profileForRam(12 * GiB).ram_upper_gib);
    try testing.expectEqual(@as(?u32, 64), memory.profileForRam(48 * GiB).ram_upper_gib);
    try testing.expectEqual(@as(?u32, null), memory.profileForRam(128 * GiB).ram_upper_gib);

    const inflight = memory.capsFor(eight_gib_profile, .inflight);
    const emergency = memory.capsFor(eight_gib_profile, .emergency);
    try testing.expectEqual(@as(u64, 32 * MiB), inflight.bytes);
    try testing.expectEqual(@as(u64, 8 * MiB), emergency.bytes);
    try testing.expectEqual(@as(u16, core.limits.values.fd_max - core.limits.values.fd_control_reserve), inflight.fds);

    var counters: memory.accounting.Counters = .{};
    var budget = inflightBudget(&counters);
    var other = memory.Budget.init(99, inflight, &counters);
    var r = try budget.reserve(session(1), .{ .input_bytes = 1 * MiB, .fds = 2, .cpu_permits = 1 });
    try testing.expectError(error.InvariantViolation, other.release(&r));
    try budget.release(&r);
    try budget.release(&r); // second release is counted, never subtracted
    try testing.expectEqual(@as(u64, 1), counters.snapshot().double_releases);
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
    try testing.expectEqual(@as(u16, 0), budget.usage().fds);
}

test "T03 accounting reports live allocation, retained capacity and process footprint separately" {
    var counters: memory.accounting.Counters = .{};
    var budget = inflightBudget(&counters);
    var reservation = try budget.reserve(session(1), .{ .scratch_bytes = 4 * MiB });
    var request: memory.RequestArena = undefined;
    request.init(testing.allocator, &reservation, &counters, null);

    _ = try request.allocator().alloc(u8, 100 * KiB);
    const during = request.memoryReport();
    try testing.expect(during.handed_out_bytes >= 100 * KiB);
    try testing.expect(during.tracked_bytes >= during.handed_out_bytes);
    try testing.expect(during.retained_capacity_bytes >= during.handed_out_bytes);

    const footprint = memory.accounting.processFootprint();
    if (builtin.os.tag == .macos) {
        try testing.expect(footprint.physical_bytes.? > 0);
        const report = memory.accounting.overhead(during.tracked_bytes, footprint);
        try testing.expect(report.system_overhead_bytes != null);
    } else {
        try testing.expect(footprint.physical_bytes == null);
    }

    const released = try request.release(&budget, &reservation);
    // Freed to the child allocator; whether pages return to the OS is not claimed.
    try testing.expectEqual(@as(u64, 0), released.tracked_after_bytes);
    try testing.expectEqual(@as(u64, 0), budget.usage().bytes);
}
