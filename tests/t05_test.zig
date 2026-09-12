//! T05 tests: Git-aware streaming traversal and ignore rules (FS-001..FS-006).
//!
//! Git itself is the oracle for ignore semantics: `git ls-files --others
//! --exclude-standard` for file sets and `git check-ignore --no-index` for
//! single patterns, with global and system Git configuration disabled.
//!
//! Run: `zig build test -Dtest-group=fs`.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const traverse = @import("zcr_fs_traverse");
const evidence = @import("evidence");

const testing = std.testing;
const io = testing.io;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const KiB = core.limits.KiB;
const MiB = core.limits.MiB;

const workspace: core.WorkspaceId = .{ .registry_uuid = @splat(0x11), .incarnation = @splat(0x22) };
const task: core.TaskId = .{ .uuid = @splat(0x33) };
const digest: core.PolicyDigest = @splat(0x44);

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

/// Collects pushed paths; optionally refuses after `accept` items.
const Collector = struct {
    arena: Allocator,
    paths: std.ArrayList([]const u8) = .empty,
    accept: ?usize = null,
    refuse_with: core.SinkError = error.Busy,

    fn push(context: *anyopaque, item: core.RelativePath) core.SinkError!void {
        const self: *Collector = @ptrCast(@alignCast(context));
        if (self.accept) |limit| if (self.paths.items.len >= limit) return self.refuse_with;
        const copy = self.arena.dupe(u8, item.bytes) catch return error.OutputBudgetExceeded;
        self.paths.append(self.arena, copy) catch return error.OutputBudgetExceeded;
    }

    fn sink(self: *Collector) core.Sink(core.RelativePath) {
        return .{ .context = self, .push_fn = push };
    }

    fn sorted(self: *Collector) []const []const u8 {
        std.mem.sort([]const u8, self.paths.items, {}, lessThan);
        return self.paths.items;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Harness = struct {
    arena: Allocator,
    tmp: testing.TmpDir,
    root_path: []const u8,
    root: core.TrustedRoot,
    authorizer: policy.Authorizer,
    counters: memory.accounting.Counters = .{},
    budget: memory.Budget = undefined,
    reservation: core.Reservation = undefined,
    reserved: memory.ReservedAllocator = undefined,
    traverser: traverse.Traverser = undefined,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    env: std.process.Environ.Map,
    git: evidence.Git,

    fn init(arena: Allocator, caps: traverse.Caps) !*Harness {
        const h = try arena.create(Harness);
        h.* = .{ .arena = arena, .tmp = testing.tmpDir(.{}), .root_path = undefined, .root = undefined, .authorizer = undefined, .env = undefined, .git = undefined };
        h.root_path = try h.tmp.dir.realPathFileAlloc(io, ".", arena);
        try h.setupRoot(caps);
        h.env = try testing.environ.createMap(arena);
        try h.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try h.env.put("GIT_CONFIG_NOSYSTEM", "1");
        h.git = try evidence.findGit(arena, io, &h.env);
        return h;
    }

    fn setupRoot(h: *Harness, caps: traverse.Caps) !void {
        const dir = try Io.Dir.openDirAbsolute(io, h.root_path, .{});
        h.root = .{ .dir = dir, .canonical_path = h.root_path };
        h.authorizer = try policy.Authorizer.init(h.arena, io, h.root, workspace, task, .{
            .digest = digest,
            .state = .active,
            .read_paths = &.{.{ .bytes = "." }},
            .write_paths = &.{},
            .immutable_paths = &.{},
            .operations = &.{ .enumerate, .search, .read },
            .max_changed_files = 1,
        }, .{ .git_dir = null, .common_dir = null });
        h.budget = memory.Budget.init(1, .{ .bytes = 64 * MiB, .fds = 64, .cpu = 4, .output_bytes = 16 * MiB }, &h.counters);
        h.reservation = try h.budget.reserve(session(), .{ .scratch_bytes = traverse.Caps.defaultBytes(caps) + 1 * MiB, .fds = 32 });
        h.reserved = memory.ReservedAllocator.init(testing.allocator, &h.reservation, &h.counters, null);
        h.traverser = try traverse.Traverser.init(h.reserved.allocator(), h.root, workspace, caps);
    }

    fn deinit(h: *Harness) void {
        h.traverser.deinit();
        h.budget.release(&h.reservation) catch unreachable;
        h.root.dir.close(io);
        h.tmp.cleanup();
    }

    fn write(h: *Harness, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |parent| try h.tmp.dir.createDirPath(io, parent);
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    fn cancel(h: *Harness) core.Cancel {
        return .{ .requested = &h.cancel_flag };
    }

    fn enumerate(h: *Harness, spec: core.FileSpec, collector: *Collector) !core.Coverage {
        const capability = try h.authorizer.authorize(io, session(), .enumerate, .{ .bytes = "." });
        return h.traverser.enumerate(io, capability, spec, collector.sink(), h.cancel());
    }

    fn gitInit(h: *Harness) !void {
        _ = try h.runGit(&.{ "init", "-q", "-b", "main" }, true);
    }

    /// Untracked, not ignored files according to Git, sorted by bytes.
    fn gitOracle(h: *Harness) ![]const []const u8 {
        const out = try h.runGit(&.{ "-c", "core.ignorecase=false", "-c", "core.excludesFile=", "ls-files", "--others", "--exclude-standard", "-z" }, true);
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, out, 0);
        while (it.next()) |p| try list.append(h.arena, p);
        std.mem.sort([]const u8, list.items, {}, lessThan);
        return list.items;
    }

    fn runGit(h: *Harness, args: []const []const u8, must_succeed: bool) ![]const u8 {
        const argv = try h.arena.alloc([]const u8, args.len + 1);
        argv[0] = h.git.exe;
        @memcpy(argv[1..], args);
        const result = try std.process.run(h.arena, io, .{ .argv = argv, .cwd = .{ .path = h.root_path }, .environ_map = &h.env });
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (must_succeed and !ok) {
            std.debug.print("git {s} failed: {s}\n", .{ args[args.len - 1], result.stderr });
            return error.FixtureGitFailed;
        }
        return result.stdout;
    }
};

fn expectSameSet(expected: []const []const u8, actual: []const []const u8) !void {
    var mismatch = expected.len != actual.len;
    if (!mismatch) for (expected, actual) |a, b| {
        if (!std.mem.eql(u8, a, b)) mismatch = true;
    };
    if (mismatch) {
        std.debug.print("\nexpected ({d}):\n", .{expected.len});
        for (expected) |p| std.debug.print("  {s}\n", .{p});
        std.debug.print("actual ({d}):\n", .{actual.len});
        for (actual) |p| std.debug.print("  {s}\n", .{p});
        return error.TestExpectedEqual;
    }
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |p| if (std.mem.eql(u8, p, item)) return true;
    return false;
}

const all_hidden: core.FileSpec = .{ .include_hidden = true, .limit = 10_000 };

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

const IgnoreSwap = struct {
    h: *Harness,
    fifo: bool,
    done: bool = false,

    fn swap(ctx: ?*anyopaque) void {
        const self: *IgnoreSwap = @ptrCast(@alignCast(ctx.?));
        if (self.done) return;
        self.done = true;
        if (self.fifo) {
            self.h.tmp.dir.deleteFile(io, ".gitignore") catch unreachable;
            const path = std.fmt.allocPrintSentinel(self.h.arena, "{s}/.gitignore", .{self.h.root_path}, 0) catch unreachable;
            std.debug.assert(mkfifo(path.ptr, 0o600) == 0);
        } else {
            self.h.write("replacement", "secret.txt\n") catch unreachable;
            self.h.tmp.dir.rename("replacement", self.h.tmp.dir, ".gitignore", io) catch unreachable;
        }
    }
};

test "FS-005 replacing an ignore file with a FIFO between stat and open cannot block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    try h.write(".gitignore", "secret.txt\n");
    try h.write("secret.txt", "x\n");
    var swap: IgnoreSwap = .{ .h = h, .fifo = true };
    var fault: traverse.IgnoreFault = .{ .before_open = IgnoreSwap.swap, .context = &swap };
    h.traverser.ignore_fault = &fault;
    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.enumerate(all_hidden, &collector);
    try testing.expect(swap.done);
    try testing.expectEqual(@as(usize, 0), collector.paths.items.len);
    try testing.expect(coverage.skipped > 0);
    try testing.expect(!h.traverser.report().complete);
}

test "FS-005 replacing an ignore path during its read cannot report stale rules complete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    try h.write(".gitignore", "# initial\n");
    try h.write("secret.txt", "x\n");
    var swap: IgnoreSwap = .{ .h = h, .fifo = false };
    var fault: traverse.IgnoreFault = .{ .after_read = IgnoreSwap.swap, .context = &swap };
    h.traverser.ignore_fault = &fault;
    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.enumerate(all_hidden, &collector);
    try testing.expect(swap.done);
    try testing.expectEqual(@as(usize, 0), collector.paths.items.len);
    try testing.expect(coverage.skipped > 0);
    try testing.expect(!h.traverser.report().complete);
}

test "FS-001 trusted Git info and global excludes follow Git precedence without reading repository config" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    try h.gitInit();
    try h.write(".git/info/exclude", "info.txt\n!from-global.txt\nshared.txt\n");
    try h.write(".gitignore", "!shared.txt\n");
    try h.write("sub/.gitignore", "!global.txt\n");
    for ([_][]const u8{ "info.txt", "global.txt", "from-global.txt", "shared.txt", "sub/global.txt", "visible.txt" }) |p| try h.write(p, "x\n");
    var external = testing.tmpDir(.{});
    defer external.cleanup();
    try external.dir.writeFile(io, .{ .sub_path = "global", .data = "global.txt\nfrom-global.txt\n" });
    const global_path = try external.dir.realPathFileAlloc(io, "global", h.arena);
    const config_arg = try std.fmt.allocPrint(h.arena, "core.excludesFile={s}", .{global_path});
    const oracle_bytes = try h.runGit(&.{ "-c", config_arg, "ls-files", "--others", "--exclude-standard", "-z" }, true);
    var expected: std.ArrayList([]const u8) = .empty;
    var paths = std.mem.tokenizeScalar(u8, oracle_bytes, 0);
    while (paths.next()) |p| try expected.append(h.arena, p);
    std.mem.sort([]const u8, expected.items, {}, lessThan);

    const info = try h.tmp.dir.openFile(io, ".git/info/exclude", .{});
    defer info.close(io);
    const global = try external.dir.openFile(io, "global", .{});
    defer global.close(io);
    h.traverser.trusted_excludes = .{ .git_info_exclude = info, .global_exclude = global };
    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.enumerate(all_hidden, &collector);
    try expectSameSet(expected.items, collector.sorted());
    try testing.expectEqual(@as(u64, 0), coverage.skipped);
    try testing.expect(h.traverser.report().complete);

    // A repository setting is data, and cannot make ZCR open an external file.
    _ = try h.runGit(&.{ "config", "core.excludesFile", global_path }, true);
    h.traverser.trusted_excludes = .{};
    var unbound: Collector = .{ .arena = h.arena };
    _ = try h.enumerate(all_hidden, &unbound);
    try testing.expect(contains(unbound.paths.items, "global.txt"));
    // Exclude handles are borrowed; traversal neither closes nor returns their contents.
    try testing.expect((try info.stat(io)).kind == .file);
    try testing.expect((try global.stat(io)).kind == .file);
}

test "FS-005 an unreadable ignore file cannot silently expose its excluded subtree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    try h.write("private/.gitignore", "secret.txt\n");
    try h.write("private/secret.txt", "x\n");
    try h.write("visible.txt", "x\n");
    const locked = try std.fmt.allocPrintSentinel(h.arena, "{s}/private/.gitignore", .{h.root_path}, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(locked.ptr, 0));
    defer _ = std.c.chmod(locked.ptr, 0o600);
    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.enumerate(all_hidden, &collector);
    try expectSameSet(&.{"visible.txt"}, collector.sorted());
    try testing.expect(!h.traverser.report().complete);
    try testing.expect(coverage.skipped > 0);
}

// ------------------------------------------------------------------ FS-001 .. FS-003

test "FS-001 nested .gitignore files and negations give Git's file set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();

    try h.write(".gitignore", "*.log\n!important.log\nbuild/\n/top-only.txt\ndocs/**/draft.md\n*.o\n");
    try h.write("src/.gitignore", "!debug.log\n*.tmp\n/local.txt\n");
    try h.write("deep/nested/.gitignore", "!*.log\n");
    for ([_][]const u8{
        "a.log",             "important.log",     "top-only.txt",      "src/top-only.txt", "src/debug.log",
        "src/x.log",         "src/y.tmp",         "src/z.zig",         "src/local.txt",    "src/sub/local.txt",
        "build/out.bin",     "src/build/out.bin", "docs/a/b/draft.md", "docs/draft.md",    "docs/keep.md",
        "deep/nested/c.log", "deep/other.log",    "obj/main.o",        "keep.txt",
    }) |path| try h.write(path, "x\n");

    try h.gitInit();
    const oracle = try h.gitOracle();
    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.enumerate(all_hidden, &collector);
    try expectSameSet(oracle, collector.sorted());
    try testing.expectEqual(@as(u64, 0), coverage.skipped);
    try testing.expectEqual(@as(usize, 0), coverage.reasons.len);
    try testing.expectEqual(core.IndexState.live, coverage.index_state);
    try testing.expect(h.traverser.report().complete);
    try testing.expect(contains(collector.paths.items, "deep/nested/c.log"));
    try testing.expect(!contains(collector.paths.items, "src/build/out.bin"));
}

test "FS-002 a file under an excluded directory cannot be re-included, contents of a pattern-excluded directory can" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();

    try h.write(".gitignore", "build/\n!build/keep.txt\ncache/*\n!cache/keep.txt\nlogs\n!logs/keep.txt\nvendor/**\n!vendor/keep/\n!vendor/keep/**\n");
    for ([_][]const u8{ "build/keep.txt", "build/drop.txt", "cache/keep.txt", "cache/drop.txt", "logs/keep.txt", "vendor/keep/a.txt", "vendor/drop/b.txt" }) |path| {
        try h.write(path, "x\n");
    }
    try h.gitInit();
    const oracle = try h.gitOracle();
    var collector: Collector = .{ .arena = h.arena };
    _ = try h.enumerate(all_hidden, &collector);
    try expectSameSet(oracle, collector.sorted());
    try testing.expect(!contains(collector.paths.items, "build/keep.txt"));
    try testing.expect(contains(collector.paths.items, "cache/keep.txt"));
    try testing.expect(!contains(collector.paths.items, "logs/keep.txt"));
}

test "FS-003 hidden files, .git and escaped, comment and trailing-space patterns follow the policy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();

    try h.write(".gitignore", "\\#hash.txt\n\\!bang.txt\ntrail\\ \nspace name.txt\nfoo.txt   \n# comment.txt\n\n.secret\n");
    for ([_][]const u8{ "#hash.txt", "!bang.txt", "trail ", "space name.txt", "foo.txt", "# comment.txt", ".secret", ".env", ".config/tool.json", "visible.txt" }) |path| {
        try h.write(path, "x\n");
    }
    try h.gitInit();
    try h.write(".git/info/exclude.probe", "not a source file\n");
    const oracle = try h.gitOracle();

    var with_hidden: Collector = .{ .arena = h.arena };
    _ = try h.enumerate(all_hidden, &with_hidden);
    try expectSameSet(oracle, with_hidden.sorted());
    try testing.expect(contains(with_hidden.paths.items, "# comment.txt"));
    try testing.expect(!contains(with_hidden.paths.items, "trail "));

    var without_hidden: Collector = .{ .arena = h.arena };
    _ = try h.enumerate(.{ .include_hidden = false, .limit = 10_000 }, &without_hidden);
    for (without_hidden.paths.items) |path| {
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| try testing.expect(part.len == 0 or part[0] != '.');
    }
    try testing.expect(contains(without_hidden.paths.items, "visible.txt"));

    // Nothing under .git is ever listed, hidden or not.
    for (with_hidden.paths.items) |path| {
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| try testing.expect(!std.ascii.eqlIgnoreCase(part, ".git"));
    }
}

test "FS-001 single ignore patterns match git check-ignore" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    try h.gitInit();

    const patterns = [_][]const u8{
        "*.zig",     "/root.txt",        "a/*.txt", "**/gen/*.c",   "lib/**", "a/**/z",   "?.md",    "[a-c]x.txt",
        "[!a]y.txt", "[[:digit:]]*.log", "*.[ch]",  "doc/**/*.pdf", "x\\*y",  "foo**bar", "**/deep",
    };
    const candidates = [_][]const u8{
        "main.zig", "src/main.zig", "root.txt", "sub/root.txt", "a/b.txt",  "a/b/c.txt", "x/gen/m.c", "gen/m.c",
        "lib/a/b",  "lib",          "a/z",      "a/b/c/z",      "q.md",     "qq.md",     "bx.txt",    "dx.txt",
        "ay.txt",   "by.txt",       "1a.log",   "a1.log",       "file.h",   "file.hh",   "doc/x.pdf", "doc/a/b/x.pdf",
        "x*y",      "xzy",          "fooXbar",  "foo/bar",      "p/q/deep", "deep",
    };

    for (patterns) |pattern| {
        const line = try std.fmt.allocPrint(h.arena, "{s}\n", .{pattern});
        try h.write(".gitignore", line);
        var rules = try traverse.ignore.RuleStack.init(h.arena, 16, 4 * KiB);
        try rules.pushFile("", line);
        for (candidates) |candidate| {
            const git_says = try gitIgnored(h, candidate);
            const we_say = rules.isIgnored(candidate, false);
            if (git_says != we_say) {
                std.debug.print("pattern {s} path {s}: git={} zcr={}\n", .{ pattern, candidate, git_says, we_say });
                return error.TestExpectedEqual;
            }
        }
    }
}

fn gitIgnored(h: *Harness, path: []const u8) !bool {
    const argv = [_][]const u8{ h.git.exe, "-c", "core.ignorecase=false", "-c", "core.excludesFile=", "check-ignore", "--no-index", "-q", path };
    const result = try std.process.run(h.arena, io, .{ .argv = &argv, .cwd = .{ .path = h.root_path }, .environ_map = &h.env });
    return switch (result.term) {
        .exited => |code| switch (code) {
            0 => true,
            1 => false,
            else => error.FixtureGitFailed,
        },
        else => error.FixtureGitFailed,
    };
}

// ------------------------------------------------------------------ FS-004

/// Creates `dirs` directories of `files_per_dir` empty files under `parent/name`.
fn buildCorpus(parent: Io.Dir, name: []const u8, dirs: usize, files_per_dir: usize) !void {
    try parent.createDir(io, name, .default_dir);
    var root = try parent.openDir(io, name, .{});
    defer root.close(io);
    var buf: [32]u8 = undefined;
    for (0..dirs) |d| {
        const sub = try std.fmt.bufPrint(&buf, "d{d:0>4}", .{d});
        try root.createDir(io, sub, .default_dir);
        var child = try root.openDir(io, sub, .{});
        defer child.close(io);
        for (0..files_per_dir) |f| {
            const file_name = try std.fmt.bufPrint(&buf, "f{d:0>4}.txt", .{f});
            const file = try child.createFile(io, file_name, .{});
            file.close(io);
        }
    }
}

const capability_all: core.Capability = .{ .handle = @enumFromInt(1), .operation = .enumerate, .workspace_id = workspace, .task_id = task, .policy_digest = digest, .path = .{ .bytes = "." } };

// The complete catalog fixture is created on disk; the separate T21 C-large
// performance corpus additionally requires 2 GiB of contents.
test "FS-004 200000 actual files stream with fixed traversal memory and exact coverage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try buildCorpus(tmp.dir, "small", 20, 50);
    try buildCorpus(tmp.dir, "large", 400, 500);

    var counters: memory.accounting.Counters = .{};
    var budget = memory.Budget.init(1, .{ .bytes = 64 * MiB, .fds = 64, .cpu = 4, .output_bytes = 16 * MiB }, &counters);
    const caps: traverse.Caps = .{ .path_cache_entries = 64, .path_cache_bytes = 4 * KiB };
    var flag = std.atomic.Value(bool).init(false);

    var live_per_size: [2]u64 = undefined;
    for ([_]struct { name: []const u8, dirs: u64, files: u64, needle: []const u8 }{
        .{ .name = "small", .dirs = 20, .files = 1_000, .needle = "d0019/f0049.txt" },
        .{ .name = "large", .dirs = 400, .files = 200_000, .needle = "d0399/f0499.txt" },
    }, 0..) |corpus, i| {
        var reservation = try budget.reserve(session(), .{ .scratch_bytes = traverse.Caps.defaultBytes(caps) + 256 * KiB, .fds = 32 });
        defer budget.release(&reservation) catch unreachable;
        var reserved = memory.ReservedAllocator.init(testing.allocator, &reservation, &counters, null);
        const path = try tmp.dir.realPathFileAlloc(io, corpus.name, arena);
        const dir = try Io.Dir.openDirAbsolute(io, path, .{});
        defer dir.close(io);
        var traverser = try traverse.Traverser.init(reserved.allocator(), .{ .dir = dir, .canonical_path = path }, workspace, caps);
        defer traverser.deinit();
        const after_init = reserved.liveBytes();
        live_per_size[i] = after_init;

        // Discovery order: every entry is visited, one match is emitted, nothing is allocated.
        var needle: Collector = .{ .arena = arena };
        const coverage = try traverser.enumerate(io, capability_all, .{ .glob = corpus.needle }, needle.sink(), .{ .requested = &flag });
        try expectSameSet(&.{corpus.needle}, needle.paths.items);
        try testing.expectEqual(corpus.files, traverser.report().files_seen);
        try testing.expectEqual(corpus.dirs + 1, traverser.report().directories_visited);
        try testing.expect(traverser.report().complete);
        try testing.expectEqual(@as(u64, 0), coverage.skipped);
        try testing.expectEqual(after_init, reserved.liveBytes());

        // Search's internal traversal must visit every candidate without using
        // the files response limit. The bitmap is a test oracle, not runtime memory.
        var all: ExactCorpusSink = .{ .files_per_dir = @intCast(corpus.files / corpus.dirs), .dirs = @intCast(corpus.dirs) };
        var search_cap = capability_all;
        search_cap.operation = .search;
        const full = try traverser.enumerateSearchCandidates(io, search_cap, .{}, all.sink(), .{ .requested = &flag });
        try testing.expectEqual(corpus.files, all.count);
        try testing.expectEqual(corpus.files, traverser.report().emitted);
        try testing.expect(traverser.report().complete);
        try testing.expectEqual(@as(u64, 0), full.skipped);
        try testing.expectEqual(after_init, reserved.liveBytes());
        const manifest_hash = corpusDigest(@intCast(corpus.dirs), @intCast(corpus.files / corpus.dirs));
        std.debug.print("FS-004 corpus={s} actual_files={d} candidate_count={d} tracked_live={d} tracked_peak={d} coverage_skipped={d} complete={} corpus_sha256={s}\n", .{ corpus.name, corpus.files, all.count, reserved.liveBytes(), counters.snapshot().peak_live_bytes, full.skipped, traverser.report().complete, std.fmt.bytesToHex(manifest_hash, .lower) });

        // Sorted order with a 64-entry path cache falls back to discovery order and says so.
        var sorted: Collector = .{ .arena = arena };
        const fallback = try traverser.enumerate(io, capability_all, .{ .glob = "d000[0-1]/f000*.txt", .order = .path_then_offset }, sorted.sink(), .{ .requested = &flag });
        try testing.expectEqual(@as(usize, 20), sorted.paths.items.len);
        try testing.expect(traverser.report().order_fallback);
        try testing.expect(fallback.reasons.len > 0);
        try testing.expectEqual(corpus.files, traverser.report().files_seen);
        try testing.expectEqual(after_init, reserved.liveBytes());
    }
    // Two hundred times the files, the same traversal memory.
    try testing.expectEqual(live_per_size[0], live_per_size[1]);
}

const ExactCorpusSink = struct {
    seen: [25_000]u8 = @splat(0),
    files_per_dir: u32,
    dirs: u32,
    count: u64 = 0,

    fn push(ctx: *anyopaque, item: core.RelativePath) core.SinkError!void {
        const self: *ExactCorpusSink = @ptrCast(@alignCast(ctx));
        const p = item.bytes;
        if (p.len != 15 or p[0] != 'd' or !std.mem.eql(u8, p[5..7], "/f") or !std.mem.eql(u8, p[11..], ".txt")) return error.OutputBudgetExceeded;
        const d = std.fmt.parseInt(u32, p[1..5], 10) catch return error.OutputBudgetExceeded;
        const f = std.fmt.parseInt(u32, p[7..11], 10) catch return error.OutputBudgetExceeded;
        if (d >= self.dirs or f >= self.files_per_dir) return error.OutputBudgetExceeded;
        const index = d * self.files_per_dir + f;
        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(index % 8));
        if (self.seen[index / 8] & bit != 0) return error.OutputBudgetExceeded;
        self.seen[index / 8] |= bit;
        self.count += 1;
    }

    fn sink(self: *ExactCorpusSink) core.Sink(core.RelativePath) {
        return .{ .context = self, .push_fn = push };
    }
};

// SHA-256 of lexicographically sorted relative path + NUL + SHA256(empty file).
fn corpusDigest(dirs: u32, files_per_dir: u32) [32]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var empty_hash: [32]u8 = undefined;
    Sha256.hash("", &empty_hash, .{});
    var hash = Sha256.init(.{});
    var buf: [32]u8 = undefined;
    for (0..dirs) |d| for (0..files_per_dir) |f| {
        const path = std.fmt.bufPrint(&buf, "d{d:0>4}/f{d:0>4}.txt", .{ d, f }) catch unreachable;
        hash.update(path);
        hash.update("\x00");
        hash.update(&empty_hash);
    };
    return hash.finalResult();
}

// ------------------------------------------------------------------ FS-005, FS-006

test "FS-005 symlink loops are not followed and an unreadable directory makes the result incomplete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();

    try h.write("a/file.txt", "x\n");
    try h.write("locked/secret.txt", "x\n");
    try h.write("ok.txt", "x\n");
    try h.tmp.dir.symLink(io, ".", "loop", .{ .is_directory = true });
    try h.tmp.dir.symLink(io, "../a", "a/back", .{ .is_directory = true });
    try h.tmp.dir.symLink(io, "ok.txt", "link-to-file", .{});

    const locked = try std.fmt.allocPrintSentinel(h.arena, "{s}/locked", .{h.root_path}, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(locked.ptr, 0o000));
    defer _ = std.c.chmod(locked.ptr, 0o755);

    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.enumerate(all_hidden, &collector);
    try expectSameSet(&.{ "a/file.txt", "ok.txt" }, collector.sorted());
    try testing.expect(coverage.skipped >= 1);
    try testing.expect(coverage.reasons.len > 0);
    const report = h.traverser.report();
    try testing.expect(!report.complete);
    try testing.expectEqual(@as(u64, 1), report.unreadable_directories);
    try testing.expectEqual(@as(u64, 3), report.symlinks_not_followed);
}

test "FS-006 Unicode names come back byte for byte and unsupported names are counted, not dropped silently" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();

    // One normalization form only: APFS treats e + U+0301 and U+00E9 as the same name.
    const unicode = [_][]const u8{ "한글.txt", "e\u{301}.txt", "😀/emoji.txt", "newline\nname.txt" };
    for (unicode) |name| try h.write(name, "x\n");
    try h.write("back\\slash.txt", "x\n");

    // Invalid UTF-8: some file systems refuse the name outright.
    const bad = try std.fmt.allocPrintSentinel(h.arena, "{s}/bad\xff.txt", .{h.root_path}, 0);
    const fd = std.c.open(bad.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    const invalid_created = fd >= 0;
    if (invalid_created) _ = std.c.close(fd);

    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.enumerate(all_hidden, &collector);
    for (unicode) |name| try testing.expect(contains(collector.paths.items, name));
    try testing.expect(!contains(collector.paths.items, "back\\slash.txt"));

    const report = h.traverser.report();
    const expected_unsupported: u64 = if (invalid_created) 2 else 1;
    try testing.expectEqual(expected_unsupported, report.unsupported_names);
    try testing.expectEqual(expected_unsupported, coverage.skipped);
    try testing.expect(!report.complete);
    if (builtin.os.tag == .macos) try testing.expect(!invalid_created); // APFS requires valid UTF-8 names
}

// ------------------------------------------------------------------ order, glob, limits, contracts

test "T05 sorted order, glob filter and result limit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    for ([_][]const u8{ "a.txt", "a-c/x.zig", "a/b.zig", "B.zig", "a/c/d.zig", "z.md" }) |path| try h.write(path, "x\n");

    var sorted: Collector = .{ .arena = h.arena };
    _ = try h.enumerate(.{ .order = .path_then_offset, .limit = 100 }, &sorted);
    // Component-wise byte order: a directory's entries are sorted before descending.
    try expectSameSet(&.{ "B.zig", "a/b.zig", "a/c/d.zig", "a-c/x.zig", "a.txt", "z.md" }, sorted.paths.items);
    try testing.expect(!h.traverser.report().order_fallback);

    var zig_only: Collector = .{ .arena = h.arena };
    _ = try h.enumerate(.{ .glob = "**/*.zig", .order = .path_then_offset }, &zig_only);
    try expectSameSet(&.{ "B.zig", "a/b.zig", "a/c/d.zig", "a-c/x.zig" }, zig_only.paths.items);

    var limited: Collector = .{ .arena = h.arena };
    const coverage = try h.enumerate(.{ .order = .path_then_offset, .limit = 2 }, &limited);
    try testing.expectEqual(@as(usize, 2), limited.paths.items.len);
    try testing.expect(h.traverser.report().truncated);
    try testing.expect(!h.traverser.report().complete);
    try testing.expect(coverage.reasons.len > 0);
}

test "T05 capability, spec, cancellation and sink backpressure are enforced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    for (0..50) |i| try h.write(try std.fmt.allocPrint(h.arena, "d/f{d}.txt", .{i}), "x\n");
    try h.write(".gitignore", "*.tmp\nignored-dir/\n");
    try h.write("d/x.tmp", "x\n");
    try h.write("ignored-dir/y.txt", "x\n");

    var collector: Collector = .{ .arena = h.arena };
    var read_cap = try h.authorizer.authorize(io, session(), .read, .{ .bytes = "d/f1.txt" });
    try testing.expectError(error.OutOfScope, h.traverser.enumerate(io, read_cap, .{}, collector.sink(), h.cancel()));
    read_cap = try h.authorizer.authorize(io, session(), .enumerate, .{ .bytes = "." });
    read_cap.workspace_id.incarnation = @splat(0x99);
    try testing.expectError(error.OutOfScope, h.traverser.enumerate(io, read_cap, .{}, collector.sink(), h.cancel()));

    const cap = try h.authorizer.authorize(io, session(), .enumerate, .{ .bytes = "." });
    try testing.expectError(error.Unsupported, h.traverser.enumerate(io, cap, .{ .consistency = .bounded_stale }, collector.sink(), h.cancel()));
    try testing.expectError(error.InvalidArgument, h.traverser.enumerate(io, cap, .{ .limit = 0 }, collector.sink(), h.cancel()));
    try testing.expectError(error.InvalidArgument, h.traverser.enumerate(io, cap, .{ .limit = 10_001 }, collector.sink(), h.cancel()));
    try testing.expectError(error.InvalidArgument, h.traverser.enumerate(io, cap, .{ .glob = "" }, collector.sink(), h.cancel()));

    // A subdirectory capability limits the walk to that subtree, with root-relative paths.
    const sub_cap = try h.authorizer.authorize(io, session(), .enumerate, .{ .bytes = "d" });
    var sub: Collector = .{ .arena = h.arena };
    _ = try h.traverser.enumerate(io, sub_cap, .{ .limit = 100 }, sub.sink(), h.cancel());
    try testing.expectEqual(@as(usize, 50), sub.paths.items.len); // root .gitignore still hides d/x.tmp
    try testing.expect(std.mem.startsWith(u8, sub.paths.items[0], "d/f"));
    try testing.expect(!contains(sub.paths.items, "d/x.tmp"));

    // A start directory that an ancestor .gitignore excludes lists nothing and says why.
    const ignored_cap = try h.authorizer.authorize(io, session(), .enumerate, .{ .bytes = "ignored-dir" });
    var none: Collector = .{ .arena = h.arena };
    const ignored_coverage = try h.traverser.enumerate(io, ignored_cap, .{ .limit = 100 }, none.sink(), h.cancel());
    try testing.expectEqual(@as(usize, 0), none.paths.items.len);
    try testing.expect(h.traverser.report().start_ignored);
    try testing.expect(ignored_coverage.reasons.len > 0);

    h.cancel_flag.store(true, .release);
    try testing.expectError(error.Cancelled, h.traverser.enumerate(io, cap, .{}, collector.sink(), h.cancel()));
    h.cancel_flag.store(false, .release);

    var slow: Collector = .{ .arena = h.arena, .accept = 5, .refuse_with = error.Busy };
    try testing.expectError(error.Busy, h.traverser.enumerate(io, cap, .{}, slow.sink(), h.cancel()));
    try testing.expectEqual(@as(usize, 5), slow.paths.items.len);

    // After every error the traverser is reusable and holds no extra memory.
    const live = h.reserved.liveBytes();
    var again: Collector = .{ .arena = h.arena };
    _ = try h.enumerate(.{ .limit = 100 }, &again);
    try testing.expectEqual(@as(usize, 50), again.paths.items.len);
    try testing.expectEqual(live, h.reserved.liveBytes());
}

const CancelOnPush = struct {
    collector: Collector,
    flag: *std.atomic.Value(bool),

    fn push(context: *anyopaque, item: core.RelativePath) core.SinkError!void {
        const self: *CancelOnPush = @ptrCast(@alignCast(context));
        self.flag.store(true, .release);
        return Collector.push(&self.collector, item);
    }
};

test "T05 cancellation requested during a walk stops it within a bounded number of entries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    for (0..2000) |i| try h.write(try std.fmt.allocPrint(h.arena, "many/f{d:0>4}.txt", .{i}), "");

    var cancelling: CancelOnPush = .{ .collector = .{ .arena = h.arena }, .flag = &h.cancel_flag };
    const cap = try h.authorizer.authorize(io, session(), .enumerate, .{ .bytes = "." });
    const sink: core.Sink(core.RelativePath) = .{ .context = &cancelling, .push_fn = CancelOnPush.push };
    try testing.expectError(error.Cancelled, h.traverser.enumerate(io, cap, .{ .limit = 10_000 }, sink, h.cancel()));
    try testing.expect(cancelling.collector.paths.items.len < 2000);
    try testing.expect(h.traverser.report().entries_seen <= 2 * 256);
    h.cancel_flag.store(false, .release);
}

test "T05 ignore files beyond the size or rule limit exclude their subtree and are reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{ .max_ignore_file_bytes = 64, .max_ignore_rules = 4 });
    defer h.deinit();

    try h.write("ok/.gitignore", "*.tmp\n");
    try h.write("ok/a.txt", "x\n");
    try h.write("ok/b.tmp", "x\n");
    try h.write("big/.gitignore", "# " ++ "x" ** 80 ++ "\n*.tmp\n");
    try h.write("big/c.txt", "x\n");
    try h.write("many/.gitignore", "a\nb\nc\nd\ne\n");
    try h.write("many/d.txt", "x\n");

    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.enumerate(all_hidden, &collector);
    // Without its rules a subtree could leak ignored files, so it is not listed at all.
    try expectSameSet(&.{ "ok/.gitignore", "ok/a.txt" }, collector.sorted());
    try testing.expectEqual(@as(u64, 2), coverage.skipped);
    try testing.expectEqual(@as(u64, 2), h.traverser.report().ignore_limits_exceeded);
    try testing.expect(!h.traverser.report().complete);
}
