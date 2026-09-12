//! T00 tests: PF-001 baseline capture and the G01/G03/G04/G06 platform probes.
//!
//! Build runner does not exist before T01, so this file is compiled directly:
//! see bench/baseline.md "Test command".

const std = @import("std");
const builtin = @import("builtin");
const caps = @import("caps");

const testing = std.testing;
const io = testing.io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const fixture_files = [_]struct { path: []const u8, bytes: []const u8 }{
    .{ .path = "a.txt", .bytes = "alpha\n" },
    .{ .path = "sub/b.txt", .bytes = "beta\r\nline2" },
    .{ .path = "sub/deeper/c.bin", .bytes = "\x00\xff\xfe\x01" },
};

fn writeFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "sub/deeper");
    for (fixture_files) |f| try dir.writeFile(io, .{ .sub_path = f.path, .data = f.bytes });
}

/// Independent oracle for the corpus digest: sha256 over sorted
/// "<sha256hex>  <relative path>\n" lines, the same shape `shasum -a 256` prints.
fn expectedCorpusDigest() [64]u8 {
    var outer = Sha256.init(.{});
    // fixture_files is already sorted by byte-wise path order.
    for (fixture_files) |f| {
        var d: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(f.bytes, &d, .{});
        const hex = std.fmt.bytesToHex(d, .lower);
        outer.update(&hex);
        outer.update("  ");
        outer.update(f.path);
        outer.update("\n");
    }
    return std.fmt.bytesToHex(outer.finalResult(), .lower);
}

fn fixtureTotalBytes() u64 {
    var total: u64 = 0;
    for (fixture_files) |f| total += f.bytes.len;
    return total;
}

fn findGate(b: *const caps.Baseline, id: []const u8) ?caps.Gate {
    for (b.gates) |g| if (std.mem.eql(u8, g.id, id)) return g;
    return null;
}

test "PF-001 baseline capture records compiler, OS, corpus, cache and power" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const corpus_path = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var env = try testing.environ.createMap(arena);
    const baseline = try caps.capture(arena, io, .{
        .corpus_path = corpus_path,
        .corpus_id = "t00-fixture",
        .environ = &env,
    });
    try caps.validate(&baseline);

    // compiler
    try testing.expectEqualStrings("0.16.0", baseline.compiler.zig_version);
    try testing.expectEqualStrings(@tagName(builtin.mode), baseline.compiler.optimize);
    try testing.expect(baseline.compiler.target.len > 0);

    // OS
    try testing.expectEqualStrings(@tagName(builtin.os.tag), baseline.os.tag);
    try testing.expect(baseline.os.kernel_release.len > 0);
    if (builtin.os.tag == .macos) {
        try testing.expect(baseline.os.product_version != null);
        try testing.expect(baseline.os.build != null);
    }

    // corpus: measured with the independent oracle
    try testing.expectEqual(caps.CorpusStatus.measured, baseline.corpus.status);
    try testing.expectEqualStrings("t00-fixture", baseline.corpus.id.?);
    try testing.expectEqual(@as(u64, fixture_files.len), baseline.corpus.file_count);
    try testing.expectEqual(fixtureTotalBytes(), baseline.corpus.total_bytes);
    const expected = expectedCorpusDigest();
    try testing.expectEqualStrings(&expected, baseline.corpus.sha256.?);

    // cache: page cache state cannot be controlled here, so it must say unknown
    try testing.expectEqual(caps.PageCacheState.unknown, baseline.cache.page_cache_state);

    // power: recorded as a concrete state or an explicit unknown, never omitted
    if (builtin.os.tag == .macos) {
        try testing.expect(baseline.power.thermal_state != .not_applicable);
        try testing.expect(baseline.power.low_power_mode != .not_applicable);
        try testing.expect(baseline.power.source != .not_applicable);
    } else {
        try testing.expectEqual(caps.ThermalState.not_applicable, baseline.power.thermal_state);
    }

    // gates owned by T00 are all recorded
    for ([_][]const u8{ "G01", "G03", "G04", "G06" }) |id| {
        try testing.expect(findGate(&baseline, id) != null);
    }

    // JSON artifact keeps the PF-001 fields
    const json = try caps.toJson(arena, &baseline);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    for ([_][]const u8{ "schema_version", "compiler", "os", "corpus", "cache", "power", "gates" }) |key| {
        try testing.expect(parsed.object.get(key) != null);
    }
    try testing.expectEqualStrings(caps.schema_version, parsed.object.get("schema_version").?.string);
}

test "PF-001 corpus not provided is recorded explicitly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = try testing.environ.createMap(arena);
    const baseline = try caps.capture(arena, io, .{ .environ = &env });
    try caps.validate(&baseline);
    try testing.expectEqual(caps.CorpusStatus.not_provided, baseline.corpus.status);
    try testing.expect(baseline.corpus.sha256 == null);
}

test "PF-001 unavailable corpus path is an error, not an empty corpus" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const missing = try std.fmt.allocPrint(arena, "{s}/does-not-exist", .{base});

    var env = try testing.environ.createMap(arena);
    try testing.expectError(error.CorpusUnavailable, caps.capture(arena, io, .{
        .corpus_path = missing,
        .environ = &env,
    }));
}

test "PF-001 corpus limits are enforced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const corpus_path = try tmp.dir.realPathFileAlloc(io, ".", arena);

    try testing.expectError(error.CorpusTooLarge, caps.digestCorpus(arena, io, corpus_path, .{ .max_files = 2 }));
    try testing.expectError(error.CorpusTooLarge, caps.digestCorpus(arena, io, corpus_path, .{ .max_bytes = 4 }));
}

test "PF-001 validate rejects cold-cache claims without control evidence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = try testing.environ.createMap(arena);
    var baseline = try caps.capture(arena, io, .{ .environ = &env });
    baseline.cache.page_cache_state = .cold;
    baseline.cache.control_evidence = null;
    try testing.expectError(error.UnprovenColdCache, caps.validate(&baseline));
}

test "PF-001 validate rejects a baseline without every T00 gate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = try testing.environ.createMap(arena);
    var baseline = try caps.capture(arena, io, .{ .environ = &env });
    var kept: std.ArrayList(caps.Gate) = .empty;
    for (baseline.gates) |g| {
        if (!std.mem.eql(u8, g.id, "G06")) try kept.append(arena, g);
    }
    baseline.gates = kept.items;
    try testing.expectError(error.MissingGate, caps.validate(&baseline));
}

test "PF-001 validate rejects a wrong compiler version" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = try testing.environ.createMap(arena);
    var baseline = try caps.capture(arena, io, .{ .environ = &env });
    baseline.compiler.zig_version = "0.15.2";
    try testing.expectError(error.ToolchainMismatch, caps.validate(&baseline));
}

test "G04 sysctl probe distinguishes present and absent keys" {
    if (builtin.os.tag != .macos) {
        try testing.expectEqual(caps.ProbeStatus.not_applicable, caps.probeSysctlKey("hw.ncpu"));
        return;
    }
    try testing.expectEqual(caps.ProbeStatus.present, caps.probeSysctlKey("hw.ncpu"));
    try testing.expectEqual(caps.ProbeStatus.absent, caps.probeSysctlKey("hw.zcr_t00_nonexistent_key"));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cpu = try caps.probeCpu(arena);
    try testing.expect(cpu.ncpu != null);
    if (cpu.nperflevels) |n| {
        try testing.expectEqual(@as(usize, n), cpu.perflevels.len);
        var physical_sum: u64 = 0;
        for (cpu.perflevels, 0..) |level, i| {
            try testing.expectEqual(@as(u32, @intCast(i)), level.index);
            physical_sum += level.physicalcpu orelse 0;
        }
        try testing.expectEqual(cpu.physicalcpu.?, physical_sum);
    }
}

// Fixture mutations use a system-owned executable and never inherit Git controls.
fn trustedGit() ![]const u8 {
    for ([_][]const u8{ "/usr/bin/git", "/bin/git" }) |candidate| {
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (stat.kind == .file and stat.permissions.toMode() & 0o111 != 0) return candidate;
    }
    return error.TrustedFixtureGitUnavailable;
}

fn fixtureEnvironment(arena: std.mem.Allocator, inherited: *const std.process.Environ.Map, empty_template: []const u8) !std.process.Environ.Map {
    var clean = std.process.Environ.Map.init(arena);
    var entries = inherited.iterator();
    while (entries.next()) |entry| {
        if (std.ascii.startsWithIgnoreCase(entry.key_ptr.*, "GIT_")) continue;
        try clean.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    try clean.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try clean.put("GIT_CONFIG_NOSYSTEM", "1");
    try clean.put("GIT_TERMINAL_PROMPT", "0");
    try clean.put("GIT_AUTHOR_NAME", "t00");
    try clean.put("GIT_AUTHOR_EMAIL", "t00@example.invalid");
    try clean.put("GIT_COMMITTER_NAME", "t00");
    try clean.put("GIT_COMMITTER_EMAIL", "t00@example.invalid");
    const keys = [_][]const u8{ "core.hooksPath", "commit.gpgSign", "tag.gpgSign", "init.templateDir", "core.attributesFile", "core.excludesFile" };
    const values = [_][]const u8{ "/dev/null", "false", "false", empty_template, "/dev/null", "/dev/null" };
    try clean.put("GIT_CONFIG_COUNT", "6");
    for (keys, values, 0..) |key, value, i| {
        try clean.put(try std.fmt.allocPrint(arena, "GIT_CONFIG_KEY_{d}", .{i}), key);
        try clean.put(try std.fmt.allocPrint(arena, "GIT_CONFIG_VALUE_{d}", .{i}), value);
    }
    return clean;
}

fn runOk(arena: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    var inherited = try testing.environ.createMap(arena);
    return runOkFromEnvironment(arena, cwd, argv, &inherited);
}

fn runOkFromEnvironment(arena: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, inherited: *const std.process.Environ.Map) !void {
    std.debug.assert(argv.len > 0 and std.mem.eql(u8, argv[0], "git"));
    var empty_template = testing.tmpDir(.{});
    defer empty_template.cleanup();
    var env = try fixtureEnvironment(arena, inherited, try empty_template.dir.realPathFileAlloc(io, ".", arena));
    const trusted_argv = try arena.dupe([]const u8, argv);
    trusted_argv[0] = try trustedGit();
    const result = try std.process.run(arena, io, .{
        .argv = trusted_argv,
        .cwd = .{ .path = cwd },
        .environ_map = &env,
    });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("command failed ({d}): {s} {s}\n{s}\n", .{ code, argv[0], argv[1], result.stderr });
            return error.FixtureCommandFailed;
        },
        else => return error.FixtureCommandFailed,
    }
}

test "G06 git probe identifies main and linked worktrees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/file.txt", .data = "x\n" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const repo = try std.fmt.allocPrint(arena, "{s}/repo", .{base});
    const linked = try std.fmt.allocPrint(arena, "{s}/linked", .{base});

    const git_id = [_][]const u8{ "git", "-c", "user.name=t00", "-c", "user.email=t00@example.invalid", "-c", "commit.gpgsign=false" };
    try runOk(arena, repo, &.{ "git", "init", "-q", "-b", "main" });
    try runOk(arena, repo, &.{ "git", "add", "file.txt" });
    try runOk(arena, repo, &(git_id ++ [_][]const u8{ "commit", "-q", "-m", "fixture" }));
    try runOk(arena, repo, &.{ "git", "worktree", "add", "-q", "-b", "linked", linked });

    var inherited = try testing.environ.createMap(arena);
    try tmp.dir.createDirPath(io, "empty-template");
    var env = try fixtureEnvironment(arena, &inherited, try std.fs.path.join(arena, &.{ base, "empty-template" }));
    // probeGit intentionally exercises PATH discovery; restrict this fixture probe to trusted directories.
    try env.put("PATH", "/usr/bin:/bin");

    const main_probe = try caps.probeGit(arena, io, &env, repo);
    try testing.expectEqual(caps.ProbeStatus.present, main_probe.status);
    try testing.expectEqual(false, main_probe.is_linked_worktree.?);
    try testing.expectEqual(caps.GitFileKind.directory, main_probe.dot_git_kind);
    try testing.expectEqual(@as(u32, 2), main_probe.worktree_count.?);
    for (main_probe.commands) |cmd| try testing.expectEqual(@as(?u8, 0), cmd.exit_code);

    const linked_probe = try caps.probeGit(arena, io, &env, linked);
    try testing.expectEqual(true, linked_probe.is_linked_worktree.?);
    try testing.expectEqual(caps.GitFileKind.file, linked_probe.dot_git_kind);
    try testing.expectEqualStrings(main_probe.common_dir.?, linked_probe.common_dir.?);
    try testing.expect(!std.mem.eql(u8, main_probe.absolute_git_dir.?, linked_probe.absolute_git_dir.?));
    try testing.expectEqualStrings(main_probe.head_commit.?, linked_probe.head_commit.?);
}

test "G03 darwin probes report a known state or an explicit unknown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = try testing.environ.createMap(arena);
    const baseline = try caps.capture(arena, io, .{ .environ = &env });

    if (builtin.os.tag != .macos) {
        try testing.expectEqual(caps.ProbeStatus.not_applicable, baseline.gcd.status);
        try testing.expectEqual(caps.ProbeStatus.not_applicable, baseline.memory.dispatch_pressure_source);
        return;
    }
    // GCD public C ABI: the callback ran on a queue created with USER_INITIATED QoS.
    try testing.expectEqual(caps.ProbeStatus.present, baseline.gcd.status);
    try testing.expectEqual(true, baseline.gcd.callback_ran);
    try testing.expectEqualStrings("user_initiated", baseline.gcd.requested_qos);
    try testing.expect(baseline.gcd.observed_qos.len > 0);
    // Dispatch memory-pressure source is creatable with this SDK.
    try testing.expectEqual(caps.ProbeStatus.present, baseline.memory.dispatch_pressure_source);
    // SDK versions seen by the C compiler are recorded.
    try testing.expect(baseline.sdk.macos_min_required != null);
    try testing.expect(baseline.sdk.macos_max_allowed != null);
    const g03 = findGate(&baseline, "G03").?;
    try testing.expect(g03.status != .not_run);
}

test "B0/B1 tool probe reports absent tools explicitly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = try testing.environ.createMap(arena);
    const missing = try caps.probeTool(arena, io, &env, "zcr-t00-definitely-missing-tool", &.{"--version"});
    try testing.expectEqual(caps.ProbeStatus.absent, missing.status);
    try testing.expect(missing.path == null);

    const git = try caps.probeTool(arena, io, &env, "git", &.{"--version"});
    try testing.expectEqual(caps.ProbeStatus.present, git.status);
    try testing.expect(std.mem.startsWith(u8, git.version.?, "git version "));
    try testing.expectEqual(@as(usize, 64), git.sha256.?.len);
}

test "G06 fixture hostile Git environment cannot redirect mutations into a sentinel" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const sentinel = try std.fs.path.join(arena, &.{ base, "sentinel" });
    const target = try std.fs.path.join(arena, &.{ base, "target" });
    try tmp.dir.createDirPath(io, "sentinel");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.createDirPath(io, "hostile-empty-template");
    try tmp.dir.writeFile(io, .{ .sub_path = "sentinel/tracked.txt", .data = "sentinel original\n" });
    var clean = std.process.Environ.Map.init(arena);
    try clean.put("PATH", "/usr/bin:/bin");
    try clean.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try clean.put("GIT_CONFIG_NOSYSTEM", "1");
    const identity = [_][]const u8{ "git", "-c", "user.name=t00", "-c", "user.email=t00@example.invalid", "-c", "commit.gpgSign=false" };
    try runOkFromEnvironment(arena, sentinel, &.{ "git", "init", "-q", "-b", "sentinel" }, &clean);
    try runOkFromEnvironment(arena, sentinel, &.{ "git", "add", "." }, &clean);
    try runOkFromEnvironment(arena, sentinel, &(identity ++ [_][]const u8{ "commit", "-q", "-m", "sentinel base" }), &clean);
    try tmp.dir.writeFile(io, .{ .sub_path = "sentinel/untracked.txt", .data = "remain untracked\n" });
    const before = try caps.probeGit(arena, io, &clean, sentinel);
    const before_index = try tmp.dir.readFileAlloc(io, "sentinel/.git/index", arena, .limited(1 << 20));
    const before_config = try tmp.dir.readFileAlloc(io, "sentinel/.git/config", arena, .limited(1 << 20));

    var hostile = try clean.clone(arena);
    try hostile.put("GIT_DIR", try std.fs.path.join(arena, &.{ sentinel, ".git" }));
    try hostile.put("GIT_WORK_TREE", sentinel);
    try hostile.put("GIT_INDEX_FILE", try std.fs.path.join(arena, &.{ sentinel, ".git/index" }));
    try hostile.put("GIT_CONFIG", try std.fs.path.join(arena, &.{ sentinel, ".git/config" }));
    try hostile.put("GIT_CONFIG_COUNT", "1");
    try hostile.put("GIT_CONFIG_KEY_0", "core.worktree");
    try hostile.put("GIT_CONFIG_VALUE_0", sentinel);
    try hostile.put("GIT_TEMPLATE_DIR", try std.fs.path.join(arena, &.{ base, "hostile-empty-template" }));
    try hostile.put("GIT_FUTURE_UNRECOGNIZED_OVERRIDE", "must be removed too");
    try hostile.put("PATH", try std.fs.path.join(arena, &.{ base, "untrusted-bin" }));
    try hostile.put("ZCR_FIXTURE_HOST_VALUE", "preserved");
    var sanitized = try fixtureEnvironment(arena, &hostile, try std.fs.path.join(arena, &.{ base, "hostile-empty-template" }));
    try testing.expectEqualStrings("preserved", sanitized.get("ZCR_FIXTURE_HOST_VALUE").?);
    try testing.expectEqualStrings(hostile.get("PATH").?, sanitized.get("PATH").?);
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG", "GIT_FUTURE_UNRECOGNIZED_OVERRIDE" }) |key| try testing.expect(sanitized.get(key) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "target/fixture-only.txt", .data = "target only\n" });
    try runOkFromEnvironment(arena, target, &.{ "git", "init", "-q", "-b", "target" }, &hostile);
    try runOkFromEnvironment(arena, target, &.{ "git", "config", "fixture.probe", "target-only" }, &hostile);
    try runOkFromEnvironment(arena, target, &.{ "git", "add", "." }, &hostile);
    try runOkFromEnvironment(arena, target, &(identity ++ [_][]const u8{ "commit", "-q", "-m", "target fixture mutation" }), &hostile);

    const after = try caps.probeGit(arena, io, &clean, sentinel);
    try testing.expectEqualStrings(before.head_commit.?, after.head_commit.?);
    try testing.expectEqualSlices(u8, before_index, try tmp.dir.readFileAlloc(io, "sentinel/.git/index", arena, .limited(1 << 20)));
    try testing.expectEqualSlices(u8, before_config, try tmp.dir.readFileAlloc(io, "sentinel/.git/config", arena, .limited(1 << 20)));
    try testing.expectEqualStrings("remain untracked\n", try tmp.dir.readFileAlloc(io, "sentinel/untracked.txt", arena, .limited(1024)));
    try testing.expectEqualStrings("sentinel original\n", try tmp.dir.readFileAlloc(io, "sentinel/tracked.txt", arena, .limited(1024)));
    const target_probe = try caps.probeGit(arena, io, &clean, target);
    try testing.expectEqual(caps.GitFileKind.directory, target_probe.dot_git_kind);
    try testing.expect(!std.mem.eql(u8, before.absolute_git_dir.?, target_probe.absolute_git_dir.?));
}
