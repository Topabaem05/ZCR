//! Trusted launch grants, current-user credentials, and private UDS endpoints.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
pub const Token = [32]u8;
pub const Error = error{ OutOfScope, IoFailure, InvalidArgument, Unsupported };
pub fn generate(io: std.Io) Error!Token {
    var token: Token = undefined;
    io.randomSecure(&token) catch return error.IoFailure;
    return token;
}
pub fn verify(expected: Token, supplied: Token, domain: core.SecurityDomain, claimed: core.SecurityDomain, uid: u32, peer_uid: u32) Error!void {
    const equal = std.crypto.timing_safe.eql(Token, expected, supplied);
    if (!equal or uid != peer_uid or domain.id != claimed.id or domain.id == 0 or std.mem.allEqual(u8, &expected, 0)) return error.OutOfScope;
}
/// The accepted session policy is already the intersection. A broader grant is
/// refused instead of changing its manifest digest or inventing new authority.
pub fn withinCeiling(grant: core.Policy, host: core.Policy) Error!void {
    if (grant.state != .active or host.state != .active or grant.max_changed_files > host.max_changed_files) return error.OutOfScope;
    for (grant.operations) |op| if (!policy.scope.allowsOperation(&host, op)) return error.OutOfScope;
    for (grant.read_paths) |path| if (!policy.scope.coveredByAny(host.read_paths, path.bytes)) return error.OutOfScope;
    for (grant.write_paths) |path| if (!policy.scope.coveredByAny(host.write_paths, path.bytes)) return error.OutOfScope;
    for (host.immutable_paths) |path| if (!policy.scope.coveredByAny(grant.immutable_paths, path.bytes)) return error.OutOfScope;
}
extern "c" fn getpeereid(std.c.fd_t, *std.c.uid_t, *std.c.gid_t) c_int;
pub fn peerUid(fd: std.c.fd_t) Error!u32 {
    switch (builtin.os.tag) {
        .linux => {
            var cred: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
            var len: std.c.socklen_t = @sizeOf(@TypeOf(cred));
            if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.PEERCRED, &cred, &len) != 0 or len != @sizeOf(@TypeOf(cred))) return error.IoFailure;
            return cred.uid;
        },
        .macos => {
            var uid: std.c.uid_t = undefined;
            var gid: std.c.gid_t = undefined;
            if (getpeereid(fd, &uid, &gid) != 0) return error.IoFailure;
            return uid;
        },
        else => return error.Unsupported,
    }
}
pub fn address(path: []const u8) Error!std.c.sockaddr.un {
    var out: std.c.sockaddr.un = .{ .path = @splat(0) };
    if (!std.fs.path.isAbsolute(path) or path.len == 0 or path.len >= out.path.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArgument;
    @memcpy(out.path[0..path.len], path);
    return out;
}
pub fn configureSocket(fd: std.c.fd_t) Error!void {
    const old = std.c.fcntl(fd, std.c.F.GETFL);
    if (old < 0 or std.c.fcntl(fd, std.c.F.SETFL, old | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) < 0 or std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.IoFailure;
    const bytes: c_int = 4096;
    if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDBUF, &bytes, @sizeOf(c_int)) != 0 or std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVBUF, &bytes, @sizeOf(c_int)) != 0) return error.IoFailure;
    if (builtin.os.tag == .macos) {
        const yes: c_int = 1;
        if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &yes, @sizeOf(c_int)) != 0) return error.IoFailure;
    }
}
pub fn send(fd: std.c.fd_t, bytes: []const u8) isize {
    return std.c.send(fd, bytes.ptr, bytes.len, if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0);
}
pub fn wouldBlock(rc: isize) bool {
    return std.posix.errno(rc) == .AGAIN or std.posix.errno(rc) == .INTR;
}
/// Pin and verify the canonical private parent; never chmod or remove an
/// existing endpoint. The trusted launcher owns parent creation and lifetime.
pub fn privateParent(a: std.mem.Allocator, io: std.Io, path: []const u8) !std.Io.Dir {
    _ = try address(path);
    const dirname = std.fs.path.dirname(path) orelse return error.InvalidArgument;
    const parent = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    errdefer parent.close(io);
    const actual = try parent.realPathFileAlloc(io, ".", a);
    defer a.free(actual);
    if (!std.mem.eql(u8, actual, dirname)) return error.OutOfScope;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var st: linux.Statx = undefined;
        const rc = linux.statx(parent.handle, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true }, &st);
        if (linux.errno(rc) != .SUCCESS or !st.mask.UID or !st.mask.MODE or !st.mask.TYPE) return error.IoFailure;
        if (st.uid != std.c.geteuid() or st.mode & 0o077 != 0 or st.mode & 0o170000 != 0o040000) return error.OutOfScope;
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(parent.handle, &st) != 0) return error.IoFailure;
        if (st.uid != std.c.geteuid() or st.mode & 0o077 != 0 or st.mode & 0o170000 != 0o040000) return error.OutOfScope;
    }
    return parent;
}

pub fn entryAt(fd: std.c.fd_t, name: []const u8) policy.paths.StatError!?policy.paths.Entry {
    if (name.len > 107) return error.OutOfScope;
    var buf: [108:0]u8 = @splat(0);
    @memcpy(buf[0..name.len], name);
    return policy.paths.statAt(fd, buf[0..name.len :0]);
}
