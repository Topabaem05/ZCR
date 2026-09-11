//! Admission control (T03, I02). S02 RED stub.

const std = @import("std");
const core = @import("zcr_core");
const memory = @import("zcr_memory");

pub const CostInput = struct {
    operation: core.Operation,
    frame_bytes: u64,
    output_bytes: u64,
    items: u32 = 1,
    file_bytes: u64 = 0,
    decoded_bytes: u64 = 0,
    content_bytes: u64 = 0,
    worker_concurrency: u32 = 1,
};

pub fn estimate(input: CostInput) error{InvalidArgument}!core.ResourceCost {
    _ = input;
    return error.InvalidArgument;
}

pub const Evictor = struct {
    context: *anyopaque,
    evict_fn: *const fn (context: *anyopaque, bytes_needed: u64) u64,
};

pub const Admission = struct {
    budget: *memory.Budget,
    evictor: ?Evictor,

    pub fn init(budget: *memory.Budget, evictor: ?Evictor) Admission {
        return .{ .budget = budget, .evictor = evictor };
    }

    pub fn reserve(self: *Admission, session: core.SessionContext, cost: core.ResourceCost) core.ReserveError!core.Reservation {
        _ = .{ self, session, cost };
        return error.ResourceExhausted;
    }

    pub fn release(self: *Admission, session: core.SessionContext, reservation: *core.Reservation) error{InvariantViolation}!void {
        _ = .{ self, session, reservation };
        return error.InvariantViolation;
    }

    pub fn releaseSlot(self: *Admission, session: core.SessionContext) void {
        _ = .{ self, session };
    }

    pub fn inFlight(self: *const Admission) u32 {
        _ = self;
        return std.math.maxInt(u32);
    }

    comptime {
        core.conforms(core.ReserveFn(Admission), Admission.reserve);
    }
};
