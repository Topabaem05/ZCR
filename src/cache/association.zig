//! Workspace-scoped associations are hints; checked-live hits hash every byte.
const std = @import("std");
const core = @import("zcr_core");
const paths = @import("zcr_policy").paths;
const Io = std.Io;
const builtin = @import("builtin");
/// Deterministic race/cancel hooks are absent from production storage and calls.
pub const TestHooks = struct { context: *anyopaque, after_chunk: ?*const fn (*anyopaque) void = null, before_open: ?*const fn (*anyopaque) void = null };
pub var test_hooks: if (builtin.is_test) ?TestHooks else void = if (builtin.is_test) null else {};
pub const max_path = core.limits.values.path_max_utf8_bytes;
pub const Key = struct { workspace: core.WorkspaceId, generation: u64, file_id: core.FileId, domain: core.SecurityDomain, hash: core.ContentHash };
pub const Entry = struct {
    occupied: bool = false,
    valid: bool = false,
    key: Key = undefined,
    path: [max_path]u8 = undefined,
    path_len: usize = 0,
    pins: usize = 0,
    touched: u64 = 0,
    pub fn matches(e: *const Entry, key: Key, path: []const u8) bool {
        return e.occupied and e.valid and std.meta.eql(e.key, key) and std.mem.eql(u8, e.path[0..e.path_len], path);
    }
};
pub const Fingerprint = struct { file_id: core.FileId, size: u64, mtime_ns: i128, hash: core.ContentHash };

/// Component-relative nofollow opens, with NONBLOCK before the final type check.
fn open(io: Io, root: Io.Dir, path: []const u8) core.ReadError!Io.File {
    try paths.validate(path);
    var current = root;
    var owned = false;
    defer if (owned) current.close(io);
    var components = std.mem.splitScalar(u8, path, '/');
    var z: [max_path + 1]u8 = undefined;
    while (components.next()) |name| {
        @memcpy(z[0..name.len], name);
        z[name.len] = 0;
        const entry = (try paths.statAt(current.handle, z[0..name.len :0])) orelse return error.NotFound;
        if (entry.kind == .symlink) return error.PathEscape;
        if (components.peek() != null) {
            if (entry.kind != .directory) return error.NotRegular;
            const next = current.openDir(io, name, .{ .follow_symlinks = false }) catch |err| return switch (err) {
                error.SymLinkLoop, error.NotDir => error.PathEscape,
                error.FileNotFound => error.NotFound,
                error.AccessDenied, error.PermissionDenied => error.OutOfScope,
                else => error.IoFailure,
            };
            const identity = paths.statHandle(next.handle) catch |err| {
                next.close(io);
                return err;
            };
            if (identity.kind != .directory or !identity.identity.eql(entry.identity)) {
                next.close(io);
                return error.PathEscape;
            }
            if (owned) current.close(io);
            current = next;
            owned = true;
            continue;
        }
        if (entry.kind != .regular) return error.NotRegular;
        if (builtin.is_test) if (test_hooks) |h| if (h.before_open) |hook| hook(h.context);
        const fd = std.posix.openatZ(current.handle, z[0..name.len :0], .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch |err| return switch (err) {
            error.SymLinkLoop => error.PathEscape,
            error.FileNotFound, error.NotDir => error.NotFound,
            error.AccessDenied => error.OutOfScope,
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => error.ResourceExhausted,
            else => error.IoFailure,
        };
        const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(io);
        const actual = try paths.statHandle(fd);
        if (actual.kind != .regular or !actual.identity.eql(entry.identity)) return error.VersionConflict;
        return file;
    }
    return error.NotRegular;
}

pub fn verify(io: Io, root: Io.Dir, path: []const u8, max_bytes: u64, scratch: []u8, cancel: core.Cancel) core.ReadError!Fingerprint {
    try cancel.check();
    const file = try open(io, root, path);
    defer file.close(io);
    const before = file.stat(io) catch return error.IoFailure;
    const identity = try paths.statHandle(file.handle);
    if (before.kind != .file) return error.NotRegular;
    if (before.size > max_bytes) return error.ResourceExhausted;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    while (true) {
        try cancel.check();
        const amount = @min(scratch.len, max_bytes - offset + 1);
        const n = file.readPositional(io, &.{scratch[0..@intCast(amount)]}, offset) catch return error.IoFailure;
        if (n == 0) break;
        offset += n;
        if (offset > max_bytes) return error.ResourceExhausted;
        hasher.update(scratch[0..n]);
        if (builtin.is_test) if (test_hooks) |h| if (h.after_chunk) |hook| hook(h.context);
    }
    try cancel.check();
    const after = file.stat(io) catch return error.IoFailure;
    if (after.kind != .file or after.inode != before.inode or after.size != before.size or offset != before.size or
        after.mtime.nanoseconds != before.mtime.nanoseconds or after.ctime.nanoseconds != before.ctime.nanoseconds) return error.VersionConflict;
    const resolved = try paths.resolve(io, root, path);
    const current = resolved.final() orelse return error.NotFound;
    if (current.kind != .regular or !current.identity.eql(identity.identity)) return error.VersionConflict;
    return .{ .file_id = .{ .device = identity.identity.device, .inode = identity.identity.inode }, .size = offset, .mtime_ns = before.mtime.nanoseconds, .hash = hasher.finalResult() };
}
