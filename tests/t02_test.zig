//! T02 tests: I01 authorization (IS-003, IS-004) and the development scope and
//! ownership guard (DV-002, DV-003).
//!
//! Run: `zig build test -Dtest-group=isolation`.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const guard = @import("dev_guard");
const evidence = @import("evidence");
const build_options = @import("build_options");

const testing = std.testing;
const io = testing.io;
const Allocator = std.mem.Allocator;
const Io = std.Io;

// ------------------------------------------------------------------ fixture

const Fixture = struct {
    arena: Allocator,
    tmp: testing.TmpDir,
    root: []const u8,
    env: std.process.Environ.Map,
    git: evidence.Git,

    fn init(arena: Allocator) !*Fixture {
        const f = try arena.create(Fixture);
        f.arena = arena;
        f.tmp = testing.tmpDir(.{});
        f.root = try f.tmp.dir.realPathFileAlloc(io, ".", arena);
        f.env = try testing.environ.createMap(arena);
        try f.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try f.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try f.env.put("GIT_AUTHOR_NAME", "t02");
        try f.env.put("GIT_AUTHOR_EMAIL", "t02@example.invalid");
        try f.env.put("GIT_COMMITTER_NAME", "t02");
        try f.env.put("GIT_COMMITTER_EMAIL", "t02@example.invalid");
        f.git = try evidence.findGit(arena, io, &f.env);
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

    fn line(f: *Fixture, cwd_sub: []const u8, args: []const []const u8) ![]const u8 {
        return std.mem.trim(u8, try f.run(cwd_sub, args), "\n");
    }

    /// repo/ with source, contract and build files committed on main.
    fn initRepo(f: *Fixture) !void {
        try f.write("repo/src/policy/a.zig", "// a\n");
        try f.write("repo/src/core/types.zig", "// core\n");
        try f.write("repo/docs/readme.md", "docs\n");
        try f.write("repo/README.md", "readme\n");
        try f.write("repo/build.zig", "// build\n");
        try f.write("repo/contracts/api.json", "{\"v\":1}\n");
        _ = try f.run("repo", &.{ "init", "-q", "-b", "main" });
        _ = try f.run("repo", &.{ "add", "." });
        _ = try f.run("repo", &.{ "commit", "-q", "-m", "base" });
    }

    fn gitMetadata(f: *Fixture, cwd_sub: []const u8) !core.GitMetadata {
        return .{
            .git_dir = try f.line(cwd_sub, &.{ "rev-parse", "--absolute-git-dir" }),
            .common_dir = try f.line(cwd_sub, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }),
        };
    }
};

// ------------------------------------------------------------------ authorizer helpers

const all_operations = [_]core.Operation{ .read, .enumerate, .search, .batch_read, .patch, .create, .status, .health };
const workspace: core.WorkspaceId = .{ .registry_uuid = @splat(0x11), .incarnation = @splat(0x22) };
const task: core.TaskId = .{ .uuid = @splat(0x33) };
const digest: core.PolicyDigest = @splat(0x44);

fn rel(bytes: []const u8) core.RelativePath {
    // Struct literal on purpose: authorize must not rely on RelativePath.init having run.
    return .{ .bytes = bytes };
}

fn paths(comptime items: []const []const u8) []const core.RelativePath {
    const out = comptime blk: {
        var array: [items.len]core.RelativePath = undefined;
        for (items, 0..) |item, i| array[i] = .{ .bytes = item };
        break :blk array;
    };
    return &out;
}

const PolicyOptions = struct {
    state: core.ManifestState = .active,
    read_paths: []const core.RelativePath = paths(&.{"."}),
    write_paths: []const core.RelativePath = paths(&.{ "src", "tests/t02_test.zig" }),
    immutable_paths: []const core.RelativePath = paths(&.{ "src/core", "build.zig", "contracts" }),
    operations: []const core.Operation = &all_operations,
};

fn makeAuthorizer(f: *Fixture, root_sub: []const u8, options: PolicyOptions) !policy.Authorizer {
    const root_path = try f.path(root_sub);
    const dir = try Io.Dir.openDirAbsolute(io, root_path, .{});
    return policy.Authorizer.init(f.arena, io, .{ .dir = dir, .canonical_path = root_path }, workspace, task, .{
        .digest = digest,
        .state = options.state,
        .read_paths = options.read_paths,
        .write_paths = options.write_paths,
        .immutable_paths = options.immutable_paths,
        .operations = options.operations,
        .max_changed_files = 16,
    }, try f.gitMetadata(root_sub));
}

fn session() core.SessionContext {
    return .{
        .session_id = .{ .uuid = @splat(0x55) },
        .security_domain = .{ .id = 1 },
        .policy_digest = digest,
        .bound_workspace = workspace,
        .bound_task = task,
        .capability_handle = .none,
    };
}

fn isCaseInsensitive(f: *Fixture, existing_sub: []const u8, alias_sub: []const u8) bool {
    _ = f.tmp.dir.statFile(io, existing_sub, .{}) catch return false;
    _ = f.tmp.dir.statFile(io, alias_sub, .{}) catch return false;
    return true;
}

// ------------------------------------------------------------------ IS-003

test "IS-003 traversal, absolute, UNC, drive-letter and backslash paths are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    var authorizer = try makeAuthorizer(f, "repo", .{});

    const escapes = [_][]const u8{
        "../outside.txt",
        "src/../../outside.txt",
        "src/..",
        "/etc/passwd",
        "//server/share/file",
        "\\\\server\\share\\file",
        "C:\\Windows\\win.ini",
        "C:/Windows/win.ini",
        "src\\policy\\a.zig",
    };
    for (escapes) |bytes| {
        testing.expectError(error.PathEscape, authorizer.authorize(io, session(), .read, rel(bytes))) catch |err| {
            std.debug.print("path not refused as escape: {s}\n", .{bytes});
            return err;
        };
    }

    const invalid = [_][]const u8{ "", "src//policy/a.zig", "./src/policy/a.zig", "src/policy/", "src/./policy/a.zig", "a\x00b", "\xff\xfe" };
    for (invalid) |bytes| {
        testing.expectError(error.InvalidArgument, authorizer.authorize(io, session(), .read, rel(bytes))) catch |err| {
            std.debug.print("path not refused as invalid: {any}\n", .{bytes});
            return err;
        };
    }
}

test "IS-003 symlinks are refused as final or intermediate components, even when they point inside the root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    try f.write("outside/secret.txt", "secret\n");
    try f.tmp.dir.symLink(io, try f.path("outside"), "repo/src/escape-dir", .{ .is_directory = true });
    try f.tmp.dir.symLink(io, try f.path("outside/secret.txt"), "repo/src/escape-file", .{});
    try f.tmp.dir.symLink(io, "policy", "repo/src/inside-link", .{ .is_directory = true });
    var authorizer = try makeAuthorizer(f, "repo", .{});

    try testing.expectError(error.PathEscape, authorizer.authorize(io, session(), .read, rel("src/escape-dir/secret.txt")));
    try testing.expectError(error.PathEscape, authorizer.authorize(io, session(), .read, rel("src/escape-file")));
    try testing.expectError(error.PathEscape, authorizer.authorize(io, session(), .patch, rel("src/escape-file")));
    try testing.expectError(error.PathEscape, authorizer.authorize(io, session(), .read, rel("src/inside-link/a.zig")));
    try testing.expectError(error.PathEscape, authorizer.authorize(io, session(), .create, rel("src/escape-dir/new.txt")));
}

test "IS-003 model arguments cannot switch workspace, task, policy or operation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    var authorizer = try makeAuthorizer(f, "repo", .{});
    const target = rel("src/policy/a.zig");

    var other_workspace = session();
    other_workspace.bound_workspace.incarnation = @splat(0x99);
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, other_workspace, .read, target));

    var other_task = session();
    other_task.bound_task = .{ .uuid = @splat(0x98) };
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, other_task, .read, target));

    var other_policy = session();
    other_policy.policy_digest = @splat(0x97);
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, other_policy, .read, target));

    var planned = try makeAuthorizer(f, "repo", .{ .state = .planned });
    try testing.expectError(error.ManifestUnbound, planned.authorize(io, session(), .read, target));
    var revoked = try makeAuthorizer(f, "repo", .{ .state = .revoked });
    try testing.expectError(error.OutOfScope, revoked.authorize(io, session(), .read, target));

    var read_only = try makeAuthorizer(f, "repo", .{ .operations = &.{ .read, .status } });
    try testing.expectError(error.OutOfScope, read_only.authorize(io, session(), .patch, target));
    _ = try read_only.authorize(io, session(), .read, target);
}

test "IS-003 allowed operations inside scope yield distinct immutable capabilities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    var authorizer = try makeAuthorizer(f, "repo", .{});

    const first = try authorizer.authorize(io, session(), .read, rel("src/policy/a.zig"));
    const second = try authorizer.authorize(io, session(), .patch, rel("src/policy/a.zig"));
    try testing.expectEqual(core.Operation.read, first.operation);
    try testing.expectEqualStrings("src/policy/a.zig", first.path.bytes);
    try testing.expect(first.workspace_id.eql(workspace));
    try testing.expect(std.mem.eql(u8, &first.policy_digest, &digest));
    try testing.expect(first.handle != second.handle);
    try testing.expect(first.handle != .none);

    _ = try authorizer.authorize(io, session(), .create, rel("src/policy/new.zig"));
    _ = try authorizer.authorize(io, session(), .enumerate, rel("src"));
    _ = try authorizer.authorize(io, session(), .status, rel("."));

    // Scope matching is by path component, not string prefix.
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .patch, rel("docs/readme.md")));
    try f.write("repo/src2/x.zig", "x\n");
    try f.write("repo/srcx.zig", "x\n");
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .patch, rel("src2/x.zig")));
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .patch, rel("srcx.zig")));

    // Filesystem type checks.
    try testing.expectError(error.NotFound, authorizer.authorize(io, session(), .read, rel("src/policy/missing.zig")));
    try testing.expectError(error.NotRegular, authorizer.authorize(io, session(), .read, rel("src/policy")));
    try testing.expectError(error.NotFound, authorizer.authorize(io, session(), .create, rel("src/no-such-dir/new.zig")));
    try testing.expectError(error.NotFound, authorizer.authorize(io, session(), .read, rel("src/policy/a.zig/child")));
}

// ------------------------------------------------------------------ IS-004

test "IS-004 the linked worktree .git file is neither writable nor readable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    _ = try f.run("repo", &.{ "worktree", "add", "-q", "-b", "task", try f.path("wt") });
    // Whole root writable so only Git metadata protection can refuse.
    var authorizer = try makeAuthorizer(f, "wt", .{ .write_paths = paths(&.{"."}), .immutable_paths = &.{} });

    try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .patch, rel(".git")));
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .read, rel(".git")));
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .create, rel(".git/hooks/pre-commit")));
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .patch, rel(".GIT")));
    try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .create, rel("src/.Git/config")));
    _ = try authorizer.authorize(io, session(), .patch, rel("src/policy/a.zig"));
}

test "IS-004 the main .git directory is refused by name and a common git dir under the root by identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    var main_root = try makeAuthorizer(f, "repo", .{ .write_paths = paths(&.{"."}), .immutable_paths = &.{} });
    try testing.expectError(error.OutOfScope, main_root.authorize(io, session(), .patch, rel(".git/config")));
    try testing.expectError(error.OutOfScope, main_root.authorize(io, session(), .create, rel(".git/objects/zz")));
    try testing.expectError(error.OutOfScope, main_root.authorize(io, session(), .patch, rel(".Git/HEAD")));

    // A repository whose git dir lives under the root with an ordinary name.
    try f.write("separate/src/main.zig", "// main\n");
    _ = try f.run("separate", &.{ "init", "-q", "-b", "main", "--separate-git-dir", try f.path("separate/store") });
    const meta = try f.gitMetadata("separate");
    try testing.expect(std.mem.endsWith(u8, meta.common_dir.?, "store"));
    var separate = try makeAuthorizer(f, "separate", .{ .write_paths = paths(&.{"."}), .immutable_paths = &.{} });
    try testing.expectError(error.OutOfScope, separate.authorize(io, session(), .patch, rel("store/config")));
    try testing.expectError(error.OutOfScope, separate.authorize(io, session(), .create, rel("store/hooks/post-checkout")));
    try testing.expectError(error.OutOfScope, separate.authorize(io, session(), .read, rel("store/HEAD")));
    _ = try separate.authorize(io, session(), .patch, rel("src/main.zig"));
}

test "IS-004 immutable paths are compared by filesystem identity, not spelling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    var authorizer = try makeAuthorizer(f, "repo", .{
        .write_paths = paths(&.{ "src", "BUILD.ZIG" }),
        .immutable_paths = paths(&.{ "src/core", "build.zig" }),
    });

    try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .patch, rel("src/core/types.zig")));
    if (isCaseInsensitive(f, "repo/src/core", "repo/src/CORE")) {
        // Same directory through a case alias: refused by identity.
        try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .patch, rel("src/CORE/types.zig")));
        try testing.expectError(error.OutOfScope, authorizer.authorize(io, session(), .patch, rel("BUILD.ZIG")));
    } else {
        // Case-sensitive volume: the alias is a different, missing path.
        try testing.expectError(error.NotFound, authorizer.authorize(io, session(), .patch, rel("src/CORE/types.zig")));
        try testing.expectError(error.NotFound, authorizer.authorize(io, session(), .patch, rel("BUILD.ZIG")));
    }
}

// ------------------------------------------------------------------ DV-002

fn hasViolation(report: guard.Report, path: []const u8, reason: guard.Reason) bool {
    for (report.violations) |v| {
        if (v.reason == reason and std.mem.eql(u8, v.path, path)) return true;
    }
    return false;
}

fn violatedPath(report: guard.Report, path: []const u8) bool {
    for (report.violations) |v| if (std.mem.eql(u8, v.path, path)) return true;
    return false;
}

test "DV-002 out-of-scope new, renamed, deleted, staged and committed files are all rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    const base = try f.line("repo", &.{ "rev-parse", "HEAD" });

    // Committed: one owned edit, a rename out of an unowned path, an unowned addition.
    try f.write("repo/src/policy/a.zig", "// a edited\n");
    _ = try f.run("repo", &.{ "mv", "README.md", "src/policy/README.md" });
    try f.write("repo/docs/extra.md", "extra\n");
    _ = try f.run("repo", &.{ "add", "." });
    _ = try f.run("repo", &.{ "commit", "-q", "-m", "task commit" });

    // Working tree: unstaged delete, untracked file, staged file, owned untracked file, symlink.
    try f.tmp.dir.deleteFile(io, "repo/docs/readme.md");
    try f.write("repo/notes.txt", "notes\n");
    try f.write("repo/tools/x.zig", "x\n");
    _ = try f.run("repo", &.{ "add", "tools/x.zig" });
    try f.write("repo/src/policy/new.zig", "new\n");
    try f.tmp.dir.symLink(io, "/etc/hosts", "repo/src/policy/link", .{});

    const status_before = try f.run("repo", &.{ "status", "--porcelain=v2", "-z", "--untracked-files=all" });
    const rules: guard.Rules = .{ .task_id = "T99", .owned_paths = &.{ "src/policy", "tests/t99_test.zig" } };
    const report = try guard.scopeGuard(f.arena, io, f.git, try f.path("repo"), base, rules, .task);

    try testing.expect(!report.ok());
    try testing.expect(hasViolation(report, "README.md", .outside_owned_paths)); // rename source
    try testing.expect(hasViolation(report, "docs/extra.md", .outside_owned_paths)); // committed
    try testing.expect(hasViolation(report, "docs/readme.md", .outside_owned_paths)); // deleted
    try testing.expect(hasViolation(report, "notes.txt", .outside_owned_paths)); // untracked
    try testing.expect(hasViolation(report, "tools/x.zig", .outside_owned_paths)); // staged
    try testing.expect(hasViolation(report, "src/policy/link", .symlink));
    try testing.expect(!violatedPath(report, "src/policy/a.zig"));
    try testing.expect(!violatedPath(report, "src/policy/new.zig"));
    try testing.expect(!violatedPath(report, "src/policy/README.md"));

    // The guard only reads.
    try testing.expectEqualStrings(status_before, try f.run("repo", &.{ "status", "--porcelain=v2", "-z", "--untracked-files=all" }));
    try testing.expectEqualStrings("", try f.run("repo", &.{ "stash", "list" }));
}

test "DV-002 changes inside owned paths pass and ownership matches whole path components" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    const base = try f.line("repo", &.{ "rev-parse", "HEAD" });
    const rules: guard.Rules = .{ .task_id = "T99", .owned_paths = &.{"src/policy"} };

    try f.write("repo/src/policy/x.zig", "x\n");
    const clean = try guard.scopeGuard(f.arena, io, f.git, try f.path("repo"), base, rules, .task);
    try testing.expect(clean.ok());
    try testing.expectEqual(@as(usize, 1), clean.changes.len);

    try f.write("repo/src/policy2/y.zig", "y\n");
    try f.write("repo/src/policyx", "z\n");
    const report = try guard.scopeGuard(f.arena, io, f.git, try f.path("repo"), base, rules, .task);
    try testing.expect(hasViolation(report, "src/policy2/y.zig", .outside_owned_paths));
    try testing.expect(hasViolation(report, "src/policyx", .outside_owned_paths));
    try testing.expect(!violatedPath(report, "src/policy/x.zig"));
}

// ------------------------------------------------------------------ DV-003

test "DV-003 two tasks editing the same shared contract are rejected unless the integrator makes the change" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try Fixture.init(arena_state.allocator());
    defer f.deinit();
    try f.initRepo();
    const base = try f.line("repo", &.{ "rev-parse", "HEAD" });
    _ = try f.run("repo", &.{ "worktree", "add", "-q", "-b", "task-t98", try f.path("t98") });
    _ = try f.run("repo", &.{ "worktree", "add", "-q", "-b", "task-t99", try f.path("t99") });

    try f.write("t98/contracts/api.json", "{\"v\":98}\n");
    try f.write("t98/src/a.zig", "a\n");
    _ = try f.run("t98", &.{ "add", "." });
    _ = try f.run("t98", &.{ "commit", "-q", "-m", "t98" });

    try f.write("t99/contracts/api.json", "{\"v\":99}\n");
    try f.write("t99/build.zig", "// t99 build\n");
    try f.write("t99/src/b.zig", "b\n");
    _ = try f.run("t99", &.{ "add", "." });
    _ = try f.run("t99", &.{ "commit", "-q", "-m", "t99" });

    const t98 = try guard.scopeGuard(f.arena, io, f.git, try f.path("t98"), base, .{ .task_id = "T98", .owned_paths = &.{"src/a.zig"} }, .task);
    try testing.expect(hasViolation(t98, "contracts/api.json", .integrator_owned));
    try testing.expect(!violatedPath(t98, "src/a.zig"));

    // Owning an integrator path in a task manifest does not grant it.
    const t99 = try guard.scopeGuard(f.arena, io, f.git, try f.path("t99"), base, .{ .task_id = "T99", .owned_paths = &.{ "src/b.zig", "contracts/api.json" } }, .task);
    try testing.expect(hasViolation(t99, "contracts/api.json", .integrator_owned));
    try testing.expect(hasViolation(t99, "build.zig", .integrator_owned));

    const integrator = try guard.scopeGuard(f.arena, io, f.git, try f.path("t99"), base, .{ .task_id = "T01", .owned_paths = &.{} }, .integrator);
    try testing.expect(integrator.ok());
}

test "DV-003 overlapping task ownership is detected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tasks = [_]guard.TaskOwnership{
        .{ .task_id = "T97", .owns = &.{"contracts/extra.schema.json"} },
        .{ .task_id = "T98", .owns = &.{"src/shared/x.zig"} },
        .{ .task_id = "T99", .owns = &.{"src/shared"} },
        .{ .task_id = "T96", .owns = &.{"src/sharedx.zig"} },
    };
    const overlaps = try guard.findOwnershipOverlaps(arena, &tasks);
    try testing.expectEqual(@as(usize, 2), overlaps.len);
    var saw_shared = false;
    var saw_integrator = false;
    for (overlaps) |o| {
        if (std.mem.eql(u8, o.first_task, "T98") and std.mem.eql(u8, o.second_task, "T99")) saw_shared = true;
        if (std.mem.eql(u8, o.first_task, "T97") and std.mem.eql(u8, o.second_task, "integrator")) saw_integrator = true;
    }
    try testing.expect(saw_shared);
    try testing.expect(saw_integrator);
}

test "DV-003 the repository task table assigns every path to one owner" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tasks_path = try std.fs.path.join(arena, &.{ build_options.repo_root, "tasks/tasks.json" });
    const tasks = try guard.loadTasks(arena, io, tasks_path);
    try testing.expectEqual(@as(usize, 26), tasks.len);
    const overlaps = try guard.findOwnershipOverlaps(arena, tasks);
    for (overlaps) |o| std.debug.print("overlap {s}: {s} / {s}\n", .{ o.path, o.first_task, o.second_task });
    try testing.expectEqual(@as(usize, 0), overlaps.len);

    const rules = try guard.rulesFor(arena, tasks, "T02");
    for ([_][]const u8{ "src/policy/capability.zig", "tools/dev/guard.zig", "tests/t02_test.zig", "evidence/T02" }) |owned| {
        for (rules.owned_paths) |p| {
            if (std.mem.eql(u8, p, owned)) break;
        } else {
            std.debug.print("T02 rules missing {s}\n", .{owned});
            return error.TestExpectedOwnership;
        }
    }
    try testing.expectEqual(guard.Role.integrator, guard.roleFor("T01"));
    try testing.expectEqual(guard.Role.task, guard.roleFor("T02"));
    try testing.expectError(error.UnknownTask, guard.rulesFor(arena, tasks, "T77"));
}
