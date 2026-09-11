//! I01 authorization (T02). S02 RED stub: public API only.

const std = @import("std");
const core = @import("zcr_core");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const paths = @import("paths.zig");
pub const scope = @import("scope.zig");

pub const Authorizer = struct {
    root: core.TrustedRoot,
    workspace_id: core.WorkspaceId,
    task_id: core.TaskId,
    policy: core.Policy,

    pub fn init(
        arena: Allocator,
        io: Io,
        root: core.TrustedRoot,
        workspace_id: core.WorkspaceId,
        task_id: core.TaskId,
        policy: core.Policy,
        git: core.GitMetadata,
    ) !Authorizer {
        _ = .{ arena, io, git };
        return .{ .root = root, .workspace_id = workspace_id, .task_id = task_id, .policy = policy };
    }

    pub fn authorize(
        self: *Authorizer,
        io: Io,
        session: core.SessionContext,
        operation: core.Operation,
        path: core.RelativePath,
    ) core.AuthorizeError!core.Capability {
        _ = .{ self, io, session, operation, path };
        return error.Unsupported;
    }

    comptime {
        core.conforms(core.AuthorizeFn(Authorizer), Authorizer.authorize);
    }
};
