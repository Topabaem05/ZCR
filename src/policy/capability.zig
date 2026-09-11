//! I01 authorization (T02; docs/06, docs/11 §2).
//!
//! `Authorizer` holds the trusted inputs a request cannot change: root handle,
//! workspace and task binding, the active policy snapshot, and the identities
//! of Git metadata and immutable paths. `authorize` checks, in order:
//!   1. session binding (workspace, task, policy digest),
//!   2. path syntax (paths.zig),
//!   3. task scope and operation (scope.zig),
//!   4. a no-follow walk under the root handle, refusing symlinks,
//!   5. protected identities: Git metadata for every access, immutable paths for writes,
//!   6. the file type the operation needs.
//! The resulting capability is a check, not an open handle; see paths.zig for
//! the race limits that callers must handle.

const std = @import("std");
const core = @import("zcr_core");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const paths = @import("paths.zig");
pub const scope = @import("scope.zig");

pub const InitError = paths.StatError || paths.SyntaxError || Allocator.Error;

pub const Authorizer = struct {
    root: core.TrustedRoot,
    workspace_id: core.WorkspaceId,
    task_id: core.TaskId,
    policy: core.Policy,
    /// Root `.git` entry (file or directory), per-worktree git dir and common git dir.
    git_identities: []const paths.Identity,
    /// Immutable paths that existed when the authorizer was built.
    immutable_identities: []const paths.Identity,
    next_handle: std.atomic.Value(u64) = .init(1),

    /// `root`, `policy` and `git` must come from trusted launch configuration and
    /// Git discovery, never from request arguments. `arena` owns the identity lists.
    pub fn init(
        arena: Allocator,
        io: Io,
        root: core.TrustedRoot,
        workspace_id: core.WorkspaceId,
        task_id: core.TaskId,
        policy: core.Policy,
        git: core.GitMetadata,
    ) InitError!Authorizer {
        var git_ids: std.ArrayList(paths.Identity) = .empty;
        if (try paths.statAt(root.dir.handle, ".git")) |entry| try git_ids.append(arena, entry.identity);
        for ([_]?[]const u8{ git.git_dir, git.common_dir }) |maybe_dir| {
            const dir_path = maybe_dir orelse continue;
            var dir = Io.Dir.openDirAbsolute(io, dir_path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.AccessDenied, error.PermissionDenied => return error.OutOfScope,
                else => return error.IoFailure,
            };
            defer dir.close(io);
            try git_ids.append(arena, (try paths.statHandle(dir.handle)).identity);
        }

        var immutable_ids: std.ArrayList(paths.Identity) = .empty;
        for (policy.immutable_paths) |immutable| {
            const resolved = paths.resolve(io, root.dir, immutable.bytes) catch |err| switch (err) {
                error.NotFound => continue,
                else => |e| return e,
            };
            if (resolved.final()) |entry| try immutable_ids.append(arena, entry.identity);
        }

        return .{
            .root = root,
            .workspace_id = workspace_id,
            .task_id = task_id,
            .policy = policy,
            .git_identities = git_ids.items,
            .immutable_identities = immutable_ids.items,
        };
    }

    pub fn authorize(
        self: *Authorizer,
        io: Io,
        session: core.SessionContext,
        operation: core.Operation,
        path: core.RelativePath,
    ) core.AuthorizeError!core.Capability {
        if (!session.bound_workspace.eql(self.workspace_id) or
            !std.mem.eql(u8, &session.bound_task.uuid, &self.task_id.uuid) or
            !std.mem.eql(u8, &session.policy_digest, &self.policy.digest)) return error.OutOfScope;

        const access = scope.accessFor(operation);
        if (access != .none) try paths.validate(path.bytes);
        try scope.check(&self.policy, operation, path.bytes);

        if (access != .none) {
            const resolved = try paths.resolve(io, self.root.dir, path.bytes);
            for (resolved.entries()) |entry| {
                if (containsIdentity(self.git_identities, entry.identity)) return error.OutOfScope;
                if (access == .write and containsIdentity(self.immutable_identities, entry.identity)) return error.OutOfScope;
            }
            try checkKind(operation, &resolved);
        }

        return .{
            .handle = @enumFromInt(self.next_handle.fetchAdd(1, .monotonic)),
            .operation = operation,
            .workspace_id = self.workspace_id,
            .task_id = self.task_id,
            .policy_digest = self.policy.digest,
            .path = path,
        };
    }

    comptime {
        core.conforms(core.AuthorizeFn(Authorizer), Authorizer.authorize);
    }
};

fn containsIdentity(list: []const paths.Identity, identity: paths.Identity) bool {
    for (list) |item| {
        if (item.eql(identity)) return true;
    }
    return false;
}

/// File type each operation needs. `create` only needs existing parents; whether
/// an existing target conflicts is decided at publish time (T11).
fn checkKind(operation: core.Operation, resolved: *const paths.Resolved) error{ NotFound, NotRegular }!void {
    switch (operation) {
        .create => if (!resolved.parentExists()) return error.NotFound,
        .read, .batch_read, .patch => {
            const entry = resolved.final() orelse return error.NotFound;
            if (entry.kind != .regular) return error.NotRegular;
        },
        .enumerate, .search => {
            const entry = resolved.final() orelse return error.NotFound;
            if (entry.kind != .regular and entry.kind != .directory) return error.NotRegular;
        },
        .status, .health => {},
    }
}
