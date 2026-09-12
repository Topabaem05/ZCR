//! Admission control (T03, I02; docs/05 §4, §10, docs/07, docs/17 §6).
//!
//! `estimate` turns a request shape into its worst-case `ResourceCost`: raw
//! frame, decoded input, full old and new file bytes, scratch, output and a
//! journal record, so that nothing large is allocated before the reservation
//! exists (INV-03). `Admission.reserve` then:
//!   1. refuses a cost that can never fit the budget, without queueing or evicting;
//!   2. takes an in-flight slot, bounded per session and globally (`E_BUSY`);
//!   3. reserves from the budget, and on shortage asks the evictor once and retries
//!      once before `ResourceExhausted` (`E_RESOURCE`).
//! Emergency capacity is a separate budget and is never used here.

const std = @import("std");
const core = @import("zcr_core");
const memory = @import("zcr_memory");

const KiB = core.limits.KiB;

/// Upper bound for one prepared journal record (T12 refines the real size).
pub const journal_estimate_bytes = 64 * KiB;

pub const CostInput = struct {
    operation: core.Operation,
    /// Raw request frame as received.
    frame_bytes: u64,
    output_bytes: u64,
    items: u32 = 1,
    /// Current size of the file a patch rewrites.
    file_bytes: u64 = 0,
    /// Decoded replacement text of a patch.
    decoded_bytes: u64 = 0,
    /// Content of a create.
    content_bytes: u64 = 0,
    /// Items read concurrently by a batch.
    worker_concurrency: u32 = 1,
};

/// Worst-case cost of one request. Inputs beyond contract limits are
/// `InvalidArgument` before any budget is consulted.
pub fn estimate(input: CostInput) error{InvalidArgument}!core.ResourceCost {
    const v = core.limits.values;
    if (input.frame_bytes > v.raw_frame_bytes or input.output_bytes > v.max_output_bytes) return error.InvalidArgument;
    if (input.items == 0 or input.items > v.max_batch_items or input.worker_concurrency == 0) return error.InvalidArgument;

    var cost: core.ResourceCost = .{ .input_bytes = input.frame_bytes, .output_bytes = input.output_bytes };
    switch (input.operation) {
        .read, .enumerate, .search => {
            cost.scratch_bytes = v.chunk_bytes;
            cost.fds = 1;
        },
        .batch_read => {
            // One shared output budget; scratch and handles only for items read at once.
            const workers = @min(input.items, input.worker_concurrency);
            cost.scratch_bytes = v.chunk_bytes * workers;
            cost.fds = @intCast(workers);
        },
        .patch => {
            if (input.file_bytes > v.max_write_file_bytes or input.decoded_bytes > v.max_write_file_bytes) return error.InvalidArgument;
            const new_bytes = @min(v.max_write_file_bytes, input.file_bytes + input.decoded_bytes);
            cost.input_bytes += input.decoded_bytes;
            cost.write_temp_bytes = input.file_bytes + new_bytes;
            cost.journal_bytes = journal_estimate_bytes;
            cost.fds = 3;
        },
        .create => {
            if (input.content_bytes > v.max_write_file_bytes) return error.InvalidArgument;
            cost.input_bytes += input.content_bytes;
            cost.write_temp_bytes = input.content_bytes;
            cost.journal_bytes = journal_estimate_bytes;
            cost.fds = 2;
        },
        .status, .health => {},
    }
    return cost;
}

/// Frees cache memory on request; returns the bytes it released (0 when nothing could go).
pub const Evictor = struct {
    context: *anyopaque,
    evict_fn: *const fn (context: *anyopaque, bytes_needed: u64) u64,
};

const Slot = struct { session: core.SessionId, count: u32 };

pub const Admission = struct {
    budget: *memory.Budget,
    evictor: ?Evictor,
    lock: memory.SpinLock = .{},
    slots: [core.limits.values.max_sessions]?Slot = @splat(null),
    in_flight: u32 = 0,

    pub fn init(budget: *memory.Budget, evictor: ?Evictor) Admission {
        return .{ .budget = budget, .evictor = evictor };
    }

    pub fn reserve(self: *Admission, session: core.SessionContext, cost: core.ResourceCost) core.ReserveError!core.Reservation {
        const bytes = cost.totalBytes() catch return error.ResourceExhausted;
        const caps = self.budget.caps;
        if (cost.output_bytes > caps.output_bytes) return error.OutputBudgetExceeded;
        if (bytes > caps.bytes or cost.fds > caps.fds or cost.cpu_permits > caps.cpu) return error.ResourceExhausted;

        try self.takeSlot(session.session_id);
        errdefer self.releaseSlot(session);

        return self.budget.reserve(session, cost) catch |err| switch (err) {
            error.ResourceExhausted => {
                const evictor = self.evictor orelse return err;
                if (evictor.evict_fn(evictor.context, bytes) == 0) return err;
                return self.budget.reserve(session, cost);
            },
            else => return err,
        };
    }

    /// Returns the reservation and the in-flight slot.
    pub fn release(self: *Admission, session: core.SessionContext, reservation: *core.Reservation) error{InvariantViolation}!void {
        try self.budget.release(reservation);
        self.releaseSlot(session);
    }

    /// Returns only the in-flight slot, for callers that released the reservation elsewhere
    /// (for example through `RequestArena.release`).
    pub fn releaseSlot(self: *Admission, session: core.SessionContext) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.slots) |*maybe| {
            const slot = &(maybe.* orelse continue);
            if (!std.mem.eql(u8, &slot.session.uuid, &session.session_id.uuid)) continue;
            std.debug.assert(slot.count > 0 and self.in_flight > 0);
            slot.count -= 1;
            self.in_flight -= 1;
            if (slot.count == 0) maybe.* = null;
            return;
        }
        std.debug.assert(false); // releasing a slot that was never taken
    }

    pub fn inFlight(self: *Admission) u32 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.in_flight;
    }

    fn takeSlot(self: *Admission, session: core.SessionId) error{Busy}!void {
        const v = core.limits.values;
        self.lock.lock();
        defer self.lock.unlock();
        if (self.in_flight >= v.global_queue) return error.Busy;

        var free_index: ?usize = null;
        for (&self.slots, 0..) |*maybe, i| {
            const slot = &(maybe.* orelse {
                if (free_index == null) free_index = i;
                continue;
            });
            if (!std.mem.eql(u8, &slot.session.uuid, &session.uuid)) continue;
            if (slot.count >= v.session_queue) return error.Busy;
            slot.count += 1;
            self.in_flight += 1;
            return;
        }
        const index = free_index orelse return error.Busy;
        self.slots[index] = .{ .session = session, .count = 1 };
        self.in_flight += 1;
    }

    comptime {
        core.conforms(core.ReserveFn(Admission), Admission.reserve);
    }
};
