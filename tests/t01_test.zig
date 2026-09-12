//! T01 tests: development scope baseline (DV-001, DV-004, DV-005) and the
//! frozen core contract (types, errors, limits against contracts/ and config/).
//!
//! Run through the build runner: `zig build test -Dtest-group=dev`.

const std = @import("std");
const core = @import("zcr_core");
const evidence = @import("evidence");
const build_options = @import("build_options");

const testing = std.testing;
const io = testing.io;
const Allocator = std.mem.Allocator;

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
    try clean.put("GIT_AUTHOR_NAME", "t01");
    try clean.put("GIT_AUTHOR_EMAIL", "t01@example.invalid");
    try clean.put("GIT_COMMITTER_NAME", "t01");
    try clean.put("GIT_COMMITTER_EMAIL", "t01@example.invalid");
    const keys = [_][]const u8{ "core.hooksPath", "commit.gpgSign", "tag.gpgSign", "init.templateDir", "core.attributesFile", "core.excludesFile" };
    const values = [_][]const u8{ "/dev/null", "false", "false", empty_template, "/dev/null", "/dev/null" };
    try clean.put("GIT_CONFIG_COUNT", "6");
    for (keys, values, 0..) |key, value, i| {
        try clean.put(try std.fmt.allocPrint(arena, "GIT_CONFIG_KEY_{d}", .{i}), key);
        try clean.put(try std.fmt.allocPrint(arena, "GIT_CONFIG_VALUE_{d}", .{i}), value);
    }
    return clean;
}

/// A throwaway Git repository with Git configuration isolated from the user's.
const Fixture = struct {
    arena: Allocator,
    tmp: testing.TmpDir,
    root: []const u8,
    env: std.process.Environ.Map,
    git: evidence.Git,

    fn init(arena: Allocator) !*Fixture {
        var inherited = try testing.environ.createMap(arena);
        return initFromEnvironment(arena, &inherited);
    }

    fn initFromEnvironment(arena: Allocator, inherited: *const std.process.Environ.Map) !*Fixture {
        const f = try arena.create(Fixture);
        f.arena = arena;
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        f.root = try f.tmp.dir.realPathFileAlloc(io, ".", arena);
        try f.tmp.dir.createDirPath(io, "empty-template");
        f.env = try fixtureEnvironment(arena, inherited, try f.path("empty-template"));
        f.git = .{ .exe = try trustedGit(), .environ = &f.env };
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }

    fn path(f: *Fixture, sub: []const u8) ![]const u8 {
        return std.fs.path.join(f.arena, &.{ f.root, sub });
    }

    fn write(f: *Fixture, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |dir| try f.tmp.dir.createDirPath(io, dir);
        try f.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    fn read(f: *Fixture, sub: []const u8) ![]const u8 {
        return f.tmp.dir.readFileAlloc(io, sub, f.arena, .limited(1 << 20));
    }

    fn exists(f: *Fixture, sub: []const u8) bool {
        _ = f.tmp.dir.statFile(io, sub, .{}) catch return false;
        return true;
    }

    /// Runs git in `cwd_sub` and returns stdout; any non-zero exit fails the test.
    fn run(f: *Fixture, cwd_sub: []const u8, args: []const []const u8) ![]const u8 {
        const argv = try f.arena.alloc([]const u8, args.len + 1);
        argv[0] = f.git.exe;
        @memcpy(argv[1..], args);
        const result = try std.process.run(f.arena, io, .{
            .argv = argv,
            .cwd = .{ .path = try f.path(cwd_sub) },
            .environ_map = &f.env,
        });
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        std.debug.print("git {s} failed in {s}: {s}\n", .{ args[0], cwd_sub, result.stderr });
        return error.FixtureGitFailed;
    }

    fn head(f: *Fixture, cwd_sub: []const u8) ![]const u8 {
        return std.mem.trim(u8, try f.run(cwd_sub, &.{ "rev-parse", "HEAD" }), "\n");
    }

    /// repo/ with one commit containing a.txt, b.txt, c.txt and contracts/api.json.
    fn initRepo(f: *Fixture) !void {
        try f.write("repo/a.txt", "alpha\n");
        try f.write("repo/b.txt", "beta\n");
        try f.write("repo/c.txt", "gamma\n");
        try f.write("repo/contracts/api.json", "{\"v\":1}\n");
        _ = try f.run("repo", &.{ "init", "-q", "-b", "main" });
        _ = try f.run("repo", &.{ "add", "." });
        _ = try f.run("repo", &.{ "commit", "-q", "-m", "base" });
    }

    fn commitFile(f: *Fixture, cwd_sub: []const u8, file: []const u8, data: []const u8, message: []const u8) ![]const u8 {
        try f.write(try std.fs.path.join(f.arena, &.{ cwd_sub, file }), data);
        _ = try f.run(cwd_sub, &.{ "add", file });
        _ = try f.run(cwd_sub, &.{ "commit", "-q", "-m", message });
        return f.head(cwd_sub);
    }
};

fn hasEntry(state: evidence.WorktreeState, kind: evidence.DirtyKind, path: []const u8) bool {
    for (state.entries) |entry| {
        if (entry.kind == kind and std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- DV-001

test "DV-001 dirty base worktree fails preflight and user changes are preserved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();

    // User work in progress: modified, deleted, staged rename, untracked, name with spaces.
    try f.write("repo/a.txt", "alpha edited by user\n");
    try f.tmp.dir.deleteFile(io, "repo/b.txt");
    _ = try f.run("repo", &.{ "mv", "c.txt", "c renamed.txt" });
    try f.write("repo/notes draft.md", "untracked user notes\n");

    const status_before = try f.run("repo", &.{ "status", "--porcelain=v2", "-z", "--untracked-files=all" });
    const head_before = try f.head("repo");

    const result = try evidence.preflight(f.arena, io, f.git, try f.path("repo"));
    try testing.expect(!result.ok);
    try testing.expect(!result.state.isClean());
    try testing.expect(hasEntry(result.state, .modified, "a.txt"));
    try testing.expect(hasEntry(result.state, .deleted, "b.txt"));
    try testing.expect(hasEntry(result.state, .renamed, "c renamed.txt"));
    try testing.expect(hasEntry(result.state, .untracked, "notes draft.md"));
    for (result.state.entries) |entry| {
        if (entry.kind == .renamed) try testing.expectEqualStrings("c.txt", entry.orig_path.?);
    }
    try testing.expect(result.reasons.len > 0);

    // Nothing was stashed, reset, checked out or cleaned.
    try testing.expectEqualStrings(status_before, try f.run("repo", &.{ "status", "--porcelain=v2", "-z", "--untracked-files=all" }));
    try testing.expectEqualStrings(head_before, try f.head("repo"));
    try testing.expectEqualStrings("", try f.run("repo", &.{ "stash", "list" }));
    try testing.expectEqualStrings("alpha edited by user\n", try f.read("repo/a.txt"));
    try testing.expectEqualStrings("untracked user notes\n", try f.read("repo/notes draft.md"));
    try testing.expect(!f.exists("repo/b.txt"));
}

test "DV-001 clean task worktree passes preflight with its identity recorded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    _ = try f.run("repo", &.{ "worktree", "add", "-q", "-b", "task-t99", try f.path("task-t99") });

    const result = try evidence.preflight(f.arena, io, f.git, try f.path("task-t99"));
    try testing.expect(result.ok);
    try testing.expect(result.state.isClean());
    try testing.expectEqualStrings(try f.head("repo"), result.state.head_commit);
    try testing.expectEqualStrings("task-t99", result.state.branch.?);
    try testing.expect(!std.mem.eql(u8, result.state.absolute_git_dir, result.state.common_dir));
}

// ---------------------------------------------------------------- DV-004

fn writeBinary(f: *Fixture, sub: []const u8, bytes: []const u8) ![]const u8 {
    try f.write(sub, bytes);
    return f.path(sub);
}

test "DV-004 evidence produced in another worktree is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    _ = try f.run("repo", &.{ "worktree", "add", "-q", "-b", "other", try f.path("other") });

    // Both worktrees are clean and at the same commit and tree: HEAD alone cannot tell them apart.
    try testing.expectEqualStrings(try f.head("repo"), try f.head("other"));

    const binary = try writeBinary(f, "state/other/bin/test-binary", "binary built in other worktree");
    const ev = try evidence.record(f.arena, io, f.git, try f.path("other"), .{
        .task_id = "T99",
        .label = "green-debug",
        .command = "zig build test -Dtest-group=dev",
        .exit_code = 0,
        .binary_path = binary,
    });
    try evidence.verify(f.arena, io, f.git, try f.path("other"), &ev);
    try testing.expectError(error.WorktreeMismatch, evidence.verify(f.arena, io, f.git, try f.path("repo"), &ev));
}

test "DV-004 evidence for an older source commit is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();

    const binary = try writeBinary(f, "state/bin/test-binary", "binary v1");
    const ev = try evidence.record(f.arena, io, f.git, try f.path("repo"), .{
        .task_id = "T99",
        .label = "green-debug",
        .command = "zig build test",
        .exit_code = 0,
        .binary_path = binary,
    });
    _ = try f.commitFile("repo", "a.txt", "alpha v2\n", "change after evidence");
    try testing.expectError(error.SourceCommitMismatch, evidence.verify(f.arena, io, f.git, try f.path("repo"), &ev));
}

test "DV-004 evidence whose binary was replaced is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();

    const binary = try writeBinary(f, "state/bin/test-binary", "binary v1");
    const ev = try evidence.record(f.arena, io, f.git, try f.path("repo"), .{
        .task_id = "T99",
        .label = "green-debug",
        .command = "zig build test",
        .exit_code = 0,
        .binary_path = binary,
    });
    _ = try writeBinary(f, "state/bin/test-binary", "binary from a different build");
    try testing.expectError(error.BinaryDigestMismatch, evidence.verify(f.arena, io, f.git, try f.path("repo"), &ev));
}

test "DV-004 evidence is neither recorded nor accepted on a dirty worktree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();

    const binary = try writeBinary(f, "state/bin/test-binary", "binary v1");
    const input: evidence.RecordInput = .{
        .task_id = "T99",
        .label = "green-debug",
        .command = "zig build test",
        .exit_code = 0,
        .binary_path = binary,
    };
    const ev = try evidence.record(f.arena, io, f.git, try f.path("repo"), input);

    try f.write("repo/a.txt", "uncommitted edit\n");
    try testing.expectError(error.DirtyWorktree, evidence.record(f.arena, io, f.git, try f.path("repo"), input));
    try testing.expectError(error.DirtyWorktree, evidence.verify(f.arena, io, f.git, try f.path("repo"), &ev));
}

test "DV-004 evidence survives a JSON round trip and still binds to its source" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();

    const binary = try writeBinary(f, "state/bin/test-binary", "binary v1");
    const ev = try evidence.record(f.arena, io, f.git, try f.path("repo"), .{
        .task_id = "T99",
        .label = "green-releasesafe",
        .command = "zig build test -Doptimize=ReleaseSafe",
        .exit_code = 0,
        .binary_path = binary,
    });
    try testing.expectEqualStrings(try f.head("repo"), ev.source_commit);
    try testing.expectEqual(@as(usize, 64), ev.binary_sha256.len);

    const json = try evidence.evidenceToJson(f.arena, &ev);
    const parsed = try evidence.parseEvidence(f.arena, json);
    try evidence.verify(f.arena, io, f.git, try f.path("repo"), &parsed);

    const tampered = try std.mem.replaceOwned(u8, f.arena, json, ev.source_commit, "0000000000000000000000000000000000000000");
    try testing.expectError(error.SourceCommitMismatch, evidence.verify(f.arena, io, f.git, try f.path("repo"), &(try evidence.parseEvidence(f.arena, tampered))));
}

// ---------------------------------------------------------------- DV-005

fn ledgerPath(f: *Fixture) ![]const u8 {
    return f.path("state/T99/task-step.json");
}

/// Simulates a model session that ran S01 and S02, then stopped.
fn ledgerAfterTwoSteps(f: *Fixture) !void {
    const repo = try f.path("repo");
    var ledger = try evidence.beginLedger(f.arena, io, f.git, repo, "T99", &.{"contracts"});
    try evidence.appendStep(f.arena, io, f.git, repo, &ledger, .S01, .pass, &.{});
    _ = try f.commitFile("repo", "a.txt", "alpha from S02\n", "S02 red test");
    try evidence.appendStep(f.arena, io, f.git, repo, &ledger, .S02, .pass, &.{"evidence/T99/red.json"});
    try f.tmp.dir.createDirPath(io, "state/T99");
    try evidence.saveLedger(f.arena, io, &ledger, try ledgerPath(f));
}

test "DV-005 resume after a session restart re-validates the ledger and continues" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    try ledgerAfterTwoSteps(f);

    // A new session: nothing but the ledger file and the real tree.
    var restart_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer restart_arena.deinit();
    const ledger = try evidence.loadLedger(restart_arena.allocator(), io, try ledgerPath(f));
    try testing.expectEqualStrings("T99", ledger.task_id);
    try testing.expectEqual(@as(usize, 2), ledger.steps.len);

    const resumed = try evidence.resumeTask(restart_arena.allocator(), io, f.git, try f.path("repo"), &ledger);
    try testing.expectEqual(evidence.StepId.S03, resumed.next_step.?);
    try testing.expectEqualStrings(try f.head("repo"), resumed.head_commit);
}

test "DV-005 resume rejects commits made after the last recorded step" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    try ledgerAfterTwoSteps(f);
    _ = try f.commitFile("repo", "b.txt", "unrecorded change\n", "not in ledger");

    const ledger = try evidence.loadLedger(f.arena, io, try ledgerPath(f));
    try testing.expectError(error.HeadMismatch, evidence.resumeTask(f.arena, io, f.git, try f.path("repo"), &ledger));
}

test "DV-005 resume and step recording reject a changed contract digest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    try ledgerAfterTwoSteps(f);

    // Ledger digest edited by hand while the tree is unchanged.
    const saved = try f.read("state/T99/task-step.json");
    var ledger = try evidence.loadLedger(f.arena, io, try ledgerPath(f));
    const tampered = try std.mem.replaceOwned(u8, f.arena, saved, ledger.contract_digest, "f" ** 64);
    try f.write("state/T99/task-step.json", tampered);
    const bad = try evidence.loadLedger(f.arena, io, try ledgerPath(f));
    try testing.expectError(error.ContractDigestMismatch, evidence.resumeTask(f.arena, io, f.git, try f.path("repo"), &bad));

    // A contract change committed inside the task cannot be recorded as a step.
    _ = try f.commitFile("repo", "contracts/api.json", "{\"v\":2}\n", "contract edit");
    try testing.expectError(error.ContractDigestMismatch, evidence.appendStep(f.arena, io, f.git, try f.path("repo"), &ledger, .S03, .pass, &.{}));
}

test "DV-005 resume rejects dirty trees, foreign worktrees, unrelated bases and skipped steps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    try ledgerAfterTwoSteps(f);
    const repo = try f.path("repo");
    var ledger = try evidence.loadLedger(f.arena, io, try ledgerPath(f));

    // Step order: S04 cannot follow S02.
    try testing.expectError(error.StepOrderInvalid, evidence.appendStep(f.arena, io, f.git, repo, &ledger, .S04, .pass, &.{}));

    // Same commit checked out in another worktree.
    _ = try f.run("repo", &.{ "worktree", "add", "-q", "--detach", try f.path("other"), "HEAD" });
    try testing.expectError(error.WorktreeMismatch, evidence.resumeTask(f.arena, io, f.git, try f.path("other"), &ledger));

    // Base commit that is not an ancestor of HEAD.
    _ = try f.run("other", &.{ "checkout", "-q", "--orphan", "unrelated" });
    _ = try f.run("other", &.{ "commit", "-q", "-m", "unrelated root" });
    var foreign_base = ledger;
    foreign_base.base_commit = try f.head("other");
    try testing.expectError(error.BaseNotAncestor, evidence.resumeTask(f.arena, io, f.git, repo, &foreign_base));

    // Uncommitted user edits.
    try f.write("repo/c.txt", "dirty\n");
    try testing.expectError(error.DirtyWorktree, evidence.resumeTask(f.arena, io, f.git, repo, &ledger));
}

// ---------------------------------------------------------------- core contract

test "T01 contract: core declarations match contracts/ and config/" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try evidence.verifyContracts(arena, io, build_options.repo_root);
    for (report.checks) |check| {
        if (check.status != .pass) std.debug.print("contract check failed: {s}: {s}\n", .{ check.name, check.detail });
    }
    try testing.expect(report.checks.len >= 20);
    try testing.expectEqual(@as(usize, 0), report.failed);
}

test "T01 contract: contract digest matches the recorded T00 method" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();

    // Coverage-only: creation/staging order differs from the independently specified byte order.
    try f.write("repo/contracts/z-last.json", "last\n");
    try f.write("repo/contracts/nested/mid name.json", "middle with space\n");
    try f.write("repo/contracts/a-first.json", "first\n");
    _ = try f.run("repo", &.{ "add", "contracts/z-last.json", "contracts/nested/mid name.json", "contracts/a-first.json" });
    _ = try f.run("repo", &.{ "commit", "-q", "-m", "multi-file contracts" });
    try f.write("repo/contracts/0-untracked.json", "excluded from digest\n");

    // Independent oracle: literal sorted tracked paths and literal expected contents.
    // Do not reuse the implementation's Git listing, sorting or framing helpers.
    const tracked = [_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = "contracts/a-first.json", .bytes = "first\n" },
        .{ .path = "contracts/api.json", .bytes = "{\"v\":1}\n" },
        .{ .path = "contracts/nested/mid name.json", .bytes = "middle with space\n" },
        .{ .path = "contracts/z-last.json", .bytes = "last\n" },
    };
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var outer = Sha256.init(.{});
    for (tracked) |file| {
        var file_digest: [32]u8 = undefined;
        Sha256.hash(file.bytes, &file_digest, .{});
        outer.update(&std.fmt.bytesToHex(file_digest, .lower));
        outer.update("  ");
        outer.update(file.path);
        outer.update("\n");
    }
    const expected = std.fmt.bytesToHex(outer.finalResult(), .lower);
    const digest = try evidence.contractDigest(f.arena, io, f.git, try f.path("repo"), &.{"contracts"});
    try testing.expectEqualStrings(&expected, digest);
    try f.write("repo/contracts/0-untracked.json", "changed untracked bytes still excluded\n");
    try testing.expectEqualStrings(&expected, try evidence.contractDigest(f.arena, io, f.git, try f.path("repo"), &.{"contracts"}));
}

test "T01 core: ByteSpan, LineRange and RelativePath reject invalid input" {
    try testing.expectError(error.InvalidArgument, core.ByteSpan.init(5, 3));
    try testing.expectEqual(@as(u64, 0), (try core.ByteSpan.init(3, 3)).len());
    try testing.expectEqual(@as(u64, 7), (try core.ByteSpan.init(3, 10)).len());

    try testing.expectError(error.InvalidArgument, core.LineRange.init(0, 1));
    try testing.expectError(error.InvalidArgument, core.LineRange.init(1, 0));
    try testing.expectError(error.InvalidArgument, core.LineRange.init(1, core.limits.values.max_read_lines + 1));
    try testing.expectError(error.InvalidArgument, core.LineRange.init(std.math.maxInt(u32), 2));
    try testing.expectEqual(@as(u32, 200), (try core.LineRange.init(1, 200)).count);

    try testing.expectError(error.InvalidArgument, core.RelativePath.init(""));
    try testing.expectError(error.InvalidArgument, core.RelativePath.init("/etc/passwd"));
    try testing.expectError(error.InvalidArgument, core.RelativePath.init("a/../../b"));
    try testing.expectError(error.InvalidArgument, core.RelativePath.init("a\x00b"));
    try testing.expectError(error.InvalidArgument, core.RelativePath.init("\xff\xfe"));
    try testing.expectError(error.InvalidArgument, core.RelativePath.init("a" ** (core.limits.values.path_max_utf8_bytes + 1)));
    try testing.expectEqualStrings("src/main.zig", (try core.RelativePath.init("src/main.zig")).bytes);
}

test "T01 core: every internal error has exactly one wire code" {
    try testing.expectEqual(core.errors.WireCode.E_RESOURCE, core.errors.wireCode(error.OutOfMemory));
    try testing.expectEqual(core.errors.WireCode.E_VERSION_CONFLICT, core.errors.wireCode(error.VersionConflict));
    try testing.expectEqual(core.errors.WireCode.E_PATH_ESCAPE, core.errors.wireCode(error.PathEscape));
    try testing.expectEqual(core.errors.WireCode.E_RECOVERY_REQUIRED, core.errors.wireCode(error.RecoveryRequired));
    try testing.expectEqual(core.errors.WireCode.E_INTERNAL, core.errors.wireCode(error.InvariantViolation));

    // Exhaustive: each member of the error set maps without falling into a default.
    const members = comptime @typeInfo(core.errors.Error).error_set.?;
    try testing.expect(members.len >= 20);
    inline for (members) |member| {
        _ = core.errors.wireCode(@field(core.errors.Error, member.name));
    }
    try testing.expect(core.errors.defaultRetryable(.E_BUSY));
    try testing.expect(!core.errors.defaultRetryable(.E_VERSION_CONFLICT));
    try testing.expect(!core.errors.defaultRetryable(.E_RECOVERY_REQUIRED));
}

test "T01 core: interface table declares I01 to I19 with receiver-generic signatures" {
    const Receiver = struct {};
    try testing.expectEqual(@as(usize, 19), core.interfaces.len);
    inline for (core.interfaces, 1..) |entry, n| {
        var buf: [3]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "I{d:0>2}", .{n});
        try testing.expectEqualStrings(id, entry.id);
        const Signature = entry.Signature(Receiver);
        if (n == 19) {
            // I19 is the JournalStore vtable: prepare, record, lookup.
            try testing.expectEqual(@as(usize, 3), @typeInfo(Signature).@"struct".fields.len);
        } else {
            const info = @typeInfo(Signature).@"fn";
            try testing.expect(info.params[0].type.? == *Receiver);
        }
    }
}

test "T01 core: a reservation is moved, not copied" {
    var original: core.Reservation = .{ .budget_id = 1, .bytes = 4096, .fd = 1, .cpu = 1, .output = 1024 };
    const moved = original.take();
    try testing.expect(!moved.released);
    try testing.expectEqual(@as(u64, 4096), moved.bytes);
    try testing.expect(original.released);
    try testing.expectEqual(@as(u64, 0), original.bytes);

    const cost: core.ResourceCost = .{ .input_bytes = std.math.maxInt(u64), .output_bytes = 1 };
    try testing.expectError(error.InvalidArgument, cost.totalBytes());
}

test "T01 limits: scheduler hardware ceiling follows the recorded formula" {
    try testing.expectEqual(@as(u32, 1), core.limits.hardwareCeiling(0));
    try testing.expectEqual(@as(u32, 1), core.limits.hardwareCeiling(1));
    try testing.expectEqual(@as(u32, 3), core.limits.hardwareCeiling(4));
    try testing.expectEqual(@as(u32, 6), core.limits.hardwareCeiling(7));
    try testing.expectEqual(@as(u32, 6), core.limits.hardwareCeiling(8));
    try testing.expectEqual(@as(u32, 14), core.limits.hardwareCeiling(16));
}

test "DV-001 fixture hostile Git environment cannot redirect mutations into a sentinel" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No hostile value ever points outside repositories owned by this test.
    // Bootstrap the sentinel with a minimal explicit system-Git environment.
    var clean = std.process.Environ.Map.init(arena);
    try clean.put("PATH", "/usr/bin:/bin");
    try clean.put("ZCR_FIXTURE_HOST_VALUE", "preserved");
    const sentinel = try Fixture.initFromEnvironment(arena, &clean);
    defer sentinel.deinit();
    try sentinel.initRepo();
    try sentinel.write("repo/sentinel-untracked.txt", "sentinel stays untracked\n");
    const sentinel_repo = try sentinel.path("repo");
    const before_head = try sentinel.run("repo", &.{ "rev-parse", "HEAD" });
    const before_index = try sentinel.tmp.dir.readFileAlloc(io, "repo/.git/index", arena, .limited(1 << 20));
    const before_config = try sentinel.tmp.dir.readFileAlloc(io, "repo/.git/config", arena, .limited(1 << 20));
    const before_status = try sentinel.run("repo", &.{ "status", "--porcelain=v2", "-z" });
    try sentinel.tmp.dir.createDirPath(io, "empty-hostile-template");

    var hostile = try clean.clone(arena);
    // An unusable inherited PATH must be preserved without selecting the fixture executable.
    try hostile.put("PATH", try sentinel.path("untrusted-bin"));
    try hostile.put("GIT_DIR", try sentinel.path("repo/.git"));
    try hostile.put("GIT_WORK_TREE", sentinel_repo);
    try hostile.put("GIT_INDEX_FILE", try sentinel.path("repo/.git/index"));
    try hostile.put("GIT_CONFIG", try sentinel.path("repo/.git/config"));
    try hostile.put("GIT_CONFIG_GLOBAL", try sentinel.path("repo/.git/config"));
    try hostile.put("GIT_CONFIG_SYSTEM", try sentinel.path("repo/.git/config"));
    try hostile.put("GIT_CONFIG_COUNT", "2");
    try hostile.put("GIT_CONFIG_KEY_0", "core.worktree");
    try hostile.put("GIT_CONFIG_VALUE_0", sentinel_repo);
    try hostile.put("GIT_CONFIG_KEY_1", "user.name");
    try hostile.put("GIT_CONFIG_VALUE_1", "hostile environment identity");
    try hostile.put("GIT_CONFIG_KEY_99", "unused.stale.key");
    try hostile.put("GIT_TEMPLATE_DIR", try sentinel.path("empty-hostile-template"));
    try hostile.put("GIT_FUTURE_UNRECOGNIZED_OVERRIDE", "must be removed too");
    const target = try Fixture.initFromEnvironment(arena, &hostile);
    defer target.deinit();
    try target.write("repo/fixture-only.txt", "belongs only to target\n");
    _ = try target.run("repo", &.{ "init", "-q", "-b", "fixture-target" });
    _ = try target.run("repo", &.{ "config", "fixture.probe", "target-only" });
    _ = try target.run("repo", &.{ "add", "." });
    _ = try target.run("repo", &.{ "commit", "-q", "-m", "target fixture mutation" });

    try testing.expectEqualStrings(before_head, try sentinel.run("repo", &.{ "rev-parse", "HEAD" }));
    try testing.expectEqualSlices(u8, before_index, try sentinel.tmp.dir.readFileAlloc(io, "repo/.git/index", arena, .limited(1 << 20)));
    try testing.expectEqualSlices(u8, before_config, try sentinel.tmp.dir.readFileAlloc(io, "repo/.git/config", arena, .limited(1 << 20)));
    try testing.expectEqualStrings(before_status, try sentinel.run("repo", &.{ "status", "--porcelain=v2", "-z" }));
    try testing.expectEqualStrings("sentinel stays untracked\n", try sentinel.tmp.dir.readFileAlloc(io, "repo/sentinel-untracked.txt", arena, .limited(1024)));
    try testing.expectEqualStrings("target-only\n", try target.run("repo", &.{ "config", "--get", "fixture.probe" }));
    try testing.expectEqualStrings("preserved", target.env.get("ZCR_FIXTURE_HOST_VALUE").?);
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG", "GIT_CONFIG_KEY_99", "GIT_FUTURE_UNRECOGNIZED_OVERRIDE" }) |key| try testing.expect(target.env.get(key) == null);
    try testing.expectEqualStrings(try trustedGit(), target.git.exe);
    try testing.expectEqualStrings(hostile.get("PATH").?, target.env.get("PATH").?);
    try testing.expectEqualStrings("/dev/null\n", try target.run("repo", &.{ "config", "--get", "core.hooksPath" }));
    try testing.expectEqualStrings("false\n", try target.run("repo", &.{ "config", "--get", "commit.gpgSign" }));
    try testing.expectEqualStrings("0", target.env.get("GIT_TERMINAL_PROMPT").?);
}
