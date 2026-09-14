//! Trusted, bounded Git discovery. All subprocesses use explicit argv and an
//! isolated environment; discovery never changes cwd or writes Git metadata.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const paths = @import("zcr_policy").paths;
const Io = std.Io;
const A = std.mem.Allocator;

pub const max_git_output = 1024 * 1024;
pub const MarkerTestHook = struct {
    context: ?*anyopaque = null,
    before_open: ?*const fn (?*anyopaque) void = null,
    after_read: ?*const fn (?*anyopaque) void = null,
};
/// Deterministic race injection; ignored in every non-test build.
pub var marker_test_hook: if (builtin.is_test) ?MarkerTestHook else void = if (builtin.is_test) null else {};

pub const Identity = struct {
    arena: std.heap.ArenaAllocator,
    root: core.TrustedRoot,
    git_dir: Io.Dir,
    common_dir: Io.Dir,
    git: core.GitMetadata,
    root_id: core.FileId,
    git_dir_id: core.FileId,
    common_dir_id: core.FileId,
    marker: Marker,
    head: [64]u8 = @splat(0),
    head_len: u8 = 0,

    pub fn deinit(self: *Identity, io: Io) void {
        self.root.dir.close(io);
        self.git_dir.close(io);
        self.common_dir.close(io);
        self.arena.deinit();
    }

    /// Check retained handles against canonical paths again before authority use.
    /// The host must still enforce the dedicated-worktree condition against
    /// hostile same-UID mutation between this check and a handle-relative commit.
    pub fn validate(self: *const Identity, io: Io) core.RegisterError!void {
        try validatePath(io, self.root.canonical_path, self.root.dir, self.root_id);
        if (!std.meta.eql(self.marker, try markerAt(io, self.root.dir))) return error.PathEscape;
        try validatePath(io, self.git.git_dir.?, self.git_dir, self.git_dir_id);
        try validatePath(io, self.git.common_dir.?, self.common_dir, self.common_dir_id);
    }

    pub fn same(self: *const Identity, other: *const Identity) bool {
        return std.meta.eql(self.marker, other.marker) and eql(self.root_id, other.root_id) and eql(self.git_dir_id, other.git_dir_id) and
            eql(self.common_dir_id, other.common_dir_id) and std.mem.eql(u8, self.root.canonical_path, other.root.canonical_path);
    }
};

pub fn eql(a: core.FileId, b: core.FileId) bool {
    return a.device == b.device and a.inode == b.inode;
}
fn fileId(dir: Io.Dir) core.RegisterError!core.FileId {
    const entry = try paths.statHandle(dir.handle);
    if (entry.kind != .directory) return error.NotRegular;
    return .{ .device = entry.identity.device, .inode = entry.identity.inode };
}
fn checkAbsolute(path: []const u8) core.RegisterError!void {
    if (path.len == 0 or path.len > 4096 or !std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path) or
        std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return error.InvalidArgument;
}
fn open(io: Io, path: []const u8) core.RegisterError!Io.Dir {
    return Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.OutOfScope,
        error.SymLinkLoop => error.PathEscape,
        else => error.IoFailure,
    };
}
fn validatePath(io: Io, path: []const u8, retained: Io.Dir, expected: core.FileId) core.RegisterError!void {
    if (!eql(try fileId(retained), expected)) return error.PathEscape;
    const current = try open(io, path);
    defer current.close(io);
    if (!eql(try fileId(current), expected)) return error.PathEscape;
    var buf: [4096]u8 = undefined;
    const len = current.realPath(io, &buf) catch return error.IoFailure;
    if (!std.mem.eql(u8, path, buf[0..len])) return error.PathEscape;
}
fn output(a: A, io: Io, exe: []const u8, root: []const u8, args: []const []const u8, timeout_ms: u32) core.RegisterError![]const u8 {
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_OPTIONAL_LOCKS", "0");
    try env.put("LC_ALL", "C");
    var argv: [12][]const u8 = undefined;
    argv[0] = exe;
    argv[1] = "-C";
    argv[2] = root;
    if (args.len > argv.len - 3) return error.InvalidArgument;
    @memcpy(argv[3..][0..args.len], args);
    const r = std.process.run(a, io, .{
        .argv = argv[0 .. args.len + 3],
        .environ_map = &env,
        .stdout_limit = .limited(max_git_output),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.ResourceExhausted,
        // Identity was not established and nothing was written; the caller may retry.
        error.Timeout => error.Busy,
        else => error.IoFailure,
    };
    switch (r.term) {
        .exited => |code| if (code == 0) return r.stdout,
        else => {},
    }
    return error.IoFailure;
}
fn line(bytes: []const u8) core.RegisterError![]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.IoFailure;
    const value = bytes[0 .. bytes.len - 1];
    try checkAbsolute(value);
    return value;
}

pub const DiscoverOptions = struct {
    /// Budget for each Git subprocess; expiry is reported as retryable Busy.
    timeout_ms: u32 = default_git_timeout_ms,
};
pub const default_git_timeout_ms: u32 = 5000;
pub const max_git_timeout_ms: u32 = 60_000;

pub fn discover(a: A, io: Io, exe: []const u8, trusted: core.TrustedRoot) core.RegisterError!Identity {
    return discoverWith(a, io, exe, trusted, .{});
}

pub fn discoverWith(a: A, io: Io, exe: []const u8, trusted: core.TrustedRoot, options: DiscoverOptions) core.RegisterError!Identity {
    if (options.timeout_ms == 0 or options.timeout_ms > max_git_timeout_ms) return error.InvalidArgument;
    try checkAbsolute(exe);
    try checkAbsolute(trusted.canonical_path);
    const root_id = try fileId(trusted.dir);
    const marker = try markerAt(io, trusted.dir);
    try validatePath(io, trusted.canonical_path, trusted.dir, root_id);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const top = try line(try output(temp, io, exe, trusted.canonical_path, &.{ "rev-parse", "--path-format=absolute", "--show-toplevel" }, options.timeout_ms));
    if (!std.mem.eql(u8, top, trusted.canonical_path)) return error.OutOfScope;
    const git_path = try line(try output(temp, io, exe, top, &.{ "rev-parse", "--absolute-git-dir" }, options.timeout_ms));
    const common_path = try line(try output(temp, io, exe, top, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }, options.timeout_ms));
    const listing = try output(temp, io, exe, top, &.{ "worktree", "list", "--porcelain", "-z" }, options.timeout_ms);
    var head: [64]u8 = @splat(0);
    var head_len: u8 = 0;
    var fields = std.mem.splitScalar(u8, listing, 0);
    var in_root = false;
    var found_root = false;
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "worktree ")) {
            in_root = std.mem.eql(u8, field[9..], top);
            found_root = found_root or in_root;
        } else if (in_root and std.mem.startsWith(u8, field, "HEAD ")) {
            const value = field[5..];
            if (value.len != 40 and value.len != 64) return error.IoFailure;
            for (value) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.IoFailure;
            @memcpy(head[0..value.len], value);
            head_len = @intCast(value.len);
        }
    }
    if (!found_root) return error.OutOfScope;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const root_dir = trusted.dir.openDir(io, ".", .{ .follow_symlinks = false }) catch return error.IoFailure;
    errdefer root_dir.close(io);
    const git_dir = try open(io, git_path);
    errdefer git_dir.close(io);
    const common_dir = try open(io, common_path);
    errdefer common_dir.close(io);
    var result: Identity = .{
        .arena = arena,
        .root = .{ .dir = root_dir, .canonical_path = try owned.dupe(u8, top) },
        .git_dir = git_dir,
        .common_dir = common_dir,
        .git = .{ .git_dir = try owned.dupe(u8, git_path), .common_dir = try owned.dupe(u8, common_path) },
        .root_id = root_id,
        .git_dir_id = try fileId(git_dir),
        .common_dir_id = try fileId(common_dir),
        .head = head,
        .head_len = head_len,
        .marker = marker,
    };
    // Copy the allocator's final state after its last allocation.
    result.arena = arena;
    try result.validate(io);
    return result;
}

const Marker = struct { id: core.FileId, hash: ?core.Sha256 };

/// A regular marker can be replaced by a FIFO after lstat. NONBLOCK must be
/// present on the open itself; checking the opened kind comes too late to stop
/// a blocking FIFO open. NOFOLLOW and CLOEXEC preserve the descriptor boundary.
fn openMarker(root: Io.Dir) core.RegisterError!Io.File {
    if (comptime builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.Unsupported;
    const fd = std.posix.openatZ(root.handle, ".git", .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir, error.SymLinkLoop, error.NoDevice => error.PathEscape,
        error.AccessDenied, error.PermissionDenied => error.OutOfScope,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => error.ResourceExhausted,
        else => error.IoFailure,
    };
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}

fn markerAt(io: Io, root: Io.Dir) core.RegisterError!Marker {
    const entry = (try paths.statAt(root.handle, ".git")) orelse return error.NotFound;
    const id: core.FileId = .{ .device = entry.identity.device, .inode = entry.identity.inode };
    if (entry.kind == .directory) return .{ .id = id, .hash = null };
    if (entry.kind != .regular) return error.PathEscape;
    if (builtin.is_test) if (marker_test_hook) |hook| if (hook.before_open) |run| run(hook.context);
    const file = try openMarker(root);
    defer file.close(io);
    const opened = try paths.statHandle(file.handle);
    if (!opened.identity.eql(entry.identity) or opened.kind != .regular) return error.PathEscape;
    const before = file.stat(io) catch return error.IoFailure;
    if (before.kind != .file or before.inode != opened.identity.inode) return error.PathEscape;
    if (before.size > 4096) return error.ResourceExhausted;
    var bytes: [4097]u8 = undefined;
    const len = file.readPositionalAll(io, &bytes, 0) catch return error.IoFailure;
    if (len == bytes.len) return error.ResourceExhausted;
    if (builtin.is_test) if (marker_test_hook) |hook| if (hook.after_read) |run| run(hook.context);
    const after = file.stat(io) catch return error.IoFailure;
    if (after.kind != .file or after.inode != before.inode or after.size != before.size or
        after.mtime.nanoseconds != before.mtime.nanoseconds or after.ctime.nanoseconds != before.ctime.nanoseconds or
        @as(u64, len) != before.size) return error.PathEscape;
    const current = (try paths.statAt(root.handle, ".git")) orelse return error.PathEscape;
    if (current.kind != .regular or !current.identity.eql(opened.identity)) return error.PathEscape;
    var digest: core.Sha256 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..len], &digest, .{});
    return .{ .id = id, .hash = digest };
}
