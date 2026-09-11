//! Request arenas (T03; docs/02 §5, docs/05 §3, §11).
//!
//! A request arena allocates from its own reservation through a
//! `ReservedAllocator`. Release follows docs/02 §5: children drained, then
//! arena memory freed to the child allocator, then the reservation returned.
//! "Cancel requested" and "released" are different states: cancelling only
//! stops new children; memory stays valid until every pending child has ended.
//!
//! Worker scratch buffers do not use a request arena; each worker takes its own
//! reservation and `ReservedAllocator`, so a request reset never frees a
//! buffer a worker is still using. Arena reuse with retained capacity
//! (`retained_limit_bytes`) is a policy constant for the executor (T09) and is
//! not implemented here: `release` frees everything.

const std = @import("std");
const core = @import("zcr_core");
const budget_mod = @import("budget.zig");
const accounting = @import("accounting.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// docs/05 §3 request arena policy: start size and capacity kept after a request.
pub const initial_bytes = 8 * core.limits.KiB;
pub const retained_limit_bytes = 64 * core.limits.KiB;

pub const ChildToken = struct { request: *RequestArena };

pub const ReleaseReport = struct {
    /// Arena capacity freed to the child allocator (not necessarily to the OS).
    capacity_before_bytes: u64,
    /// Bytes still held from the reservation after release; always 0 on success.
    tracked_after_bytes: u64,
};

pub const MemoryReport = struct {
    /// Bytes handed to callers since the arena was created.
    handed_out_bytes: u64,
    /// Bytes the reservation-bound allocator holds from its child.
    tracked_bytes: u64,
    /// Arena capacity, including space not yet handed out.
    retained_capacity_bytes: u64,
};

const State = enum(u8) { active, releasing, released };

pub const RequestArena = struct {
    reserved: budget_mod.ReservedAllocator,
    arena: std.heap.ArenaAllocator,
    fault: ?*budget_mod.FaultPlan,
    counters: *accounting.Counters,
    handed_out: std.atomic.Value(u64) = .init(0),
    pending: std.atomic.Value(u32) = .init(0),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(State) = .init(.active),

    /// Initializes in place; the arena refers to `self.reserved`, so a RequestArena must not move.
    pub fn init(
        self: *RequestArena,
        child: Allocator,
        reservation: *const core.Reservation,
        counters: *accounting.Counters,
        fault: ?*budget_mod.FaultPlan,
    ) void {
        self.* = .{
            .reserved = budget_mod.ReservedAllocator.init(child, reservation, counters, null),
            .arena = undefined,
            .fault = fault,
            .counters = counters,
        };
        self.arena = std.heap.ArenaAllocator.init(self.reserved.allocator());
    }

    pub fn allocator(self: *RequestArena) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Registers a child job. Refused once cancellation was requested or release started.
    pub fn beginChild(self: *RequestArena) error{Cancelled}!ChildToken {
        _ = self.pending.fetchAdd(1, .monotonic);
        if (self.cancel_requested.load(.monotonic) or self.state.load(.monotonic) != .active) {
            _ = self.pending.fetchSub(1, .monotonic);
            return error.Cancelled;
        }
        return .{ .request = self };
    }

    pub fn endChild(self: *RequestArena, token: ChildToken) void {
        std.debug.assert(token.request == self);
        const before = self.pending.fetchSub(1, .monotonic);
        std.debug.assert(before > 0);
    }

    pub fn requestCancel(self: *RequestArena) void {
        self.cancel_requested.store(true, .monotonic);
    }

    pub fn isCancelRequested(self: *const RequestArena) bool {
        return self.cancel_requested.load(.monotonic);
    }

    pub fn pendingChildren(self: *const RequestArena) u32 {
        return self.pending.load(.monotonic);
    }

    /// Frees the arena and returns the reservation, but only when no child is
    /// pending; otherwise nothing is freed and `ChildrenPending` is returned.
    pub fn release(self: *RequestArena, budget: *budget_mod.Budget, reservation: *core.Reservation) error{ ChildrenPending, InvariantViolation }!ReleaseReport {
        if (self.state.cmpxchgStrong(.active, .releasing, .monotonic, .monotonic) != null) return error.InvariantViolation;
        // A child that registered before the state change is visible here; one that
        // registers after it sees `releasing` and backs out.
        if (self.pending.load(.monotonic) != 0) {
            self.state.store(.active, .monotonic);
            return error.ChildrenPending;
        }
        const capacity = self.arena.queryCapacity();
        self.arena.deinit();
        const tracked_after = self.reserved.liveBytes();
        if (tracked_after != 0) return error.InvariantViolation;
        try budget.release(reservation);
        self.state.store(.released, .monotonic);
        return .{ .capacity_before_bytes = capacity, .tracked_after_bytes = tracked_after };
    }

    pub fn memoryReport(self: *RequestArena) MemoryReport {
        return .{
            .handed_out_bytes = self.handed_out.load(.monotonic),
            .tracked_bytes = self.reserved.liveBytes(),
            .retained_capacity_bytes = self.arena.queryCapacity(),
        };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *RequestArena = @ptrCast(@alignCast(context));
        std.debug.assert(self.state.load(.monotonic) != .released);
        if (self.fault) |plan| if (plan.shouldFail()) {
            self.counters.recordFailure(true);
            return null;
        };
        const inner = self.arena.allocator();
        const ptr = inner.vtable.alloc(inner.ptr, len, alignment, ret_addr) orelse return null;
        _ = self.handed_out.fetchAdd(len, .monotonic);
        return ptr;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *RequestArena = @ptrCast(@alignCast(context));
        const inner = self.arena.allocator();
        if (!inner.vtable.resize(inner.ptr, memory, alignment, new_len, ret_addr)) return false;
        self.adjustHandedOut(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *RequestArena = @ptrCast(@alignCast(context));
        const inner = self.arena.allocator();
        const ptr = inner.vtable.remap(inner.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        self.adjustHandedOut(memory.len, new_len);
        return ptr;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *RequestArena = @ptrCast(@alignCast(context));
        const inner = self.arena.allocator();
        inner.vtable.free(inner.ptr, memory, alignment, ret_addr);
        _ = self.handed_out.fetchSub(memory.len, .monotonic);
    }

    fn adjustHandedOut(self: *RequestArena, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            _ = self.handed_out.fetchAdd(new_len - old_len, .monotonic);
        } else {
            _ = self.handed_out.fetchSub(old_len - new_len, .monotonic);
        }
    }
};
