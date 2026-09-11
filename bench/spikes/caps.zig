//! T00 baseline capture and platform probe (PF-001; gates G01/G03/G04/G06).
//! S02 RED stub: public types are declared, capture is not implemented yet.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const schema_version = "zcr-baseline/1";

pub const ProbeStatus = enum { present, absent, failed, not_applicable };
pub const GateStatus = enum { pass, fail, unknown, not_run };
pub const CorpusStatus = enum { measured, not_provided };
pub const PageCacheState = enum { unknown, cold, warm };
pub const PowerSource = enum { ac, battery, ups, unknown, not_applicable };
pub const LowPowerMode = enum { enabled, disabled, unknown, not_applicable };
pub const ThermalState = enum { nominal, fair, serious, critical, unknown, not_applicable };
pub const GitFileKind = enum { file, directory, missing, other };

pub const Gate = struct { id: []const u8, status: GateStatus, detail: []const u8 };
pub const KeyProbe = struct { key: []const u8, status: ProbeStatus };
pub const PerfLevel = struct { index: u32, name: ?[]const u8, physicalcpu: ?u64, logicalcpu: ?u64 };

pub const Source = struct { repo_path: ?[]const u8 = null, head_commit: ?[]const u8 = null, dirty: ?bool = null };
pub const Compiler = struct {
    zig_version: []const u8,
    target: []const u8,
    optimize: []const u8,
    zig_exe: ?[]const u8 = null,
    zig_exe_sha256: ?[]const u8 = null,
};
pub const Os = struct {
    tag: []const u8,
    kernel_release: []const u8,
    product_version: ?[]const u8 = null,
    build: ?[]const u8 = null,
    model: ?[]const u8 = null,
};
pub const Cpu = struct {
    arch: []const u8,
    brand: ?[]const u8 = null,
    ncpu: ?u64 = null,
    physicalcpu: ?u64 = null,
    logicalcpu: ?u64 = null,
    nperflevels: ?u32 = null,
    perflevels: []const PerfLevel = &.{},
};
pub const Memory = struct {
    total_bytes: ?u64 = null,
    page_size: ?u64 = null,
    vm_pressure_level: ?u64 = null,
    dispatch_pressure_source: ProbeStatus = .not_applicable,
};
pub const Power = struct {
    source: PowerSource = .not_applicable,
    low_power_mode: LowPowerMode = .not_applicable,
    thermal_state: ThermalState = .not_applicable,
};
pub const Gcd = struct {
    status: ProbeStatus = .not_applicable,
    callback_ran: bool = false,
    requested_qos: []const u8 = "",
    observed_qos: []const u8 = "",
};
pub const Cache = struct {
    page_cache_state: PageCacheState = .unknown,
    control_evidence: ?[]const u8 = null,
    zig_global_cache_dir: ?[]const u8 = null,
    zig_local_cache_dir: ?[]const u8 = null,
    tmpdir: ?[]const u8 = null,
};
pub const Corpus = struct {
    status: CorpusStatus = .not_provided,
    id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    file_count: u64 = 0,
    total_bytes: u64 = 0,
    skipped_non_regular: u64 = 0,
    sha256: ?[]const u8 = null,
    digest_method: []const u8 = corpus_digest_method,
};
pub const Sdk = struct { macos_min_required: ?u32 = null, macos_max_allowed: ?u32 = null };
pub const Tool = struct {
    name: []const u8,
    status: ProbeStatus,
    path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
};
pub const GitCommand = struct { argv: []const u8, exit_code: ?u8, stdout_sha256: ?[]const u8 };
pub const GitProbe = struct {
    status: ProbeStatus,
    repo_path: []const u8,
    toplevel: ?[]const u8 = null,
    absolute_git_dir: ?[]const u8 = null,
    common_dir: ?[]const u8 = null,
    head_commit: ?[]const u8 = null,
    is_linked_worktree: ?bool = null,
    dot_git_kind: GitFileKind = .missing,
    worktree_count: ?u32 = null,
    dirty: ?bool = null,
    commands: []const GitCommand = &.{},
};

pub const Baseline = struct {
    schema_version: []const u8 = schema_version,
    captured_at_unix_ms: i64,
    source: Source,
    compiler: Compiler,
    os: Os,
    cpu: Cpu,
    memory: Memory,
    power: Power,
    gcd: Gcd,
    cache: Cache,
    corpus: Corpus,
    sdk: Sdk,
    tools: []const Tool,
    git: ?GitProbe,
    sysctl_keys: []const KeyProbe,
    gates: []const Gate,
    not_run: []const []const u8,
};

pub const corpus_digest_method = "sha256 over sorted lines '<sha256hex>  <relative/path>\\n' of regular files";

pub const CorpusLimits = struct {
    max_files: u64 = 200_000,
    max_bytes: u64 = 2 * 1024 * 1024 * 1024,
};

pub const Options = struct {
    environ: *const Environ.Map,
    repo_path: ?[]const u8 = null,
    corpus_path: ?[]const u8 = null,
    corpus_id: ?[]const u8 = null,
    corpus_limits: CorpusLimits = .{},
    zig_exe: ?[]const u8 = null,
};

pub fn capture(arena: Allocator, io: Io, options: Options) !Baseline {
    _ = .{ arena, io, options };
    return error.NotImplemented;
}

pub fn validate(b: *const Baseline) !void {
    _ = b;
    return error.NotImplemented;
}

pub fn toJson(arena: Allocator, b: *const Baseline) ![]u8 {
    _ = .{ arena, b };
    return error.NotImplemented;
}

pub fn digestCorpus(arena: Allocator, io: Io, path: []const u8, limits: CorpusLimits) !Corpus {
    _ = .{ arena, io, path, limits };
    return error.NotImplemented;
}

pub fn probeSysctlKey(name: [:0]const u8) ProbeStatus {
    _ = name;
    return .failed;
}

pub fn probeCpu(arena: Allocator) !Cpu {
    _ = arena;
    return error.NotImplemented;
}

pub fn probeGit(arena: Allocator, io: Io, environ: *const Environ.Map, repo_path: []const u8) !GitProbe {
    _ = .{ arena, io, environ, repo_path };
    return error.NotImplemented;
}

pub fn probeTool(arena: Allocator, io: Io, environ: *const Environ.Map, name: []const u8, args: []const []const u8) !Tool {
    _ = .{ arena, io, environ, name, args };
    return error.NotImplemented;
}

pub fn main() void {}
