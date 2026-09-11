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

fn runOk(arena: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .expand_arg0 = .expand, // resolve "git" through PATH
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

    var env = try testing.environ.createMap(arena);

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
