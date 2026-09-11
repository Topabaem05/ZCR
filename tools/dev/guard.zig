//! Development scope and ownership guard (T02). S02 RED stub: public API only.

const std = @import("std");
const core = @import("zcr_core");
const evidence = @import("evidence");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ChangeKind = enum { added, modified, deleted, renamed, copied, type_changed, unmerged, untracked };
pub const ChangeSource = enum { committed, working_tree };
pub const Change = struct {
    kind: ChangeKind,
    path: []const u8,
    orig_path: ?[]const u8 = null,
    symlink: bool = false,
    source: ChangeSource,
};

pub const Role = enum { task, integrator };
pub const Reason = enum { outside_owned_paths, integrator_owned, symlink };
pub const Violation = struct { path: []const u8, reason: Reason, change: ChangeKind };

pub const default_integrator_paths = [_][]const u8{ "build.zig", "build.zig.zon", "src/core", "contracts", "config", "AGENTS.md", ".github" };

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

pub fn scopeGuard(arena: Allocator, io: Io, git: evidence.Git, worktree: []const u8, base_commit: []const u8, rules: Rules, role: Role) !Report {
    _ = .{ arena, io, git, worktree, base_commit, rules, role };
    return error.NotImplemented;
}

pub fn loadTasks(arena: Allocator, io: Io, tasks_json_path: []const u8) ![]const TaskOwnership {
    _ = .{ arena, io, tasks_json_path };
    return error.NotImplemented;
}

pub fn rulesFor(arena: Allocator, tasks: []const TaskOwnership, task_id: []const u8) !Rules {
    _ = .{ arena, tasks, task_id };
    return error.NotImplemented;
}

pub fn roleFor(task_id: []const u8) Role {
    _ = task_id;
    return .task;
}

pub fn findOwnershipOverlaps(arena: Allocator, tasks: []const TaskOwnership) ![]const Overlap {
    _ = .{ arena, tasks };
    return error.NotImplemented;
}

pub fn main() u8 {
    return 1;
}
