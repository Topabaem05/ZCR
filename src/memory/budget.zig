//! Budgets and reservation-bound allocation (T03, I02; docs/05 §2-§4, docs/17 §6).
//!
//! A `Budget` is a hard cap for one bucket of a RAM profile. `reserve` takes the
//! whole worst-case cost of an operation at once (INV-03) or refuses it; nothing
//! is allocated before that succeeds. A `ReservedAllocator` then hands out at
//! most the reserved bytes from its child allocator and returns null beyond
//! that. It never falls back to another allocator.
//!
//! Caps are not preallocated. Budgets count bytes; they do not bound process
//! RSS or footprint (see accounting.zig).

const std = @import("std");
const core = @import("zcr_core");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const accounting = @import("accounting.zig");
pub const arena = @import("arena.zig");
pub const RequestArena = arena.RequestArena;
pub const ChildToken = arena.ChildToken;

const MiB = core.limits.MiB;
const GiB = core.limits.GiB;

pub const Caps = struct { bytes: u64, fds: u16, cpu: u8, output_bytes: u64 };

/// Buckets of config/memory-profiles.json. Normal requests draw only from `inflight`;
/// `emergency` is reserved for error, cancellation and recovery paths.
pub const Bucket = enum { base, emergency, paths, content, ast, inflight };

pub fn profileForRam(ram_bytes: u64) *const core.limits.MemoryProfile {
    const profiles = &core.limits.memory_profiles;
    for (profiles) |*profile| {
        const upper = profile.ram_upper_gib orelse return profile;
        if (ram_bytes <= @as(u64, upper) * GiB) return profile;
    }
    return &profiles[profiles.len - 1];
}

pub fn capsFor(profile: *const core.limits.MemoryProfile, bucket: Bucket) Caps {
    const v = core.limits.values;
    const mib: u64 = switch (bucket) {
        .base => profile.base_mib,
        .emergency => profile.emergency_mib,
        .paths => profile.paths_mib,
        .content => profile.content_mib,
        .ast => profile.ast_mib,
        .inflight => profile.inflight_mib,
    };
    return .{
        .bytes = mib * MiB,
        .fds = switch (bucket) {
            .inflight => @intCast(v.fd_max - v.fd_control_reserve),
            .base, .emergency => @intCast(v.fd_control_reserve),
            .paths, .content, .ast => 0,
        },
        // CPU permits are limited by the scheduler (T09); a byte budget does not cap them.
        .cpu = std.math.maxInt(u8),
        .output_bytes = switch (bucket) {
            .inflight => v.group_backlog_bytes,
            .emergency => v.default_output_bytes,
            .base, .paths, .content, .ast => 0,
        },
    };
}

/// Deterministic allocation failure for tests (docs/12 §7). Only `alloc` calls
/// are counted and failed; `resize` and `remap` are not injected.
pub const FaultPlan = struct {
    /// 1-based index of the allocation attempt that fails; null never fails.
    fail_at: ?u64 = null,
    seen: std.atomic.Value(u64) = .init(0),
    injected: std.atomic.Value(u64) = .init(0),

    /// Counts one attempt and reports whether it must fail.
    pub fn shouldFail(plan: *FaultPlan) bool {
        const attempt = plan.seen.fetchAdd(1, .monotonic) + 1;
        const target = plan.fail_at orelse return false;
        if (attempt != target) return false;
        _ = plan.injected.fetchAdd(1, .monotonic);
        return true;
    }
};

/// Short critical sections over counters only; never held across I/O (INV-05).
pub const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    pub fn lock(l: *SpinLock) void {
        while (!l.state.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(l: *SpinLock) void {
        l.state.unlock();
    }
};

pub const Budget = struct {
    id: u32,
    caps: Caps,
    /// Host pressure policy narrows future admission under lock. Hard caps stay
    /// immutable during runtime, and existing reservations retain their credit.
    admission_caps: ?Caps = null,
    counters: *accounting.Counters,
    lock: SpinLock = .{},
    used: Caps = .{ .bytes = 0, .fds = 0, .cpu = 0, .output_bytes = 0 },
    peak_bytes: u64 = 0,

    pub fn init(id: u32, caps: Caps, counters: *accounting.Counters) Budget {
        return .{ .id = id, .caps = caps, .counters = counters };
    }

    pub fn setAdmissionCaps(self: *Budget, caps: Caps) error{InvalidArgument}!void {
        if (caps.bytes > self.caps.bytes or caps.fds > self.caps.fds or
            caps.cpu > self.caps.cpu or caps.output_bytes > self.caps.output_bytes) return error.InvalidArgument;
        self.lock.lock();
        defer self.lock.unlock();
        self.admission_caps = caps;
    }

    pub fn admissionCaps(self: *Budget) Caps {
        self.lock.lock();
        defer self.lock.unlock();
        return self.admission_caps orelse self.caps;
    }

    /// True only when reclaiming tracked bytes can make this exact cost fit.
    /// Cache eviction cannot restore FD, CPU, or output credit, and must not run
    /// for costs larger than the current admission cap itself.
    pub fn reclaimableMemoryPressure(self: *Budget, cost: core.ResourceCost) bool {
        const bytes = cost.totalBytes() catch return false;
        self.lock.lock();
        defer self.lock.unlock();
        const cap = self.admission_caps orelse self.caps;
        return bytes <= cap.bytes and bytes > cap.bytes -| self.used.bytes and
            cost.fds <= cap.fds -| self.used.fds and
            cost.cpu_permits <= cap.cpu -| self.used.cpu and
            cost.output_bytes <= cap.output_bytes -| self.used.output_bytes;
    }

    /// Reserves the whole cost or nothing. A cost that can never fit and a cost
    /// that does not fit right now are both `ResourceExhausted`; output larger
    /// than the whole output share is `OutputBudgetExceeded`.
    pub fn reserve(self: *Budget, session: core.SessionContext, cost: core.ResourceCost) core.ReserveError!core.Reservation {
        _ = session; // per-session limits live in Admission
        const bytes = cost.totalBytes() catch return error.ResourceExhausted;
        if (cost.output_bytes > self.caps.output_bytes) return error.OutputBudgetExceeded;
        if (bytes > self.caps.bytes or cost.fds > self.caps.fds or cost.cpu_permits > self.caps.cpu) return error.ResourceExhausted;

        self.lock.lock();
        defer self.lock.unlock();
        const cap = self.admission_caps orelse self.caps;
        if (bytes > cap.bytes -| self.used.bytes or
            cost.fds > cap.fds -| self.used.fds or
            cost.cpu_permits > cap.cpu -| self.used.cpu or
            cost.output_bytes > cap.output_bytes -| self.used.output_bytes) return error.ResourceExhausted;

        self.used.bytes += bytes;
        self.used.fds += cost.fds;
        self.used.cpu += cost.cpu_permits;
        self.used.output_bytes += cost.output_bytes;
        self.peak_bytes = @max(self.peak_bytes, self.used.bytes);
        self.counters.reservationOpened();
        return .{ .budget_id = self.id, .bytes = bytes, .fd = cost.fds, .cpu = cost.cpu_permits, .output = cost.output_bytes };
    }

    /// Returns a reservation to this budget. A second release of the same
    /// reservation is counted and ignored; a reservation from another budget or
    /// counters that would underflow are invariant violations.
    pub fn release(self: *Budget, reservation: *core.Reservation) error{InvariantViolation}!void {
        if (reservation.budget_id != self.id) return error.InvariantViolation;
        if (reservation.released) {
            self.counters.doubleRelease();
            return;
        }
        self.lock.lock();
        if (self.used.bytes < reservation.bytes or self.used.fds < reservation.fd or
            self.used.cpu < reservation.cpu or self.used.output_bytes < reservation.output)
        {
            self.lock.unlock();
            return error.InvariantViolation;
        }
        self.used.bytes -= reservation.bytes;
        self.used.fds -= reservation.fd;
        self.used.cpu -= reservation.cpu;
        self.used.output_bytes -= reservation.output;
        self.lock.unlock();
        self.counters.reservationClosed();
        _ = reservation.take();
    }

    pub fn usage(self: *Budget) Caps {
        self.lock.lock();
        defer self.lock.unlock();
        return self.used;
    }

    pub fn peakBytes(self: *Budget) u64 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.peak_bytes;
    }

    comptime {
        core.conforms(core.ReserveFn(Budget), Budget.reserve);
    }
};

/// Allocator bounded by one reservation. Allocation beyond the reserved bytes,
/// an injected fault, or a child failure all return null; there is no fallback.
pub const ReservedAllocator = struct {
    child: Allocator,
    limit: u64,
    live: std.atomic.Value(u64) = .init(0),
    counters: *accounting.Counters,
    fault: ?*FaultPlan,

    pub fn init(child: Allocator, reservation: *const core.Reservation, counters: *accounting.Counters, fault: ?*FaultPlan) ReservedAllocator {
        return .{
            .child = child,
            .limit = if (reservation.released) 0 else reservation.bytes,
            .counters = counters,
            .fault = fault,
        };
    }

    pub fn allocator(self: *ReservedAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn liveBytes(self: *const ReservedAllocator) u64 {
        return self.live.load(.monotonic);
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn claim(self: *ReservedAllocator, bytes: usize) bool {
        var current = self.live.load(.monotonic);
        while (true) {
            const next = std.math.add(u64, current, bytes) catch return false;
            if (next > self.limit) return false;
            current = self.live.cmpxchgWeak(current, next, .monotonic, .monotonic) orelse return true;
        }
    }

    fn unclaim(self: *ReservedAllocator, bytes: usize) void {
        _ = self.live.fetchSub(bytes, .monotonic);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ReservedAllocator = @ptrCast(@alignCast(context));
        if (self.fault) |plan| if (plan.shouldFail()) {
            self.counters.recordFailure(true);
            return null;
        };
        if (!self.claim(len)) {
            self.counters.recordFailure(false);
            return null;
        }
        const ptr = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr) orelse {
            self.unclaim(len);
            self.counters.recordFailure(false);
            return null;
        };
        self.counters.recordAlloc(len);
        return ptr;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ReservedAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len) {
            const extra = new_len - memory.len;
            if (!self.claim(extra)) return false;
            if (!self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr)) {
                self.unclaim(extra);
                return false;
            }
            self.counters.grow(extra);
            return true;
        }
        if (!self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr)) return false;
        self.unclaim(memory.len - new_len);
        self.counters.shrink(memory.len - new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ReservedAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len) {
            const extra = new_len - memory.len;
            if (!self.claim(extra)) return null;
            const ptr = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr) orelse {
                self.unclaim(extra);
                return null;
            };
            self.counters.grow(extra);
            return ptr;
        }
        const ptr = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        self.unclaim(memory.len - new_len);
        self.counters.shrink(memory.len - new_len);
        return ptr;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *ReservedAllocator = @ptrCast(@alignCast(context));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
        self.unclaim(memory.len);
        self.counters.recordFree(memory.len);
    }
};
