//! Development scope and ownership guard (T02; DEV-01, DEV-02; docs/06 §7, docs/13 §5).
//!
//!   scope      every path changed since the task base (committed, staged, unstaged,
//!              untracked, both sides of renames, deletions) must be owned by the task;
//!              integrator-owned paths need the integrator role; symlinks are refused
//!   ownership  no path is owned by two tasks, and only the integrator task owns
//!              integrator paths
//!
//! Git runs with explicit argv and `-C <worktree>` and NUL-separated output. The
//! guard only reads: it never stashes, resets, checks out or cleans. Text inside
//! the repository is data, not permission.

const std = @import("std");
const core = @import("zcr_core");
const evidence = @import("evidence");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const git_timeout_ms = 30_000;
const max_git_output = 16 * 1024 * 1024;
const max_tasks_file = 4 * 1024 * 1024;

pub const ChangeKind = enum { added, modified, deleted, renamed, copied, type_changed, unmerged, untracked };
pub const ChangeSource = enum { committed, working_tree };

pub const Change = struct {
    kind: ChangeKind,
    path: []const u8,
    /// Source path of a rename or copy; it is changed too.
    orig_path: ?[]const u8 = null,
    symlink: bool = false,
    source: ChangeSource,
};

pub const Role = enum { task, integrator };
pub const Reason = enum { outside_owned_paths, integrator_owned, symlink };
pub const Violation = struct { path: []const u8, reason: Reason, change: ChangeKind };

/// docs/13 §2: build files, core public types, contracts, top-level policy and CI belong to the integrator.
pub const default_integrator_paths = [_][]const u8{ "build.zig", "build.zig.zon", "src/core", "contracts", "config", "AGENTS.md", ".github" };
pub const integrator_tasks = [_][]const u8{"T01"};

pub const Rules = struct {
    task_id: []const u8,
    owned_paths: []const []const u8,
    integrator_paths: []const []const u8 = &default_integrator_paths,
};

pub const Report = struct {
    changes: []const Change,
    violations: []const Violation,

    pub fn ok(report: Report) bool {
        return report.violations.len == 0;
    }
};

pub const TaskOwnership = struct { task_id: []const u8, owns: []const []const u8 };
pub const Overlap = struct { path: []const u8, first_task: []const u8, second_task: []const u8 };

// ------------------------------------------------------------------ scope

pub fn scopeGuard(arena: Allocator, io: Io, git: evidence.Git, worktree: []const u8, base_commit: []const u8, rules: Rules, role: Role) !Report {
    const changes = try collectChanges(arena, io, git, worktree, base_commit);
    return checkChanges(arena, changes, rules, role);
}

/// Changes committed since `base_commit` plus index, working tree and untracked files.
pub fn collectChanges(arena: Allocator, io: Io, git: evidence.Git, worktree: []const u8, base_commit: []const u8) ![]const Change {
    var changes: std.ArrayList(Change) = .empty;

    const diff = try gitOutput(arena, io, git, worktree, &.{ "diff", "--raw", "-z", "-M", "--no-abbrev", "--no-ext-diff", base_commit, "HEAD" });
    try parseRawDiff(arena, diff, &changes);

    const state = try evidence.inspect(arena, io, git, worktree);
    for (state.entries) |entry| {
        try changes.append(arena, .{
            .kind = std.meta.stringToEnum(ChangeKind, @tagName(entry.kind)).?,
            .path = entry.path,
            .orig_path = entry.orig_path,
            .symlink = try isSymlink(arena, io, worktree, entry.path),
            .source = .working_tree,
        });
    }
    return changes.items;
}

/// `git diff --raw -z`: `:<old mode> <new mode> <old sha> <new sha> <status>` NUL
/// `<path>` NUL, with a second path for renames and copies.
pub fn parseRawDiff(arena: Allocator, bytes: []const u8, changes: *std.ArrayList(Change)) !void {
    var fields = std.mem.splitScalar(u8, bytes, 0);
    while (fields.next()) |meta| {
        if (meta.len == 0) continue;
        if (meta[0] != ':') return error.MalformedGitDiff;
        var parts = std.mem.tokenizeScalar(u8, meta[1..], ' ');
        _ = parts.next() orelse return error.MalformedGitDiff; // old mode
        const new_mode = parts.next() orelse return error.MalformedGitDiff;
        _ = parts.next() orelse return error.MalformedGitDiff; // old object
        _ = parts.next() orelse return error.MalformedGitDiff; // new object
        const status = parts.next() orelse return error.MalformedGitDiff;
        if (status.len == 0) return error.MalformedGitDiff;

        const first = fields.next() orelse return error.MalformedGitDiff;
        const kind: ChangeKind = switch (status[0]) {
            'A' => .added,
            'M' => .modified,
            'D' => .deleted,
            'R' => .renamed,
            'C' => .copied,
            'T' => .type_changed,
            'U' => .unmerged,
            else => return error.MalformedGitDiff,
        };
        var change: Change = .{ .kind = kind, .path = first, .symlink = std.mem.eql(u8, new_mode, "120000"), .source = .committed };
        if (kind == .renamed or kind == .copied) {
            change.orig_path = first;
            change.path = fields.next() orelse return error.MalformedGitDiff;
        }
        try changes.append(arena, change);
    }
}

pub fn checkChanges(arena: Allocator, changes: []const Change, rules: Rules, role: Role) !Report {
    var violations: std.ArrayList(Violation) = .empty;
    for (changes) |change| {
        for ([_]?[]const u8{ change.path, change.orig_path }) |maybe_path| {
            const path = maybe_path orelse continue;
            if (role == .integrator) continue;
            if (coveredByAny(rules.integrator_paths, path)) {
                try addViolation(arena, &violations, .{ .path = path, .reason = .integrator_owned, .change = change.kind });
            } else if (!coveredByAny(rules.owned_paths, path)) {
                try addViolation(arena, &violations, .{ .path = path, .reason = .outside_owned_paths, .change = change.kind });
            }
        }
        if (change.symlink) try addViolation(arena, &violations, .{ .path = change.path, .reason = .symlink, .change = change.kind });
    }
    return .{ .changes = changes, .violations = violations.items };
}

fn addViolation(arena: Allocator, violations: *std.ArrayList(Violation), violation: Violation) !void {
    for (violations.items) |existing| {
        if (existing.reason == violation.reason and std.mem.eql(u8, existing.path, violation.path)) return;
    }
    try violations.append(arena, violation);
}

// ------------------------------------------------------------------ ownership

pub fn roleFor(task_id: []const u8) Role {
    for (integrator_tasks) |id| {
        if (std.mem.eql(u8, id, task_id)) return .integrator;
    }
    return .task;
}

/// Reads tasks/tasks.json. Each task also owns `tests/<id>_test.zig` and
/// `evidence/<ID>/`, as every task document requires.
pub fn loadTasks(arena: Allocator, io: Io, tasks_json_path: []const u8) ![]const TaskOwnership {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, tasks_json_path, arena, .limited(max_tasks_file));
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const list = switch (doc) {
        .object => |object| object.get("tasks") orelse return error.MalformedTasks,
        else => return error.MalformedTasks,
    };
    if (list != .array) return error.MalformedTasks;

    var tasks: std.ArrayList(TaskOwnership) = .empty;
    for (list.array.items) |item| {
        if (item != .object) return error.MalformedTasks;
        const id = item.object.get("id") orelse return error.MalformedTasks;
        const owns = item.object.get("owns") orelse return error.MalformedTasks;
        if (id != .string or owns != .array) return error.MalformedTasks;

        var paths: std.ArrayList([]const u8) = .empty;
        for (owns.array.items) |owned| {
            if (owned != .string) return error.MalformedTasks;
            try paths.append(arena, owned.string);
        }
        const lower = try std.ascii.allocLowerString(arena, id.string);
        try paths.append(arena, try std.fmt.allocPrint(arena, "tests/{s}_test.zig", .{lower}));
        try paths.append(arena, try std.fmt.allocPrint(arena, "evidence/{s}", .{id.string}));
        try tasks.append(arena, .{ .task_id = id.string, .owns = paths.items });
    }
    return tasks.items;
}

pub fn rulesFor(arena: Allocator, tasks: []const TaskOwnership, task_id: []const u8) !Rules {
    _ = arena;
    for (tasks) |t| {
        if (std.mem.eql(u8, t.task_id, task_id)) return .{ .task_id = t.task_id, .owned_paths = t.owns };
    }
    return error.UnknownTask;
}

/// Pairs of tasks whose owned paths cover each other, and non-integrator tasks
/// that own integrator paths (reported against the pseudo-owner "integrator").
pub fn findOwnershipOverlaps(arena: Allocator, tasks: []const TaskOwnership) ![]const Overlap {
    var overlaps: std.ArrayList(Overlap) = .empty;
    for (tasks, 0..) |a, i| {
        for (a.owns) |path_a| {
            if (roleFor(a.task_id) == .task) {
                for (default_integrator_paths) |integrator_path| {
                    if (covers(integrator_path, path_a) or covers(path_a, integrator_path)) {
                        try overlaps.append(arena, .{ .path = path_a, .first_task = a.task_id, .second_task = "integrator" });
                        break;
                    }
                }
            }
            for (tasks[i + 1 ..]) |b| {
                for (b.owns) |path_b| {
                    if (covers(path_a, path_b) or covers(path_b, path_a)) {
                        try overlaps.append(arena, .{
                            .path = if (path_a.len >= path_b.len) path_a else path_b,
                            .first_task = a.task_id,
                            .second_task = b.task_id,
                        });
                    }
                }
            }
        }
    }
    return overlaps.items;
}

// ------------------------------------------------------------------ helpers

/// Component-wise prefix match: `src` covers `src` and `src/x`, not `src2`.
pub fn covers(prefix: []const u8, path: []const u8) bool {
    const p = std.mem.trimEnd(u8, prefix, "/");
    if (p.len == 0 or std.mem.eql(u8, p, ".")) return true;
    if (!std.mem.startsWith(u8, path, p)) return false;
    return path.len == p.len or path[p.len] == '/';
}

fn coveredByAny(list: []const []const u8, path: []const u8) bool {
    for (list) |prefix| {
        if (covers(prefix, path)) return true;
    }
    return false;
}

fn isSymlink(arena: Allocator, io: Io, worktree: []const u8, path: []const u8) !bool {
    const full = try std.fs.path.join(arena, &.{ worktree, path });
    const stat = Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .sym_link;
}

fn gitOutput(arena: Allocator, io: Io, git: evidence.Git, worktree: []const u8, args: []const []const u8) ![]const u8 {
    const argv = try arena.alloc([]const u8, args.len + 3);
    argv[0] = git.exe;
    argv[1] = "-C";
    argv[2] = worktree;
    @memcpy(argv[3..], args);
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .environ_map = git.environ,
        .stdout_limit = .limited(max_git_output),
        .stderr_limit = .limited(max_git_output),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(git_timeout_ms), .clock = .awake } },
    });
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    std.log.debug("git {s} failed: {s}", .{ args[0], result.stderr });
    return error.GitCommandFailed;
}

// ------------------------------------------------------------------ CLI

const usage =
    \\usage: zcr-dev-guard <command> [options]
    \\
    \\  scope      --worktree DIR --base COMMIT --tasks tasks/tasks.json --task ID [--role task|integrator]
    \\  ownership  --tasks tasks/tasks.json
    \\
    \\exit: 0 no violations, 1 violations, 64 usage error
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var argv = init.minimal.args.iterate();
    _ = argv.skip();
    const command = argv.next() orelse return usageError(io);

    var keys: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    while (argv.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) return usageError(io);
        try keys.append(arena, arg[2..]);
        try values.append(arena, argv.next() orelse return usageError(io));
    }
    const lookup = struct {
        fn get(k: []const []const u8, v: []const []const u8, key: []const u8) ?[]const u8 {
            for (k, v) |name, value| if (std.mem.eql(u8, name, key)) return value;
            return null;
        }
    }.get;

    const tasks_path = lookup(keys.items, values.items, "tasks") orelse return usageError(io);
    const tasks = try loadTasks(arena, io, tasks_path);
    const stdout = Io.File.stdout();

    if (std.mem.eql(u8, command, "ownership")) {
        const overlaps = try findOwnershipOverlaps(arena, tasks);
        try stdout.writeStreamingAll(io, try std.json.Stringify.valueAlloc(arena, .{ .overlaps = overlaps }, .{ .whitespace = .indent_2 }));
        try stdout.writeStreamingAll(io, "\n");
        return if (overlaps.len == 0) 0 else 1;
    }
    if (std.mem.eql(u8, command, "scope")) {
        const worktree = lookup(keys.items, values.items, "worktree") orelse return usageError(io);
        const base = lookup(keys.items, values.items, "base") orelse return usageError(io);
        const task_id = lookup(keys.items, values.items, "task") orelse return usageError(io);
        const role = if (lookup(keys.items, values.items, "role")) |r| std.meta.stringToEnum(Role, r) orelse return usageError(io) else roleFor(task_id);
        const rules = rulesFor(arena, tasks, task_id) catch return usageError(io);
        const git = try evidence.findGit(arena, io, init.environ_map);
        const report = try scopeGuard(arena, io, git, worktree, base, rules, role);
        try stdout.writeStreamingAll(io, try std.json.Stringify.valueAlloc(arena, .{ .task = task_id, .role = role, .violations = report.violations, .changes = report.changes }, .{ .whitespace = .indent_2 }));
        try stdout.writeStreamingAll(io, "\n");
        return if (report.ok()) 0 else 1;
    }
    return usageError(io);
}

fn usageError(io: Io) u8 {
    Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return 64;
}
