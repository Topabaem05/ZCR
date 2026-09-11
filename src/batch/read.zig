//! Batch read (T07, I06; docs/07 §4, docs/05 §7).
//!
//! S02 stub: the API the tests use, with no behaviour yet.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const fs_read = @import("zcr_fs_read");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_item_id_bytes = 64;

pub const Caps = struct {
    /// Items read at the same time, before the reservation is considered.
    max_concurrency: u32 = 4,
};

pub const JobEvent = struct { job: u32, running: u32, started: bool };

/// Test hooks for docs/12 §7.
pub const BatchFault = struct {
    on_job: ?*const fn (context: ?*anyopaque, event: JobEvent) void = null,
    context: ?*anyopaque = null,
};

pub const Report = struct {
    items: u32 = 0,
    jobs: u32 = 0,
    deduplicated: u32 = 0,
    merged: u32 = 0,
    workers: u32 = 0,
    peak_running: u32 = 0,
    output_limit: u64 = 0,
    output_used: u64 = 0,
    output_refused: u32 = 0,
    resource_refused: u32 = 0,
    item_errors: u32 = 0,
    store_bytes: u64 = 0,
};

/// Bytes the result store takes from the reservation for these items and output cap.
pub fn storeCharge(items: []const core.BatchReadItem, output_bytes: u64) u64 {
    _ = items;
    _ = output_bytes;
    return 0;
}

/// Reservation a caller needs so that `concurrency` items can be read at once.
pub fn plannedCost(items: []const core.BatchReadItem, output_bytes: u64, concurrency: u32) error{InvalidArgument}!core.ResourceCost {
    _ = items;
    _ = output_bytes;
    _ = concurrency;
    return error.InvalidArgument;
}

pub const Batcher = struct {
    authorizer: *policy.Authorizer,
    reader: *fs_read.Reader,
    caps: Caps,
    cancel: core.Cancel,
    fault: ?*BatchFault = null,
    last: Report = .{},

    pub fn init(authorizer: *policy.Authorizer, reader: *fs_read.Reader, caps: Caps, cancel: core.Cancel) Batcher {
        return .{ .authorizer = authorizer, .reader = reader, .caps = caps, .cancel = cancel };
    }

    pub fn report(self: *const Batcher) Report {
        return self.last;
    }

    pub fn batchRead(
        self: *Batcher,
        io: Io,
        allocator: Allocator,
        context: core.SessionContext,
        items: []const core.BatchReadItem,
        reservation: *core.Reservation,
    ) core.ReadError!core.Owned(core.BatchResult) {
        _ = self;
        _ = io;
        _ = allocator;
        _ = context;
        _ = items;
        _ = reservation;
        return error.Unsupported;
    }

    comptime {
        core.conforms(core.BatchReadFn(Batcher), Batcher.batchRead);
    }
};
