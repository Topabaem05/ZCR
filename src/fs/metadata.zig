//! File metadata snapshots and regular-file opens (T04; docs/07 §2, docs/11 §2).
//!
//! `openRegular` resolves the path under the root handle without following
//! symlinks (zcr_policy.paths), refuses anything that is not a regular file
//! before opening it (a FIFO is never opened), opens with no-follow, and checks
//! that the opened handle is the file that was resolved. A mismatch means the
//! path changed in between and is reported as `Changed` so the caller can retry.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const Io = std.Io;
const Identity = policy.paths.Identity;

pub const Snapshot = struct {
    identity: Identity,
    size: u64,
    mtime_ns: i128,
};

pub const OpenError = error{ InvalidArgument, NotFound, NotRegular, PathEscape, OutOfScope, IoFailure, Changed };

pub const Opened = struct { file: Io.File, before: Snapshot };

pub fn snapshot(io: Io, file: Io.File) error{IoFailure}!Snapshot {
    const stat = file.stat(io) catch return error.IoFailure;
    const entry = policy.paths.statHandle(file.handle) catch return error.IoFailure;
    return .{ .identity = entry.identity, .size = stat.size, .mtime_ns = stat.mtime.nanoseconds };
}

/// Same file identity, size and modification time. Writes that keep all three
/// identical (same size within the same timestamp) cannot be detected here.
pub fn sameVersion(a: Snapshot, b: Snapshot) bool {
    return a.identity.eql(b.identity) and a.size == b.size and a.mtime_ns == b.mtime_ns;
}

pub fn fileVersion(workspace_id: core.WorkspaceId, generation: u64, s: Snapshot, sha256: ?core.ContentHash) core.FileVersion {
    return .{
        .workspace_id = workspace_id,
        .file_id = .{ .device = s.identity.device, .inode = s.identity.inode },
        .generation = generation,
        .size = s.size,
        .mtime_ns = s.mtime_ns,
        .sha256 = sha256,
    };
}

pub fn openRegular(io: Io, root: Io.Dir, path: []const u8) OpenError!Opened {
    const resolved = try resolveFinal(io, root, path);
    const entry = resolved orelse return error.NotFound;
    if (entry.kind != .regular) return error.NotRegular;

    const file = root.openFile(io, path, .{ .mode = .read_only, .follow_symlinks = false, .allow_directory = false }) catch |err| return switch (err) {
        error.SymLinkLoop => error.PathEscape,
        error.FileNotFound, error.IsDir, error.NotDir => error.Changed,
        error.AccessDenied, error.PermissionDenied => error.OutOfScope,
        else => error.IoFailure,
    };
    errdefer file.close(io);
    const before = try snapshot(io, file);
    if (!before.identity.eql(entry.identity)) return error.Changed;
    return .{ .file = file, .before = before };
}

/// Identity the path resolves to now, or null when it no longer exists.
pub fn pathIdentity(io: Io, root: Io.Dir, path: []const u8) OpenError!?Identity {
    const entry = try resolveFinal(io, root, path) orelse return null;
    return entry.identity;
}

fn resolveFinal(io: Io, root: Io.Dir, path: []const u8) OpenError!?policy.paths.Entry {
    const resolved = policy.paths.resolve(io, root, path) catch |err| return switch (err) {
        error.InvalidArgument => error.InvalidArgument,
        error.PathEscape => error.PathEscape,
        error.NotFound => error.NotFound,
        error.OutOfScope => error.OutOfScope,
        error.IoFailure => error.IoFailure,
    };
    return resolved.final();
}
