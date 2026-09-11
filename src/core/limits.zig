//! Frozen resource limits and profile tables.
//!
//! Values mirror config/limits.json, config/memory-profiles.json and
//! config/scheduler-profiles.json, which are design defaults, not measurements.
//! `zig build verify-contracts` fails when the two drift apart.

const std = @import("std");

pub const KiB: u64 = 1024;
pub const MiB: u64 = 1024 * KiB;
pub const GiB: u64 = 1024 * MiB;

/// Field names are the keys of config/limits.json `limits`.
pub const Limits = struct {
    raw_frame_bytes: u64,
    default_output_bytes: u64,
    max_output_bytes: u64,
    max_batch_items: u32,
    default_read_lines: u32,
    max_read_lines: u32,
    default_search_matches: u32,
    max_search_matches: u32,
    default_search_file_bytes: u64,
    max_search_file_bytes: u64,
    max_write_file_bytes: u64,
    path_max_utf8_bytes: u32,
    chunk_bytes: u64,
    cpu_slice_target_us: u32,
    global_queue: u32,
    session_queue: u32,
    max_sessions: u32,
    session_backlog_bytes: u64,
    group_backlog_bytes: u64,
    default_deadline_ms: u32,
    max_deadline_ms: u32,
    lease_ttl_ms: u32,
    lease_renew_ms: u32,
    json_max_depth: u32,
    directory_max_depth: u32,
    max_ignore_file_bytes: u64,
    max_ignore_rules: u32,
    fd_max: u32,
    fd_control_reserve: u32,
    max_patch_spans: u32,
    max_file_results: u32,
};

pub const values: Limits = .{
    .raw_frame_bytes = 16 * MiB,
    .default_output_bytes = 256 * KiB,
    .max_output_bytes = 2 * MiB,
    .max_batch_items = 32,
    .default_read_lines = 200,
    .max_read_lines = 5000,
    .default_search_matches = 100,
    .max_search_matches = 1000,
    .default_search_file_bytes = 32 * MiB,
    .max_search_file_bytes = 1 * GiB,
    .max_write_file_bytes = 8 * MiB,
    .path_max_utf8_bytes = 4096,
    .chunk_bytes = 256 * KiB,
    .cpu_slice_target_us = 2000,
    .global_queue = 64,
    .session_queue = 16,
    .max_sessions = 16,
    .session_backlog_bytes = 2 * MiB,
    .group_backlog_bytes = 16 * MiB,
    .default_deadline_ms = 5000,
    .max_deadline_ms = 60000,
    .lease_ttl_ms = 30000,
    .lease_renew_ms = 10000,
    .json_max_depth = 64,
    .directory_max_depth = 128,
    .max_ignore_file_bytes = 1 * MiB,
    .max_ignore_rules = 10000,
    .fd_max = 128,
    .fd_control_reserve = 32,
    .max_patch_spans = 1024,
    .max_file_results = 10000,
};

/// One row of config/memory-profiles.json. Caps are not preallocated.
pub const MemoryProfile = struct {
    /// Largest system RAM this row applies to; null is the open-ended last row.
    ram_upper_gib: ?u32,
    group_mib: u32,
    tracked_mib: u32,
    base_mib: u32,
    emergency_mib: u32,
    paths_mib: u32,
    content_mib: u32,
    ast_mib: u32,
    inflight_mib: u32,
};

pub const memory_profiles = [_]MemoryProfile{
    .{ .ram_upper_gib = 8, .group_mib = 128, .tracked_mib = 96, .base_mib = 16, .emergency_mib = 8, .paths_mib = 24, .content_mib = 16, .ast_mib = 0, .inflight_mib = 32 },
    .{ .ram_upper_gib = 16, .group_mib = 256, .tracked_mib = 192, .base_mib = 16, .emergency_mib = 8, .paths_mib = 48, .content_mib = 48, .ast_mib = 16, .inflight_mib = 56 },
    .{ .ram_upper_gib = 24, .group_mib = 384, .tracked_mib = 288, .base_mib = 16, .emergency_mib = 8, .paths_mib = 64, .content_mib = 80, .ast_mib = 32, .inflight_mib = 88 },
    .{ .ram_upper_gib = 32, .group_mib = 512, .tracked_mib = 384, .base_mib = 24, .emergency_mib = 8, .paths_mib = 80, .content_mib = 104, .ast_mib = 64, .inflight_mib = 104 },
    .{ .ram_upper_gib = 64, .group_mib = 768, .tracked_mib = 576, .base_mib = 24, .emergency_mib = 8, .paths_mib = 128, .content_mib = 144, .ast_mib = 112, .inflight_mib = 160 },
    .{ .ram_upper_gib = null, .group_mib = 1024, .tracked_mib = 768, .base_mib = 32, .emergency_mib = 16, .paths_mib = 160, .content_mib = 208, .ast_mib = 160, .inflight_mib = 192 },
};

pub const PermitRange = struct { cpu_initial: u32, cpu_max: u32, io_initial: u32, io_max: u32 };

/// Keys of config/scheduler-profiles.json `profiles`.
pub const SchedulerProfiles = struct {
    latency: PermitRange,
    balanced: PermitRange,
    throughput: PermitRange,
    model_coexist: PermitRange,
    critical: PermitRange,
};

pub const QosClass = enum { user_initiated, utility, background };

pub const scheduler = struct {
    pub const profiles: SchedulerProfiles = .{
        .latency = .{ .cpu_initial = 2, .cpu_max = 4, .io_initial = 2, .io_max = 4 },
        .balanced = .{ .cpu_initial = 2, .cpu_max = 4, .io_initial = 2, .io_max = 4 },
        .throughput = .{ .cpu_initial = 4, .cpu_max = 8, .io_initial = 4, .io_max = 8 },
        .model_coexist = .{ .cpu_initial = 1, .cpu_max = 2, .io_initial = 1, .io_max = 2 },
        .critical = .{ .cpu_initial = 1, .cpu_max = 1, .io_initial = 1, .io_max = 1 },
    };
    pub const qos_foreground: QosClass = .user_initiated;
    pub const qos_maintenance: QosClass = .utility;
    pub const qos_prefetch: QosClass = .background;
    pub const hardware_ceiling_formula = "max(1,usable_physical_cpus - (2 if usable_physical_cpus>=8 else 1))";
    pub const all_cpu_counts_clamped_to_hardware_ceiling = true;
    pub const foreground_short_reserved_permits: u32 = 2;
    pub const foreground_to_maintenance_weight = [2]u32{ 4, 1 };
    pub const normal_stable_recovery_ms: u32 = 10_000;
    pub const recovery_step_ms: u32 = 5_000;
    pub const recovery_step_percentage_points: u32 = 10;
};

/// `hardware_ceiling_formula`: CPU permits ZCR allows itself, not reserved cores.
pub fn hardwareCeiling(usable_physical_cpus: u32) u32 {
    _ = usable_physical_cpus;
    return 0; // S02 RED placeholder
}
