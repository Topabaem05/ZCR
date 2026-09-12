//! Memory accounting (T03; docs/05 §1, §9, docs/12 §6).
//!
//! Three quantities are kept apart and never added together:
//!   tracked bytes      held by reservation-bound allocators from their child allocator
//!   retained capacity  arena capacity kept for reuse (part of tracked bytes)
//!   process footprint  the OS view of the whole process (macOS phys_footprint), which also
//!                      covers stacks, system libraries, allocator caches and untracked memory
//! Returning memory to a child allocator is not a claim that pages return to the OS.

const std = @import("std");
const builtin = @import("builtin");

pub const Counters = struct {
    live_bytes: std.atomic.Value(u64) = .init(0),
    peak_live_bytes: std.atomic.Value(u64) = .init(0),
    allocations: std.atomic.Value(u64) = .init(0),
    frees: std.atomic.Value(u64) = .init(0),
    failed_allocations: std.atomic.Value(u64) = .init(0),
    injected_failures: std.atomic.Value(u64) = .init(0),
    active_reservations: std.atomic.Value(u64) = .init(0),
    double_releases: std.atomic.Value(u64) = .init(0),

    pub fn recordAlloc(c: *Counters, bytes: u64) void {
        _ = c.allocations.fetchAdd(1, .monotonic);
        c.grow(bytes);
    }

    pub fn recordFree(c: *Counters, bytes: u64) void {
        _ = c.frees.fetchAdd(1, .monotonic);
        c.shrink(bytes);
    }

    pub fn grow(c: *Counters, bytes: u64) void {
        const live = c.live_bytes.fetchAdd(bytes, .monotonic) + bytes;
        var peak = c.peak_live_bytes.load(.monotonic);
        while (live > peak) {
            peak = c.peak_live_bytes.cmpxchgWeak(peak, live, .monotonic, .monotonic) orelse break;
        }
    }

    pub fn shrink(c: *Counters, bytes: u64) void {
        _ = c.live_bytes.fetchSub(bytes, .monotonic);
    }

    pub fn recordFailure(c: *Counters, injected: bool) void {
        _ = c.failed_allocations.fetchAdd(1, .monotonic);
        if (injected) _ = c.injected_failures.fetchAdd(1, .monotonic);
    }

    pub fn reservationOpened(c: *Counters) void {
        _ = c.active_reservations.fetchAdd(1, .monotonic);
    }

    pub fn reservationClosed(c: *Counters) void {
        _ = c.active_reservations.fetchSub(1, .monotonic);
    }

    pub fn doubleRelease(c: *Counters) void {
        _ = c.double_releases.fetchAdd(1, .monotonic);
    }

    pub fn snapshot(c: *const Counters) Snapshot {
        return .{
            .live_bytes = c.live_bytes.load(.monotonic),
            .peak_live_bytes = c.peak_live_bytes.load(.monotonic),
            .allocations = c.allocations.load(.monotonic),
            .frees = c.frees.load(.monotonic),
            .failed_allocations = c.failed_allocations.load(.monotonic),
            .injected_failures = c.injected_failures.load(.monotonic),
            .active_reservations = c.active_reservations.load(.monotonic),
            .double_releases = c.double_releases.load(.monotonic),
        };
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

/// Whole-process memory as reported by the OS; null where no probe exists.
pub const Footprint = struct { physical_bytes: ?u64 = null, resident_bytes: ?u64 = null };

pub const Overhead = struct {
    tracked_bytes: u64,
    process_footprint_bytes: ?u64,
    /// Footprint not explained by tracked bytes; null when the footprint is unknown.
    system_overhead_bytes: ?u64,
};

/// macOS: `proc_pid_rusage(RUSAGE_INFO_V2)`. Linux RSS/PSS/cgroup probes belong to T17.
pub fn processFootprint() Footprint {
    if (builtin.os.tag != .macos) return .{};
    var info: RusageInfoV2 = undefined;
    if (proc_pid_rusage(std.c.getpid(), rusage_info_v2, &info) != 0) return .{};
    return .{ .physical_bytes = info.phys_footprint, .resident_bytes = info.resident_size };
}

pub fn overhead(tracked_bytes: u64, footprint: Footprint) Overhead {
    return .{
        .tracked_bytes = tracked_bytes,
        .process_footprint_bytes = footprint.physical_bytes,
        .system_overhead_bytes = if (footprint.physical_bytes) |physical| physical -| tracked_bytes else null,
    };
}

const rusage_info_v2 = 2;

/// `struct rusage_info_v2` from <sys/resource.h>.
const RusageInfoV2 = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
    child_user_time: u64,
    child_system_time: u64,
    child_pkg_idle_wkups: u64,
    child_interrupt_wkups: u64,
    child_pageins: u64,
    child_elapsed_abstime: u64,
    diskio_bytesread: u64,
    diskio_byteswritten: u64,
};

extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfoV2) c_int;
