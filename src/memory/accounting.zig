//! Memory accounting (T03). S02 RED stub.

const std = @import("std");

pub const Counters = struct {
    live_bytes: std.atomic.Value(u64) = .init(0),

    pub fn snapshot(c: *const Counters) Snapshot {
        _ = c;
        return .{ .live_bytes = 1, .active_reservations = 1 };
    }
};

pub const Snapshot = struct {
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
    allocations: u64 = 0,
    frees: u64 = 0,
    failed_allocations: u64 = 0,
    injected_failures: u64 = 0,
    active_reservations: u64 = 0,
    double_releases: u64 = 0,
};

pub const Footprint = struct { physical_bytes: ?u64 = null, resident_bytes: ?u64 = null };
pub const Overhead = struct { tracked_bytes: u64, process_footprint_bytes: ?u64, system_overhead_bytes: ?u64 };

pub fn processFootprint() Footprint {
    return .{};
}

pub fn overhead(tracked_bytes: u64, footprint: Footprint) Overhead {
    return .{ .tracked_bytes = tracked_bytes, .process_footprint_bytes = footprint.physical_bytes, .system_overhead_bytes = null };
}
