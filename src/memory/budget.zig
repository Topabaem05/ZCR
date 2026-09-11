//! Budgets and reservation-bound allocation (T03). S02 RED stub.

const std = @import("std");
const core = @import("zcr_core");

pub const accounting = @import("accounting.zig");
pub const arena = @import("arena.zig");
pub const RequestArena = arena.RequestArena;
pub const ChildToken = arena.ChildToken;

pub const Caps = struct { bytes: u64, fds: u16, cpu: u8, output_bytes: u64 };
pub const Bucket = enum { base, emergency, paths, content, ast, inflight };

pub fn profileForRam(ram_bytes: u64) *const core.limits.MemoryProfile {
    _ = ram_bytes;
    return &core.limits.memory_profiles[5];
}

pub fn capsFor(profile: *const core.limits.MemoryProfile, bucket: Bucket) Caps {
    _ = .{ profile, bucket };
    return .{ .bytes = 0, .fds = 0, .cpu = 0, .output_bytes = 0 };
}

pub const FaultPlan = struct {
    fail_at: ?u64 = null,
    seen: std.atomic.Value(u64) = .init(0),
    injected: std.atomic.Value(u64) = .init(0),
};

pub const Budget = struct {
    id: u32,
    caps: Caps,
    counters: *accounting.Counters,

    pub fn init(id: u32, caps: Caps, counters: *accounting.Counters) Budget {
        return .{ .id = id, .caps = caps, .counters = counters };
    }

    pub fn reserve(self: *Budget, session: core.SessionContext, cost: core.ResourceCost) core.ReserveError!core.Reservation {
        _ = .{ self, session, cost };
        return error.ResourceExhausted;
    }

    pub fn release(self: *Budget, reservation: *core.Reservation) error{InvariantViolation}!void {
        _ = .{ self, reservation };
        return error.InvariantViolation;
    }

    pub fn usage(self: *Budget) Caps {
        _ = self;
        return .{ .bytes = 1, .fds = 1, .cpu = 1, .output_bytes = 1 };
    }

    pub fn peakBytes(self: *Budget) u64 {
        _ = self;
        return std.math.maxInt(u64);
    }

    comptime {
        core.conforms(core.ReserveFn(Budget), Budget.reserve);
    }
};

pub const ReservedAllocator = struct {
    child: std.mem.Allocator,

    pub fn init(child: std.mem.Allocator, reservation: *const core.Reservation, counters: *accounting.Counters, fault: ?*FaultPlan) ReservedAllocator {
        _ = .{ reservation, counters, fault };
        return .{ .child = child };
    }

    pub fn allocator(self: *ReservedAllocator) std.mem.Allocator {
        return self.child;
    }

    pub fn liveBytes(self: *const ReservedAllocator) u64 {
        _ = self;
        return std.math.maxInt(u64);
    }
};
