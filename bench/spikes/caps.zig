//! T00 baseline capture and platform probe.
//!
//! Records the environment that a benchmark or test result depends on (PF-001)
//! and probes gates G01 (Zig + macOS SDK compile/link/run), G03 (memory
//! pressure, thermal and low-power signals), G04 (perflevel sysctl keys) and
//! G06 (Git worktree identity commands). Facilities that are missing are
//! recorded as absent, unknown or not_run; nothing is inferred from names.
//!
//! Build and run commands, including the macOS link flags, are in
//! bench/baseline.md.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema_version = "zcr-baseline/1";
pub const required_zig_version = "0.16.0";
pub const required_gates = [_][]const u8{ "G01", "G03", "G04", "G06" };

const is_macos = builtin.os.tag == .macos;
const command_timeout_ms = 10_000;
const gcd_timeout_ns: i64 = 2_000_000_000;
const max_command_output = 1024 * 1024;
const max_sysctl_string = 4096;
const max_perflevels = 16;
const hash_chunk_bytes = 64 * 1024;

const baseline_tools = [_][]const u8{ "git", "rg", "fd" };
const host_tools = [_][]const u8{ "claude", "codex" };

const not_run_items = [_][]const u8{
    "B0 host built-in tool latency trace (Codex/Claude Read/Grep/Glob) is not captured; --host-tools records host versions only",
    "page cache state is not controlled on macOS and is recorded as unknown",
    "physical energy measurement",
    "Intel Mac, x86-64 Linux and Windows runtime probes",
    "G11 macOS 11 legacy compatibility",
};

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
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical.
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
    timed_out: bool = false,
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
    excluded_names: []const []const u8 = &corpus_excluded_names,
};
pub const Sdk = struct {
    macos_min_required: ?u32 = null,
    macos_max_allowed: ?u32 = null,
    foundation_version: ?f64 = null,
};
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
pub const corpus_excluded_names = [_][]const u8{ ".git", ".zig-cache", "zig-out" };

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
    host_tools: bool = false,
};

pub const ValidationError = error{
    SchemaMismatch,
    ToolchainMismatch,
    MissingField,
    UnprovenColdCache,
    UnprovenCacheState,
    MissingGate,
};

/// Public Darwin C ABI probes implemented in darwin_abi.c. Referenced only on macOS.
const darwin = struct {
    const GcdProbe = extern struct { status: i32, callback_ran: i32, requested_qos: u32, observed_qos: u32 };
    extern fn zcr_probe_gcd(qos_class: u32, timeout_ns: i64, out: *GcdProbe) i32;
    extern fn zcr_probe_memory_pressure_source() i32;
    extern fn zcr_probe_thermal_state() i32;
    extern fn zcr_probe_low_power_mode() i32;
    extern fn zcr_probe_power_source() i32;
    extern fn zcr_probe_sdk_versions(min_required: *i32, max_allowed: *i32) i32;
    extern fn zcr_probe_foundation_version() f64;

    const probe_ok = 0;
    const probe_unsupported = -1;
    const probe_timeout = -2;
    const qos_user_initiated: u32 = 0x19;
};

/// Captures the baseline. All returned memory belongs to `arena`.
pub fn capture(arena: Allocator, io: Io, options: Options) !Baseline {
    var sysctl: Sysctl = .{ .arena = arena };

    var corpus: Corpus = .{};
    if (options.corpus_path) |path| {
        corpus = try digestCorpus(arena, io, path, options.corpus_limits);
        if (options.corpus_id) |id| corpus.id = try arena.dupe(u8, id);
    }

    var tools: std.ArrayList(Tool) = .empty;
    for (baseline_tools) |name| try tools.append(arena, try probeTool(arena, io, options.environ, name, &.{"--version"}));
    if (options.host_tools) {
        for (host_tools) |name| try tools.append(arena, try probeTool(arena, io, options.environ, name, &.{"--version"}));
    }

    const git: ?GitProbe = if (options.repo_path) |repo| try probeGit(arena, io, options.environ, repo) else null;

    var baseline: Baseline = .{
        .captured_at_unix_ms = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, 1_000_000)),
        .source = if (git) |g| .{ .repo_path = g.repo_path, .head_commit = g.head_commit, .dirty = g.dirty } else .{},
        .compiler = try readCompiler(arena, io, options.zig_exe),
        .os = try readOs(arena, &sysctl),
        .cpu = try readCpu(&sysctl),
        .memory = try readMemory(&sysctl),
        .power = readPower(),
        .gcd = readGcd(),
        .cache = try readCache(arena, options.environ),
        .corpus = corpus,
        .sdk = readSdk(),
        .tools = tools.items,
        .git = git,
        .sysctl_keys = sysctl.keys.items,
        .gates = &.{},
        .not_run = &not_run_items,
    };
    baseline.gates = try evaluateGates(arena, &baseline);
    return baseline;
}

/// PF-001 acceptance: the record must say which compiler, OS, corpus, cache
/// state and power state a result was produced under, and carry every T00 gate.
pub fn validate(b: *const Baseline) ValidationError!void {
    if (!std.mem.eql(u8, b.schema_version, schema_version)) return error.SchemaMismatch;
    if (!std.mem.eql(u8, b.compiler.zig_version, required_zig_version)) return error.ToolchainMismatch;
    if (b.captured_at_unix_ms <= 0 or b.compiler.target.len == 0 or b.compiler.optimize.len == 0 or
        b.os.tag.len == 0 or b.os.kernel_release.len == 0) return error.MissingField;

    switch (b.corpus.status) {
        .measured => if (b.corpus.sha256 == null or b.corpus.path == null) return error.MissingField,
        .not_provided => {},
    }
    switch (b.cache.page_cache_state) {
        .unknown => {},
        .cold => if (b.cache.control_evidence == null) return error.UnprovenColdCache,
        .warm => if (b.cache.control_evidence == null) return error.UnprovenCacheState,
    }
    if (is_macos and (b.power.source == .not_applicable or
        b.power.low_power_mode == .not_applicable or
        b.power.thermal_state == .not_applicable)) return error.MissingField;

    for (required_gates) |id| {
        for (b.gates) |gate| {
            if (std.mem.eql(u8, gate.id, id)) break;
        } else return error.MissingGate;
    }
}

pub fn toJson(arena: Allocator, b: *const Baseline) ![]u8 {
    return std.json.Stringify.valueAlloc(arena, b.*, .{ .whitespace = .indent_2 });
}

/// Hashes every regular file under `path` in byte-wise path order. Symlinks and
/// special files are counted but not followed. Exceeding a limit is an error so
/// a partial corpus is never reported as complete.
pub fn digestCorpus(arena: Allocator, io: Io, path: []const u8, limits: CorpusLimits) !Corpus {
    var root = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.CorpusUnavailable,
        else => |e| return e,
    };
    defer root.close(io);

    const FileDigest = struct { path: []const u8, hex: [Sha256.digest_length * 2]u8 };
    var files: std.ArrayList(FileDigest) = .empty;
    var total_bytes: u64 = 0;
    var skipped: u64 = 0;

    var walker = try root.walkSelectively(arena);
    defer {
        // Close subdirectories still open after an early return.
        while (walker.stack.items.len > 0) walker.leave(io);
        walker.deinit();
    }
    while (try walker.next(io)) |entry| {
        if (isExcludedName(entry.basename)) continue;
        switch (entry.kind) {
            .directory => try walker.enter(io, entry),
            .file => {
                if (files.items.len >= limits.max_files) return error.CorpusTooLarge;
                const file = try entry.dir.openFile(io, entry.basename, .{});
                defer file.close(io);
                const hex = try hashOpenFile(io, file, limits.max_bytes, &total_bytes);
                try files.append(arena, .{ .path = try arena.dupe(u8, entry.path), .hex = hex });
            },
            else => skipped += 1,
        }
    }

    std.mem.sort(FileDigest, files.items, {}, struct {
        fn lessThan(_: void, a: FileDigest, b: FileDigest) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    var outer = Sha256.init(.{});
    for (files.items) |f| {
        outer.update(&f.hex);
        outer.update("  ");
        outer.update(f.path);
        outer.update("\n");
    }
    const digest = std.fmt.bytesToHex(outer.finalResult(), .lower);

    return .{
        .status = .measured,
        .path = try arena.dupe(u8, path),
        .file_count = files.items.len,
        .total_bytes = total_bytes,
        .skipped_non_regular = skipped,
        .sha256 = try arena.dupe(u8, &digest),
    };
}

pub fn probeSysctlKey(name: [:0]const u8) ProbeStatus {
    if (!is_macos) return .not_applicable;
    var len: usize = 0;
    return sysctlStatus(std.c.sysctlbyname(name.ptr, null, &len, null, 0));
}

pub fn probeCpu(arena: Allocator) !Cpu {
    var sysctl: Sysctl = .{ .arena = arena };
    return readCpu(&sysctl);
}

/// Runs the Git identity commands from docs/06 with explicit argv and `-C`,
/// never changing the process working directory or GIT_DIR.
pub fn probeGit(arena: Allocator, io: Io, environ: *const Environ.Map, repo_path: []const u8) !GitProbe {
    var probe: GitProbe = .{ .status = .absent, .repo_path = try arena.dupe(u8, repo_path) };
    const git = try findExecutable(arena, io, environ, "git") orelse return probe;
    probe.status = .present;

    const specs = [_][]const []const u8{
        &.{ "rev-parse", "--show-toplevel" },
        &.{ "rev-parse", "--absolute-git-dir" },
        &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" },
        &.{ "rev-parse", "HEAD" },
        &.{ "worktree", "list", "--porcelain", "-z" },
        &.{ "status", "--porcelain=v2", "-z", "--untracked-files=all" },
    };
    const commands = try arena.alloc(GitCommand, specs.len);
    var outputs: [specs.len]?[]const u8 = @splat(null);

    for (specs, commands, &outputs) |args, *command, *output| {
        const argv = try arena.alloc([]const u8, args.len + 3);
        argv[0] = git;
        argv[1] = "-C";
        argv[2] = repo_path;
        @memcpy(argv[3..], args);
        command.* = .{
            .argv = try std.fmt.allocPrint(arena, "git -C <repo> {s}", .{try std.mem.join(arena, " ", args)}),
            .exit_code = null,
            .stdout_sha256 = null,
        };
        const result = runCommand(arena, io, argv) catch {
            probe.status = .failed;
            continue;
        };
        command.exit_code = result.exit_code;
        command.stdout_sha256 = try hexDigest(arena, result.stdout);
        if (exitedOk(result.exit_code)) output.* = result.stdout else probe.status = .failed;
    }
    probe.commands = commands;

    probe.toplevel = trimLine(outputs[0]);
    probe.absolute_git_dir = trimLine(outputs[1]);
    probe.common_dir = trimLine(outputs[2]);
    probe.head_commit = trimLine(outputs[3]);
    if (outputs[4]) |list| probe.worktree_count = countWorktrees(list);
    if (outputs[5]) |status| probe.dirty = status.len > 0;

    if (probe.absolute_git_dir) |git_dir| if (probe.common_dir) |common_dir| {
        const real_git_dir = try Io.Dir.realPathFileAbsoluteAlloc(io, git_dir, arena);
        const real_common_dir = try Io.Dir.realPathFileAbsoluteAlloc(io, common_dir, arena);
        probe.is_linked_worktree = !std.mem.eql(u8, real_git_dir, real_common_dir);
    };
    if (probe.toplevel) |toplevel| probe.dot_git_kind = try dotGitKind(arena, io, toplevel);
    return probe;
}

/// Resolves `name` through PATH and records its first version line and digest.
pub fn probeTool(arena: Allocator, io: Io, environ: *const Environ.Map, name: []const u8, args: []const []const u8) !Tool {
    var tool: Tool = .{ .name = try arena.dupe(u8, name), .status = .absent };
    const path = try findExecutable(arena, io, environ, name) orelse return tool;
    tool.status = .failed;
    tool.path = path;
    tool.sha256 = hashFileHex(arena, io, path) catch null;

    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = path;
    @memcpy(argv[1..], args);
    const result = runCommand(arena, io, argv) catch return tool;
    if (!exitedOk(result.exit_code)) return tool;

    const stdout = std.mem.trim(u8, result.stdout, " \t\r\n");
    tool.version = trimLine(if (stdout.len > 0) result.stdout else result.stderr);
    tool.status = .present;
    return tool;
}

const Sysctl = struct {
    arena: Allocator,
    keys: std.ArrayList(KeyProbe) = .empty,

    fn record(s: *Sysctl, name: []const u8, status: ProbeStatus) !void {
        try s.keys.append(s.arena, .{ .key = try s.arena.dupe(u8, name), .status = status });
    }

    fn int(s: *Sysctl, name: [:0]const u8) !?u64 {
        var buf: [8]u8 = @splat(0);
        var len: usize = buf.len;
        const status = sysctlStatus(std.c.sysctlbyname(name.ptr, &buf, &len, null, 0));
        try s.record(name, status);
        if (status != .present) return null;
        const endian = builtin.cpu.arch.endian();
        return switch (len) {
            4 => std.mem.readInt(u32, buf[0..4], endian),
            8 => std.mem.readInt(u64, buf[0..8], endian),
            else => null,
        };
    }

    fn string(s: *Sysctl, name: [:0]const u8) !?[]const u8 {
        var len: usize = 0;
        const size_status = sysctlStatus(std.c.sysctlbyname(name.ptr, null, &len, null, 0));
        if (size_status != .present or len == 0 or len > max_sysctl_string) {
            try s.record(name, if (size_status == .present) .failed else size_status);
            return null;
        }
        const buf = try s.arena.alloc(u8, len);
        const status = sysctlStatus(std.c.sysctlbyname(name.ptr, buf.ptr, &len, null, 0));
        try s.record(name, status);
        if (status != .present) return null;
        return std.mem.sliceTo(buf[0..len], 0);
    }
};

/// Must be called immediately after sysctlbyname so errno is still meaningful.
fn sysctlStatus(rc: c_int) ProbeStatus {
    if (rc == 0) return .present;
    return switch (std.c.errno(rc)) {
        .NOENT => .absent,
        else => .failed,
    };
}

fn readCompiler(arena: Allocator, io: Io, zig_exe: ?[]const u8) !Compiler {
    return .{
        .zig_version = builtin.zig_version_string,
        .target = try std.fmt.allocPrint(arena, "{t}-{t}-{t}", .{ builtin.cpu.arch, builtin.os.tag, builtin.abi }),
        .optimize = @tagName(builtin.mode),
        .zig_exe = if (zig_exe) |p| try arena.dupe(u8, p) else null,
        .zig_exe_sha256 = if (zig_exe) |p| try hashFileHex(arena, io, p) else null,
    };
}

fn readOs(arena: Allocator, sysctl: *Sysctl) !Os {
    const uts = std.posix.uname();
    var os: Os = .{
        .tag = @tagName(builtin.os.tag),
        .kernel_release = try arena.dupe(u8, std.mem.sliceTo(&uts.release, 0)),
    };
    if (is_macos) {
        os.product_version = try sysctl.string("kern.osproductversion");
        os.build = try sysctl.string("kern.osversion");
        os.model = try sysctl.string("hw.model");
    }
    return os;
}

fn readCpu(sysctl: *Sysctl) !Cpu {
    var cpu: Cpu = .{ .arch = @tagName(builtin.cpu.arch) };
    if (!is_macos) {
        cpu.ncpu = std.Thread.getCpuCount() catch null;
        return cpu;
    }
    cpu.brand = try sysctl.string("machdep.cpu.brand_string");
    cpu.ncpu = try sysctl.int("hw.ncpu");
    cpu.physicalcpu = try sysctl.int("hw.physicalcpu");
    cpu.logicalcpu = try sysctl.int("hw.logicalcpu");

    const count = try sysctl.int("hw.nperflevels") orelse return cpu;
    const levels = try sysctl.arena.alloc(PerfLevel, @min(count, max_perflevels));
    for (levels, 0..) |*level, i| {
        var name_key: [64]u8 = undefined;
        var physical_key: [64]u8 = undefined;
        var logical_key: [64]u8 = undefined;
        level.* = .{
            .index = @intCast(i),
            .name = try sysctl.string(try std.fmt.bufPrintZ(&name_key, "hw.perflevel{d}.name", .{i})),
            .physicalcpu = try sysctl.int(try std.fmt.bufPrintZ(&physical_key, "hw.perflevel{d}.physicalcpu", .{i})),
            .logicalcpu = try sysctl.int(try std.fmt.bufPrintZ(&logical_key, "hw.perflevel{d}.logicalcpu", .{i})),
        };
    }
    cpu.nperflevels = @intCast(levels.len);
    cpu.perflevels = levels;
    return cpu;
}

fn readMemory(sysctl: *Sysctl) !Memory {
    if (!is_macos) return .{};
    return .{
        .total_bytes = try sysctl.int("hw.memsize"),
        .page_size = try sysctl.int("hw.pagesize"),
        .vm_pressure_level = try sysctl.int("kern.memorystatus_vm_pressure_level"),
        .dispatch_pressure_source = switch (darwin.zcr_probe_memory_pressure_source()) {
            1 => .present,
            darwin.probe_unsupported => .absent,
            else => .failed,
        },
    };
}

fn readPower() Power {
    if (!is_macos) return .{};
    return .{
        .source = switch (darwin.zcr_probe_power_source()) {
            1 => .ac,
            2 => .battery,
            3 => .ups,
            else => .unknown,
        },
        .low_power_mode = switch (darwin.zcr_probe_low_power_mode()) {
            0 => .disabled,
            1 => .enabled,
            else => .unknown,
        },
        .thermal_state = switch (darwin.zcr_probe_thermal_state()) {
            0 => .nominal,
            1 => .fair,
            2 => .serious,
            3 => .critical,
            else => .unknown,
        },
    };
}

fn readGcd() Gcd {
    if (!is_macos) return .{};
    var out: darwin.GcdProbe = undefined;
    const rc = darwin.zcr_probe_gcd(darwin.qos_user_initiated, gcd_timeout_ns, &out);
    const ran = rc == darwin.probe_ok and out.callback_ran == 1;
    return .{
        .status = switch (rc) {
            darwin.probe_ok => .present,
            darwin.probe_unsupported => .absent,
            else => .failed,
        },
        .callback_ran = ran,
        .timed_out = rc == darwin.probe_timeout,
        .requested_qos = qosName(out.requested_qos),
        .observed_qos = if (ran) qosName(out.observed_qos) else "",
    };
}

fn readSdk() Sdk {
    if (!is_macos) return .{};
    var min_required: i32 = 0;
    var max_allowed: i32 = 0;
    const versions_known = darwin.zcr_probe_sdk_versions(&min_required, &max_allowed) == darwin.probe_ok;
    const foundation = darwin.zcr_probe_foundation_version();
    return .{
        .macos_min_required = if (versions_known) @intCast(min_required) else null,
        .macos_max_allowed = if (versions_known) @intCast(max_allowed) else null,
        .foundation_version = if (foundation > 0) foundation else null,
    };
}

fn readCache(arena: Allocator, environ: *const Environ.Map) !Cache {
    return .{
        .zig_global_cache_dir = try dupeOptional(arena, environ.get("ZIG_GLOBAL_CACHE_DIR")),
        .zig_local_cache_dir = try dupeOptional(arena, environ.get("ZIG_LOCAL_CACHE_DIR")),
        .tmpdir = try dupeOptional(arena, environ.get("TMPDIR")),
    };
}

fn evaluateGates(arena: Allocator, b: *const Baseline) ![]const Gate {
    const gates = try arena.alloc(Gate, required_gates.len);
    gates[0] = try gateG01(arena, b);
    gates[1] = try gateG03(arena, b);
    gates[2] = try gateG04(arena, b);
    gates[3] = try gateG06(arena, b);
    return gates;
}

/// G01: Zig 0.16 compiled, linked against the macOS SDK and ran a C ABI callback.
fn gateG01(arena: Allocator, b: *const Baseline) !Gate {
    if (!is_macos) return .{ .id = "G01", .status = .not_run, .detail = "not a macOS host" };
    const zig_ok = std.mem.eql(u8, b.compiler.zig_version, required_zig_version);
    const sdk_ok = b.sdk.macos_max_allowed != null and b.sdk.foundation_version != null;
    const run_ok = b.gcd.status == .present and b.gcd.callback_ran;
    return .{
        .id = "G01",
        .status = if (zig_ok and sdk_ok and run_ok) .pass else .fail,
        .detail = try std.fmt.allocPrint(
            arena,
            "zig={s} target={s} optimize={s} macos_min_required={?d} macos_max_allowed={?d} foundation_version={?d} gcd_callback_ran={any}",
            .{ b.compiler.zig_version, b.compiler.target, b.compiler.optimize, b.sdk.macos_min_required, b.sdk.macos_max_allowed, b.sdk.foundation_version, b.gcd.callback_ran },
        ),
    };
}

/// G03: memory-pressure, thermal and low-power signals are available at runtime.
fn gateG03(arena: Allocator, b: *const Baseline) !Gate {
    if (!is_macos) return .{ .id = "G03", .status = .not_run, .detail = "not a macOS host" };
    const pressure = b.memory.dispatch_pressure_source;
    const status: GateStatus = if (pressure == .failed)
        .fail
    else if (pressure == .present and b.power.thermal_state != .unknown and b.power.low_power_mode != .unknown)
        .pass
    else
        .unknown;
    return .{
        .id = "G03",
        .status = status,
        .detail = try std.fmt.allocPrint(
            arena,
            "dispatch_memorypressure_source={t} vm_pressure_level={?d} thermal_state={t} low_power_mode={t} power_source={t}",
            .{ pressure, b.memory.vm_pressure_level, b.power.thermal_state, b.power.low_power_mode, b.power.source },
        ),
    };
}

/// G04: perflevel sysctl keys exist and add up to the total CPU counts.
fn gateG04(arena: Allocator, b: *const Baseline) !Gate {
    if (!is_macos) return .{ .id = "G04", .status = .not_run, .detail = "not a macOS host" };
    const cpu = b.cpu;
    if (cpu.nperflevels == null) return .{
        .id = "G04",
        .status = .unknown,
        .detail = "hw.nperflevels absent; policy must fall back to total CPU count",
    };

    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(arena, try std.fmt.allocPrint(arena, "nperflevels={d} physicalcpu={?d} logicalcpu={?d}", .{ cpu.perflevels.len, cpu.physicalcpu, cpu.logicalcpu }));
    var physical_sum: u64 = 0;
    var logical_sum: u64 = 0;
    var complete = true;
    for (cpu.perflevels) |level| {
        if (level.name == null or level.physicalcpu == null or level.logicalcpu == null) complete = false;
        physical_sum += level.physicalcpu orelse 0;
        logical_sum += level.logicalcpu orelse 0;
        try parts.append(arena, try std.fmt.allocPrint(arena, "perflevel{d}={s}:{?d}/{?d}", .{ level.index, level.name orelse "?", level.physicalcpu, level.logicalcpu }));
    }
    const sums_match = cpu.physicalcpu != null and cpu.logicalcpu != null and
        physical_sum == cpu.physicalcpu.? and logical_sum == cpu.logicalcpu.?;
    return .{
        .id = "G04",
        .status = if (complete and sums_match) .pass else .fail,
        .detail = try std.mem.join(arena, " ", parts.items),
    };
}

/// G06: Git worktree identity commands run with the recorded Git version.
fn gateG06(arena: Allocator, b: *const Baseline) !Gate {
    const git = b.git orelse return .{ .id = "G06", .status = .not_run, .detail = "no repository path provided" };
    var version: []const u8 = "unknown";
    for (b.tools) |tool| {
        if (std.mem.eql(u8, tool.name, "git")) version = tool.version orelse "unknown";
    }
    const status: GateStatus = switch (git.status) {
        .present => if (git.toplevel != null and git.common_dir != null and git.worktree_count != null) .pass else .fail,
        .absent, .failed => .fail,
        .not_applicable => .not_run,
    };
    return .{
        .id = "G06",
        .status = status,
        .detail = try std.fmt.allocPrint(
            arena,
            "{s}; probe={t} linked_worktree={?any} dot_git={t} worktrees={?d} dirty={?any}",
            .{ version, git.status, git.is_linked_worktree, git.dot_git_kind, git.worktree_count, git.dirty },
        ),
    };
}

const CommandResult = struct { exit_code: ?u8, stdout: []u8, stderr: []u8 };

fn runCommand(arena: Allocator, io: Io, argv: []const []const u8) !CommandResult {
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(command_timeout_ms), .clock = .awake } },
    });
    return .{
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => null,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn exitedOk(code: ?u8) bool {
    return if (code) |c| c == 0 else false;
}

fn findExecutable(arena: Allocator, io: Io, environ: *const Environ.Map, name: []const u8) !?[]const u8 {
    const path_var = environ.get("PATH") orelse return null;
    var dirs = std.mem.tokenizeScalar(u8, path_var, ':');
    while (dirs.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(arena, &.{ dir, name });
        const stat = Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (stat.kind != .file or stat.permissions.toMode() & 0o111 == 0) continue;
        return candidate;
    }
    return null;
}

fn hashOpenFile(io: Io, file: Io.File, limit: ?u64, total: *u64) ![Sha256.digest_length * 2]u8 {
    var hasher = Sha256.init(.{});
    var reader_buf: [hash_chunk_bytes]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buf);
    var chunk: [hash_chunk_bytes]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        hasher.update(chunk[0..n]);
        total.* += n;
        if (limit) |max| if (total.* > max) return error.CorpusTooLarge;
        if (n < chunk.len) break;
    }
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

fn hashFileHex(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    const file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var total: u64 = 0;
    const hex = try hashOpenFile(io, file, null, &total);
    return arena.dupe(u8, &hex);
}

fn hexDigest(arena: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return arena.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

fn dotGitKind(arena: Allocator, io: Io, toplevel: []const u8) !GitFileKind {
    const path = try std.fs.path.join(arena, &.{ toplevel, ".git" });
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => |e| return e,
    };
    return switch (stat.kind) {
        .file => .file,
        .directory => .directory,
        else => .other,
    };
}

/// `git worktree list --porcelain -z` emits NUL-terminated attributes; each
/// worktree record starts with a "worktree <path>" attribute.
fn countWorktrees(list: []const u8) u32 {
    var count: u32 = 0;
    var fields = std.mem.tokenizeScalar(u8, list, 0);
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "worktree ")) count += 1;
    }
    return count;
}

fn trimLine(bytes: ?[]const u8) ?[]const u8 {
    const text = bytes orelse return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const line = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
    return if (line.len == 0) null else std.mem.trimEnd(u8, line, "\r");
}

fn isExcludedName(name: []const u8) bool {
    for (corpus_excluded_names) |excluded| {
        if (std.mem.eql(u8, name, excluded)) return true;
    }
    return false;
}

fn dupeOptional(arena: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try arena.dupe(u8, v) else null;
}

fn qosName(qos_class: u32) []const u8 {
    return switch (qos_class) {
        0x21 => "user_interactive",
        0x19 => "user_initiated",
        0x15 => "default",
        0x11 => "utility",
        0x09 => "background",
        0x00 => "unspecified",
        else => "unrecognized",
    };
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var options: Options = .{ .environ = init.environ_map };
    var out_path: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--repo")) {
            options.repo_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            options.corpus_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--corpus-id")) {
            options.corpus_id = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--zig")) {
            options.zig_exe = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--host-tools")) {
            options.host_tools = true;
        } else return usage();
    }

    const baseline = try capture(arena, io, options);
    const json = try toJson(arena, &baseline);
    if (out_path) |path| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
    } else {
        try Io.File.stdout().writeStreamingAll(io, json);
    }

    validate(&baseline) catch |err| {
        std.log.err("PF-001 baseline incomplete: {t}", .{err});
        return 2;
    };
    return 0;
}

fn usage() u8 {
    std.log.err("usage: caps [--repo DIR] [--corpus DIR [--corpus-id ID]] [--zig PATH] [--host-tools] [--out FILE]", .{});
    return 64;
}
