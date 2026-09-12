//! I07 bounded outer concurrency. Initialize in place and keep the executor,
//! budget, allocator, cancel tokens and callback userdata alive through drain.
//! The allocator must support concurrent frees (never a shared request arena).
//! Accepted heap jobs belong to this executor. A callback runs exactly once,
//! including after cancellation, and must check job.cancel before each chunk.
//! Callbacks neither free their envelope nor release scratch_reservation;
//! completion does both, after the callback returns. On submit error the caller
//! retains both. Parent arenas may be released only after waitIdle/drain.
//! Nested work is enqueued here; callbacks must not wait for their children.
const std = @import("std");
const core = @import("zcr_core");
const memory = @import("zcr_memory");
const queues = @import("zcr_queue");
const darwin = @import("zcr_darwin");

pub const Backend = enum { bounded_threaded, darwin_gcd };
pub const Options = struct {
    backend: Backend = .bounded_threaded,
    cpu_permits: u32 = 2,
    io_permits: u32 = 2,
    usable_physical_cpus: u32,
    /// Deterministic thread-creation failure injection. Disabled by default.
    fail_spawn_after: ?u32 = null,
};
pub const Snapshot = struct {
    queued: usize,
    cpu_in_use: u32,
    non_short_cpu_in_use: u32,
    io_in_use: u32,
    peak_cpu: u32,
    peak_io: u32,
    worker_threads: u32,
    completed: u64,
};
const max_workers = core.limits.scheduler.profiles.throughput.cpu_max;
pub const AdmissionSnapshot = struct {
    cpu_target: u32,
    non_short_cpu_target: u32,
    io_target: u32,
    bulk_admission: bool,
    speculative_work: bool,
    cpu_in_use: u32,
    non_short_cpu_in_use: u32,
    io_in_use: u32,
    outstanding_legacy: usize,
    outstanding_over_target: usize,
    target_effective: bool,
};
// The callback frees its envelope before reacquiring the mutex. Keep immutable
// grant metadata in the slot so policy snapshots never dereference that pointer.
const Grant = struct { cpu: u32 = 0, io: u32 = 0, qos: core.QosIntent = .fg_short };
const Slot = struct { executor: *Executor, entry: ?queues.Entry = null, grant: Grant = .{}, callback_userdata: ?*anyopaque = null };
threadlocal var current_executor: ?*Executor = null;

pub const Executor = struct {
    allocator: std.mem.Allocator,
    budget: *memory.Budget,
    options: Options,
    mutex: std.c.pthread_mutex_t = .{},
    changed: std.c.pthread_cond_t = .{},
    queue: queues.Queue = .{},
    slots: [max_workers]Slot = undefined,
    threads: [max_workers]std.Thread = undefined,
    thread_count: u32 = 0,
    adapter: ?darwin.Adapter = null,
    desired_cpu: u32 = 1,
    desired_io: u32 = 1,
    bulk_admission: bool = true,
    speculative_work: bool = true,
    accepting: bool = true,
    stopping: bool = false,
    next_id: u64 = 1,
    cpu_used: u32 = 0,
    non_short_used: u32 = 0,
    foreground_jobs: u32 = 0,
    io_used: u32 = 0,
    peak_cpu: u32 = 0,
    peak_io: u32 = 0,
    completed: u64 = 0,

    pub fn init(self: *Executor, allocator: std.mem.Allocator, budget: *memory.Budget, options: Options) error{ InvalidArgument, Unsupported, OutOfMemory, ResourceExhausted }!void {
        if (current_executor != null) return error.ResourceExhausted;
        if (options.usable_physical_cpus == 0 or options.cpu_permits == 0 or options.cpu_permits > max_workers or
            options.cpu_permits > core.limits.hardwareCeiling(options.usable_physical_cpus) or options.io_permits == 0 or
            options.io_permits > core.limits.scheduler.profiles.throughput.io_max) return error.InvalidArgument;
        self.* = .{ .allocator = allocator, .budget = budget, .options = options, .desired_cpu = options.cpu_permits, .desired_io = options.io_permits };
        for (&self.slots) |*slot| slot.* = .{ .executor = self };
        if (options.backend == .darwin_gcd) {
            self.adapter = try darwin.Adapter.init();
        } else {
            errdefer {
                self.lock();
                self.stopping = true;
                self.broadcast();
                self.unlock();
                for (self.threads[0..self.thread_count]) |thread| thread.join();
                self.thread_count = 0;
                check(std.c.pthread_cond_destroy(&self.changed));
                check(std.c.pthread_mutex_destroy(&self.mutex));
            }
            while (self.thread_count < options.cpu_permits) : (self.thread_count += 1) {
                if (options.fail_spawn_after) |after| if (self.thread_count == after) return error.ResourceExhausted;
                self.threads[self.thread_count] = std.Thread.spawn(.{}, worker, .{&self.slots[self.thread_count]}) catch return error.ResourceExhausted;
            }
        }
    }

    /// The supplied reservation must belong to budget and must remain live.
    /// An FD-bearing callback conservatively consumes one I/O permit; a
    /// callback cannot start parallel syscalls internally under this grant.
    pub fn submit(self: *Executor, job: *core.JobEnvelope) core.SubmitError!core.JobHandle {
        try job.cancel.check();
        if (job.scratch_reservation.released or job.scratch_reservation.budget_id != self.budget.id) return error.ResourceExhausted;
        self.lock();
        defer self.unlock();
        try job.cancel.check();
        if (!self.accepting or self.next_id == std.math.maxInt(u64)) return error.Busy;
        if ((!self.bulk_admission and job.qos_intent != .fg_short) or
            (!self.speculative_work and job.qos_intent == .idle)) return error.Busy;
        if (queues.cpuCost(job) > self.desired_cpu or queues.ioCost(job) > self.desired_io or
            (job.qos_intent != .fg_short and queues.cpuCost(job) > nonShortCap(self.desired_cpu))) return error.ResourceExhausted;
        const handle: core.JobHandle = .{ .id = self.next_id };
        try self.queue.push(job, handle);
        self.next_id += 1;
        self.pump();
        return handle;
    }

    pub fn promote(self: *Executor, handle: core.JobHandle) bool {
        self.lock();
        defer self.unlock();
        const promoted = self.queue.promote(handle);
        if (promoted) self.pump();
        return promoted;
    }

    /// Wait for all current descendants; external producers must quiesce when
    /// using this as an arena lifetime barrier. drain also closes admission.
    pub fn waitIdle(self: *Executor) error{WouldDeadlock}!void {
        if (current_executor == self) return error.WouldDeadlock;
        self.lock();
        defer self.unlock();
        while (self.queue.len != 0 or self.cpu_used != 0) self.wait();
    }
    pub fn drain(self: *Executor) error{WouldDeadlock}!void {
        if (current_executor == self) return error.WouldDeadlock;
        self.lock();
        defer self.unlock();
        self.accepting = false;
        while (self.queue.len != 0 or self.cpu_used != 0) self.wait();
    }
    /// Only the owner calls deinit, once; it may follow concurrent drain calls
    /// after those callers have returned. It joins all worker/callback frames.
    pub fn deinit(self: *Executor) void {
        self.drain() catch @panic("executor teardown from its callback");
        self.lock();
        self.stopping = true;
        self.broadcast();
        self.unlock();
        for (self.threads[0..self.thread_count]) |thread| thread.join();
        if (self.adapter) |adapter| adapter.deinit();
        check(std.c.pthread_cond_destroy(&self.changed));
        check(std.c.pthread_mutex_destroy(&self.mutex));
    }
    pub fn snapshot(self: *Executor) Snapshot {
        self.lock();
        defer self.unlock();
        return .{ .queued = self.queue.len, .cpu_in_use = self.cpu_used, .non_short_cpu_in_use = self.non_short_used, .io_in_use = self.io_used, .peak_cpu = self.peak_cpu, .peak_io = self.peak_io, .worker_threads = self.thread_count, .completed = self.completed };
    }
    /// Prospective policy only: accepted grants retain their original ownership.
    /// Memory/cache limits are consumed by the runtime owner, not this executor.
    pub fn setAdmissionLimits(self: *Executor, limits: core.AdmissionLimits) error{InvalidArgument}!void {
        if (limits.cpu_permits == 0 or limits.cpu_permits > self.options.cpu_permits or
            limits.io_permits == 0 or limits.io_permits > self.options.io_permits) return error.InvalidArgument;
        self.lock();
        defer self.unlock();
        self.desired_cpu = limits.cpu_permits;
        self.desired_io = limits.io_permits;
        self.bulk_admission = limits.bulk_admission;
        self.speculative_work = limits.speculative_work;
        self.pump();
    }
    fn oversized(self: *const Executor, grant: Grant) bool {
        return grant.cpu > self.desired_cpu or grant.io > self.desired_io or
            (grant.qos != .fg_short and grant.cpu > nonShortCap(self.desired_cpu));
    }
    fn legacy(self: *const Executor, grant: Grant) bool {
        return self.oversized(grant) or (!self.bulk_admission and grant.qos != .fg_short) or
            (!self.speculative_work and grant.qos == .idle);
    }
    /// Counts the bounded live set under lock on every read. No watermark or
    /// retained queue handle can become stale across restore/tighten/promote.
    /// Cooperative callbacks and kernel I/O provide no wall-clock drain bound.
    pub fn admissionSnapshot(self: *Executor) AdmissionSnapshot {
        self.lock();
        defer self.unlock();
        var old: usize = 0;
        var over: usize = 0;
        for (self.slots[0..self.options.cpu_permits]) |slot| if (slot.entry != null) {
            old += @intFromBool(self.legacy(slot.grant));
            over += @intFromBool(self.oversized(slot.grant));
        };
        for (self.queue.entries[0..self.queue.len]) |entry| {
            const grant: Grant = .{ .cpu = queues.cpuCost(entry.job), .io = queues.ioCost(entry.job), .qos = entry.job.qos_intent };
            old += @intFromBool(self.legacy(grant));
            over += @intFromBool(self.oversized(grant));
        }
        return .{ .cpu_target = self.desired_cpu, .non_short_cpu_target = nonShortCap(self.desired_cpu), .io_target = self.desired_io, .bulk_admission = self.bulk_admission, .speculative_work = self.speculative_work, .cpu_in_use = self.cpu_used, .non_short_cpu_in_use = self.non_short_used, .io_in_use = self.io_used, .outstanding_legacy = old, .outstanding_over_target = over, .target_effective = old == 0 and self.cpu_used <= self.desired_cpu and
            self.non_short_used <= nonShortCap(self.desired_cpu) and self.io_used <= self.desired_io };
    }
    fn nonShortCap(cpu: u32) u32 {
        return cpu - @min(core.limits.scheduler.foreground_short_reserved_permits, cpu - 1);
    }
    /// Called under the control mutex; permits are taken before either
    /// dispatch_async_f or waking a worker. No worker waits for a permit.
    fn pump(self: *Executor) void {
        // An oversized original grant must remain exclusive, including when
        // only its non-short cost exceeds the target and short capacity is spare.
        for (self.slots[0..self.options.cpu_permits]) |slot| {
            if (slot.entry != null and self.oversized(slot.grant)) return;
        }
        for (self.slots[0..self.options.cpu_permits]) |*slot| {
            if (slot.entry != null) continue;
            const entry = self.queue.pop(.{ .cpu = self.desired_cpu -| self.cpu_used, .non_short_cpu = nonShortCap(self.desired_cpu) -| self.non_short_used, .io = self.desired_io -| self.io_used, .idle_allowed = self.foreground_jobs == 0, .exclusive_cpu = if (self.cpu_used == 0) self.options.cpu_permits else 0, .exclusive_non_short_cpu = if (self.cpu_used == 0) nonShortCap(self.options.cpu_permits) else 0, .exclusive_io = if (self.cpu_used == 0) self.options.io_permits else 0 }) orelse break;
            self.cpu_used += queues.cpuCost(entry.job);
            if (entry.job.qos_intent == .fg_short or entry.job.qos_intent == .fg_bulk) self.foreground_jobs += 1;
            if (entry.job.qos_intent != .fg_short) self.non_short_used += queues.cpuCost(entry.job);
            self.io_used += queues.ioCost(entry.job);
            self.peak_cpu = @max(self.peak_cpu, self.cpu_used);
            self.peak_io = @max(self.peak_io, self.io_used);
            slot.entry = entry;
            slot.grant = .{ .cpu = queues.cpuCost(entry.job), .io = queues.ioCost(entry.job), .qos = entry.job.qos_intent };
            if (self.adapter) |adapter| {
                // The _f context is the owned heap JobEnvelope itself. Keep
                // application userdata in its bounded slot until the trampoline
                // restores it before invoking the application callback.
                slot.callback_userdata = entry.job.userdata;
                entry.job.userdata = slot;
                adapter.submit(entry.job.qos_intent, entry.job, gcdCallback);
            }
            if (self.oversized(slot.grant)) break;
        }
        self.broadcast();
    }
    fn worker(slot: *Slot) void {
        const self = slot.executor;
        self.lock();
        while (true) {
            while (slot.entry == null and !self.stopping) self.wait();
            if (slot.entry == null and self.stopping) break;
            self.unlock();
            execute(slot);
            self.lock();
        }
        self.unlock();
    }
    fn gcdCallback(context: *anyopaque) callconv(.c) void {
        const job: *core.JobEnvelope = @ptrCast(@alignCast(context));
        const slot: *Slot = @ptrCast(@alignCast(job.userdata.?));
        job.userdata = slot.callback_userdata;
        execute(slot);
    }
    fn execute(slot: *Slot) void {
        const self = slot.executor;
        // Dispatch publishes slot.entry before invoking this callback. Its
        // content remains exclusive to this slot until finish reacquires lock.
        const job = slot.entry.?.job;
        const cpu = queues.cpuCost(job);
        const io = queues.ioCost(job);
        const non_short = job.qos_intent != .fg_short;
        const foreground = job.qos_intent == .fg_short or job.qos_intent == .fg_bulk;
        const previous = current_executor;
        current_executor = self;
        job.callback(job);
        current_executor = previous;
        var reservation = job.scratch_reservation.take();
        self.allocator.destroy(job);
        self.budget.release(&reservation) catch @panic("scheduler reservation invariant");
        self.lock();
        self.cpu_used -= cpu;
        self.io_used -= io;
        if (non_short) self.non_short_used -= cpu;
        if (foreground) self.foreground_jobs -= 1;
        self.completed += 1;
        slot.entry = null;
        self.pump();
        self.unlock();
    }
    fn lock(self: *Executor) void {
        check(std.c.pthread_mutex_lock(&self.mutex));
    }
    fn unlock(self: *Executor) void {
        check(std.c.pthread_mutex_unlock(&self.mutex));
    }
    fn wait(self: *Executor) void {
        check(std.c.pthread_cond_wait(&self.changed, &self.mutex));
    }
    fn broadcast(self: *Executor) void {
        check(std.c.pthread_cond_broadcast(&self.changed));
    }
    comptime {
        core.conforms(core.SubmitFn(Executor), Executor.submit);
    }
};
fn check(e: std.c.E) void {
    if (e != .SUCCESS) @panic("executor pthread primitive invariant");
}
