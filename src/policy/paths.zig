//! Root-handle path checks (T02, I01; docs/11 §2).
//!
//! A path is first validated syntactically, then walked from the trusted root
//! handle one component at a time without following symlinks. The walk
//! returns the (device, inode) identity of the root and of every existing
//! component so callers compare protected entries by identity, never by
//! spelling or string prefix.
//!
//! The walk narrows time-of-check races but cannot remove them: a same-UID
//! process may swap a component after the walk. Operations must reopen
//! handle-relative with no-follow and re-check the type (T04, T11), and a
//! hostile same-UID writer needs host isolation, which ZCR does not provide.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const Io = std.Io;
const posix = std.posix;

pub const max_depth = core.limits.values.directory_max_depth;
const max_path_bytes = core.limits.values.path_max_utf8_bytes;

pub const Kind = enum { directory, regular, symlink, other };

pub const Identity = struct {
    device: u64,
    inode: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.device == b.device and a.inode == b.inode;
    }
};

pub const Entry = struct { identity: Identity, kind: Kind };

pub const SyntaxError = error{ InvalidArgument, PathEscape };
pub const StatError = error{ NotFound, OutOfScope, PathEscape, IoFailure };
pub const ResolveError = SyntaxError || StatError;

/// Portable syntax rules on top of `core.RelativePath.init`. `"."` names the root.
/// Escapes (absolute, `..`, UNC or drive prefixes, backslash separators) are
/// `PathEscape`; malformed input (empty, NUL, invalid UTF-8, empty or `.`
/// components, too long or too deep) is `InvalidArgument`.
pub fn validate(bytes: []const u8) SyntaxError!void {
    if (bytes.len == 0 or bytes.len > max_path_bytes) return error.InvalidArgument;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidArgument;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidArgument;
    if (std.mem.eql(u8, bytes, ".")) return;
    if (bytes[0] == '/' or std.mem.indexOfScalar(u8, bytes, '\\') != null) return error.PathEscape;
    if (bytes.len >= 2 and bytes[1] == ':' and std.ascii.isAlphabetic(bytes[0])) return error.PathEscape;

    var components = std.mem.splitScalar(u8, bytes, '/');
    var depth: usize = 0;
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.PathEscape;
        if (component.len == 0 or std.mem.eql(u8, component, ".")) return error.InvalidArgument;
        depth += 1;
        if (depth > max_depth) return error.InvalidArgument;
    }
}

pub const Resolved = struct {
    /// Root first, then each existing component in path order.
    chain: [max_depth + 1]Entry = undefined,
    len: usize = 0,
    /// Number of components in the path (0 for the root itself).
    components: usize = 0,

    pub fn entries(r: *const Resolved) []const Entry {
        return r.chain[0..r.len];
    }

    /// Every component, including the final one, exists.
    pub fn exists(r: *const Resolved) bool {
        return r.len == r.components + 1;
    }

    /// Every component except the final one exists.
    pub fn parentExists(r: *const Resolved) bool {
        return r.len >= r.components;
    }

    pub fn final(r: *const Resolved) ?Entry {
        return if (r.exists()) r.chain[r.len - 1] else null;
    }
};

/// Walks `path` under `root` without following symlinks. Missing components
/// stop the walk (see `exists` and `parentExists`); a symlink anywhere is
/// `PathEscape`; a non-directory used as a directory is `NotFound`.
pub fn resolve(io: Io, root: Io.Dir, path: []const u8) ResolveError!Resolved {
    try validate(path);
    var r: Resolved = .{};
    r.chain[0] = try statHandle(root.handle);
    r.len = 1;
    if (std.mem.eql(u8, path, ".")) return r;
    r.components = std.mem.count(u8, path, "/") + 1;

    var name_buf: [max_path_bytes + 1]u8 = undefined;
    var current = root;
    var owns_current = false;
    defer if (owns_current) current.close(io);

    var components = std.mem.splitScalar(u8, path, '/');
    var index: usize = 0;
    while (components.next()) |component| : (index += 1) {
        @memcpy(name_buf[0..component.len], component);
        name_buf[component.len] = 0;
        const entry = try statAt(current.handle, name_buf[0..component.len :0]) orelse return r;
        r.chain[r.len] = entry;
        r.len += 1;
        if (entry.kind == .symlink) return error.PathEscape;
        if (index + 1 == r.components) return r;
        if (entry.kind != .directory) return error.NotFound;

        const next = current.openDir(io, component, .{ .follow_symlinks = false }) catch |err| return switch (err) {
            // The entry changed between stat and open.
            error.SymLinkLoop, error.NotDir => error.PathEscape,
            error.FileNotFound => error.NotFound,
            error.AccessDenied, error.PermissionDenied => error.OutOfScope,
            else => error.IoFailure,
        };
        const opened = statHandle(next.handle) catch |err| {
            next.close(io);
            return err;
        };
        if (!opened.identity.eql(entry.identity)) {
            next.close(io);
            return error.PathEscape;
        }
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
    }
    return r;
}

/// lstat of `name` relative to `dir_fd`; null when it does not exist.
pub fn statAt(dir_fd: posix.fd_t, name: [:0]const u8) StatError!?Entry {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(dir_fd, name.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .INO = true }, &stx);
            return switch (linux.errno(rc)) {
                .SUCCESS => entryFromStatx(stx),
                .NOENT => null,
                .NOTDIR => error.NotFound,
                .ACCES, .PERM => error.OutOfScope,
                .LOOP => error.PathEscape,
                else => error.IoFailure,
            };
        },
        else => {
            var st: std.c.Stat = undefined;
            const rc = std.c.fstatat(dir_fd, name.ptr, &st, std.c.AT.SYMLINK_NOFOLLOW);
            if (rc == 0) return entryFromStat(st);
            return switch (std.c.errno(rc)) {
                .NOENT => null,
                .NOTDIR => error.NotFound,
                .ACCES, .PERM => error.OutOfScope,
                .LOOP => error.PathEscape,
                else => error.IoFailure,
            };
        },
    }
}

/// fstat of an open handle.
pub fn statHandle(fd: posix.fd_t) StatError!Entry {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .INO = true }, &stx);
            return switch (linux.errno(rc)) {
                .SUCCESS => entryFromStatx(stx),
                .ACCES, .PERM => error.OutOfScope,
                else => error.IoFailure,
            };
        },
        else => {
            var st: std.c.Stat = undefined;
            if (std.c.fstat(fd, &st) != 0) return error.IoFailure;
            return entryFromStat(st);
        },
    }
}

fn kindFromMode(mode: u32) Kind {
    return switch (mode & 0o170000) {
        0o040000 => .directory,
        0o100000 => .regular,
        0o120000 => .symlink,
        else => .other,
    };
}

fn entryFromStat(st: std.c.Stat) Entry {
    const Dev = @TypeOf(st.dev);
    const UnsignedDev = std.meta.Int(.unsigned, @bitSizeOf(Dev));
    return .{
        .identity = .{ .device = @as(UnsignedDev, @bitCast(st.dev)), .inode = @intCast(st.ino) },
        .kind = kindFromMode(@intCast(st.mode)),
    };
}

fn entryFromStatx(stx: std.os.linux.Statx) Entry {
    return .{
        .identity = .{ .device = (@as(u64, stx.dev_major) << 32) | stx.dev_minor, .inode = stx.ino },
        .kind = kindFromMode(stx.mode),
    };
}
