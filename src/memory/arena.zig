//! Request arenas and worker scratch (T03). S02 RED stub.

const std = @import("std");
const core = @import("zcr_core");
const budget_mod = @import("budget.zig");
const accounting = @import("accounting.zig");

pub const ChildToken = struct { id: u32 };

pub const ReleaseReport = struct { capacity_before_bytes: u64, tracked_after_bytes: u64 };
pub const MemoryReport = struct { handed_out_bytes: u64, tracked_bytes: u64, retained_capacity_bytes: u64 };

pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(self: *RequestArena, child: std.mem.Allocator, reservation: *const core.Reservation, counters: *accounting.Counters, fault: ?*budget_mod.FaultPlan) void {
        _ = .{ reservation, counters, fault };
        self.* = .{ .arena = .init(child) };
    }

    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn beginChild(self: *RequestArena) error{Cancelled}!ChildToken {
        _ = self;
        return .{ .id = 0 };
    }

    pub fn endChild(self: *RequestArena, token: ChildToken) void {
        _ = .{ self, token };
    }

    pub fn requestCancel(self: *RequestArena) void {
        _ = self;
    }

    pub fn isCancelRequested(self: *const RequestArena) bool {
        _ = self;
        return false;
    }

    pub fn pendingChildren(self: *const RequestArena) u32 {
        _ = self;
        return 0;
    }

    pub fn release(self: *RequestArena, budget: *budget_mod.Budget, reservation: *core.Reservation) error{ ChildrenPending, InvariantViolation }!ReleaseReport {
        _ = .{ budget, reservation };
        self.arena.deinit();
        return error.InvariantViolation;
    }

    pub fn memoryReport(self: *RequestArena) MemoryReport {
        _ = self;
        return .{ .handed_out_bytes = 0, .tracked_bytes = 0, .retained_capacity_bytes = 0 };
    }
};
