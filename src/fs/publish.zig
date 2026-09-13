//! Descriptor-relative Linux and macOS publication primitives for T11.
//! Native platform execution and durability gates are tracked separately.
//! These checks assume the host-approved managed writer environment; they do
//! not promise compare-and-swap against a hostile same-UID external writer.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const paths = @import("zcr_policy").paths;
const Io = std.Io;
const Error = core.WriteError;
const linux = std.os.linux;
const LinuxMetadata = struct {
    extern "c" fn flistxattr(fd: c_int, list: ?[*]u8, size: usize) isize;
};
const Darwin = struct {
    // Public Darwin APIs: xnu bsd/sys/{xattr,stdio}.h and Libc sys/acl.h.
    extern "c" fn flistxattr(fd: c_int, list: ?[*]u8, size: usize, options: c_int) isize;
    extern "c" fn fgetxattr(fd: c_int, name: [*:0]const u8, value: ?[*]u8, size: usize, position: u32, options: c_int) isize;
    extern "c" fn acl_get_fd_np(fd: c_int, kind: c_int) ?*anyopaque;
    extern "c" fn acl_free(acl: *anyopaque) c_int;
    extern "c" fn renameatx_np(from_fd: c_int, from: [*:0]const u8, to_fd: c_int, to: [*:0]const u8, flags: c_uint) c_int;
};
pub const TempStage = enum { after_write_chunk, before_metadata };
pub const TempProbe = struct { context: *anyopaque, call: *const fn (*anyopaque, TempStage) void };

pub const Metadata = struct {
    identity: paths.Identity,
    size: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    nlink: u64,
    mtime_ns: i128,
    ctime_ns: i128,

    pub fn read(fd: std.posix.fd_t) Error!Metadata {
        if (builtin.os.tag == .macos) {
            // std.c selects fstat$INODE64 on Intel Darwin.
            var stat: std.c.Stat = undefined;
            if (std.c.fstat(fd, &stat) != 0) return error.IoFailure;
            if ((stat.mode & 0o170000) != 0o100000) return error.NotRegular;
            if (stat.nlink != 1 or (stat.mode & 0o7000) != 0 or stat.size < 0 or stat.flags != 0) return error.Unsupported;
            const UnsignedDev = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(stat.dev)));
            return .{
                .identity = .{ .device = @as(UnsignedDev, @bitCast(stat.dev)), .inode = @intCast(stat.ino) },
                .size = @intCast(stat.size),
                .mode = stat.mode & 0o777,
                .uid = stat.uid,
                .gid = stat.gid,
                .nlink = stat.nlink,
                .mtime_ns = @as(i128, stat.mtimespec.sec) * std.time.ns_per_s + stat.mtimespec.nsec,
                .ctime_ns = @as(i128, stat.ctimespec.sec) * std.time.ns_per_s + stat.ctimespec.nsec,
            };
        }
        if (builtin.os.tag != .linux) return error.Unsupported;
        var stat: linux.Statx = undefined;
        const result = linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat);
        if (linux.errno(result) != .SUCCESS) return error.IoFailure;
        const required: u32 = @bitCast(linux.STATX{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .GID = true, .MTIME = true, .CTIME = true, .INO = true, .SIZE = true });
        if ((@as(u32, @bitCast(stat.mask)) & required) != required) return error.Unsupported;
        if ((stat.mode & 0o170000) != 0o100000) return error.NotRegular;
        if (stat.nlink != 1 or (stat.mode & 0o7000) != 0 or @as(u64, @bitCast(stat.attributes)) != 0) return error.Unsupported;
        return .{ .identity = .{ .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor, .inode = stat.ino }, .size = stat.size, .mode = stat.mode & 0o777, .uid = stat.uid, .gid = stat.gid, .nlink = stat.nlink, .mtime_ns = @as(i128, stat.mtime.sec) * std.time.ns_per_s + stat.mtime.nsec, .ctime_ns = @as(i128, stat.ctime.sec) * std.time.ns_per_s + stat.ctime.nsec };
    }
    pub fn same(a: Metadata, b: Metadata) bool {
        return a.identity.eql(b.identity) and a.size == b.size and a.mode == b.mode and a.uid == b.uid and a.gid == b.gid and a.nlink == b.nlink and a.mtime_ns == b.mtime_ns and a.ctime_ns == b.ctime_ns;
    }
};

/// The one Darwin attribute whose name is not refused. The kernel attaches it to
/// files that processes create (observed on every new file on macOS 26.6.2), and a
/// user process can neither remove, change nor copy it: `fremovexattr`, `fsetxattr`
/// and `fcopyfile` report success and leave the value as it was. So the value can
/// be kept only when the temp file already carries the same one; `copyMetadata`
/// refuses a replacement whose value differs from the original's.
pub const darwin_system_attribute = "com.apple.provenance";

/// Provenance value of a descriptor, or null when it has none.
fn provenanceValue(fd: std.posix.fd_t, buffer: []u8) Error!?[]const u8 {
    const size = Darwin.fgetxattr(fd, darwin_system_attribute, buffer.ptr, buffer.len, 0, 0);
    if (size >= 0) return buffer[0..@intCast(size)];
    return switch (std.c.errno(size)) {
        .NOATTR => null,
        .RANGE => error.Unsupported,
        else => error.IoFailure,
    };
}

/// A replacement preserves provenance only when both files carry the same value
/// or neither carries one.
pub fn provenanceCompatible(original: ?[]const u8, replacement: ?[]const u8) bool {
    const a = original orelse return replacement == null;
    const b = replacement orelse return false;
    return std.mem.eql(u8, a, b);
}

fn noAttributes(fd: std.posix.fd_t) Error!void {
    // POSIX ACLs and security labels are xattrs on Linux. Refuse any attribute
    // rather than silently dropping metadata this baseline cannot preserve.
    switch (builtin.os.tag) {
        .linux => {
            const count = LinuxMetadata.flistxattr(fd, null, 0);
            if (count != 0) return if (count > 0) error.Unsupported else error.IoFailure;
        },
        .macos => try onlySystemAttribute(fd),
        else => return error.Unsupported,
    }
    if (builtin.os.tag == .macos) {
        // Darwin ACLs are separate metadata. Even an explicit empty ACL is
        // refused; acl_get_entry has different end semantics than Linux.
        if (Darwin.acl_get_fd_np(fd, 0x100)) |acl| { // ACL_TYPE_EXTENDED
            if (Darwin.acl_free(acl) != 0) return error.IoFailure;
            return error.Unsupported;
        }
        // Libc filesec_get_property(FILESEC_ACL) reports no ACL as ENOENT.
        if (std.c.errno(@as(c_int, -1)) != .NOENT) return error.IoFailure;
    }
}

/// Refuses every Darwin extended attribute except `darwin_system_attribute`.
fn onlySystemAttribute(fd: std.posix.fd_t) Error!void {
    const options = 0x0020; // XATTR_SHOWCOMPRESSION
    var names: [256]u8 = undefined;
    const size = Darwin.flistxattr(fd, &names, names.len, options);
    if (size == 0) return;
    // A list that does not fit holds more than the one allowed name.
    if (size < 0) return if (std.c.errno(size) == .RANGE) error.Unsupported else error.IoFailure;
    var rest = names[0..@intCast(size)];
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.IoFailure;
        if (!std.mem.eql(u8, rest[0..end], darwin_system_attribute)) return error.Unsupported;
        rest = rest[end + 1 ..];
    }
}

pub const Parent = struct {
    root: Io.Dir,
    dir: Io.Dir,
    path: []const u8,
    parent_path: []const u8,
    chain: paths.Resolved,
    leaf: [core.limits.values.path_max_utf8_bytes + 1]u8 = undefined,
    leaf_len: usize,
    after_publish_error: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},

    pub fn name(self: *const Parent) [:0]const u8 {
        return self.leaf[0..self.leaf_len :0];
    }
    pub fn open(io: Io, root: Io.Dir, path: []const u8) Error!Parent {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.Unsupported;
        try paths.validate(path);
        if (std.mem.eql(u8, path, ".")) return error.InvalidArgument;
        const parent_path = std.fs.path.dirname(path) orelse ".";
        const leaf = std.fs.path.basename(path);
        const chain = try paths.resolve(io, root, parent_path);
        if (!chain.exists() or chain.final().?.kind != .directory) return error.NotFound;
        // A readable directory descriptor is required by fsync; the default
        // non-iterable Zig directory uses O_PATH on Linux and cannot be synced.
        var dir = root.openDir(io, ".", .{ .follow_symlinks = false, .iterate = true }) catch return error.IoFailure;
        errdefer dir.close(io);
        if (!std.mem.eql(u8, parent_path, ".")) {
            var components = std.mem.splitScalar(u8, parent_path, '/');
            var index: usize = 1;
            while (components.next()) |component| : (index += 1) {
                const next = dir.openDir(io, component, .{ .follow_symlinks = false, .iterate = true }) catch return error.PathEscape;
                const entry = paths.statHandle(next.handle) catch {
                    next.close(io);
                    return error.IoFailure;
                };
                if (entry.kind != .directory or !entry.identity.eql(chain.chain[index].identity)) {
                    next.close(io);
                    return error.PathEscape;
                }
                dir.close(io);
                dir = next;
            }
        }
        const actual = try paths.statHandle(dir.handle);
        if (!actual.identity.eql(chain.final().?.identity)) return error.PathEscape;
        var self: Parent = .{ .root = root, .dir = dir, .path = path, .parent_path = parent_path, .chain = chain, .leaf_len = leaf.len };
        @memcpy(self.leaf[0..leaf.len], leaf);
        self.leaf[leaf.len] = 0;
        return self;
    }
    pub fn close(self: *Parent, io: Io) void {
        self.dir.close(io);
    }
    pub fn revalidate(self: *Parent, io: Io) Error!void {
        const now = paths.resolve(io, self.root, self.parent_path) catch return error.PathEscape;
        if (!now.exists() or now.len != self.chain.len) return error.PathEscape;
        for (now.entries(), self.chain.entries()) |a, b| if (a.kind != .directory or !a.identity.eql(b.identity)) return error.PathEscape;
        if (!(try paths.statHandle(self.dir.handle)).identity.eql(now.final().?.identity)) return error.PathEscape;
    }
    pub fn openOriginal(self: *Parent, io: Io) Error!Original {
        const expected = try paths.statAt(self.dir.handle, self.name()) orelse return error.NotFound;
        if (expected.kind == .symlink) return error.PathEscape;
        if (expected.kind != .regular) return error.NotRegular;
        const fd = std.posix.openatZ(self.dir.handle, self.name(), .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch |err| return mapOpen(err);
        const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(io);
        const metadata = try Metadata.read(fd);
        if (!metadata.identity.eql(expected.identity)) return error.VersionConflict;
        try noAttributes(fd);
        return .{ .file = file, .metadata = metadata };
    }
    pub fn createTemp(self: *Parent, io: Io) Error!Temp {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            var random: [16]u8 = undefined;
            io.randomSecure(&random) catch return error.IoFailure;
            var temp_name: [41:0]u8 = undefined;
            @memcpy(temp_name[0..9], ".zcr-tmp-");
            @memcpy(temp_name[9..41], &std.fmt.bytesToHex(random, .lower));
            temp_name[41] = 0;
            const fd = std.posix.openatZ(self.dir.handle, &temp_name, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return mapOpen(err),
            };
            const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
            const metadata = Metadata.read(fd) catch |err| {
                defer file.close(io);
                const handle_entry = paths.statHandle(fd) catch return error.RecoveryRequired;
                const named = paths.statAt(self.dir.handle, &temp_name) catch return error.RecoveryRequired;
                if (named == null or !named.?.identity.eql(handle_entry.identity)) return error.RecoveryRequired;
                if (std.c.unlinkat(self.dir.handle, &temp_name, 0) != 0) return error.RecoveryRequired;
                return err;
            };
            return .{ .file = file, .name = temp_name, .identity = metadata.identity };
        }
        return error.Busy;
    }
    pub fn publishReplace(self: *Parent, temp: *Temp) Error!void {
        try temp.checkIdentity(self);
        const rc = std.c.renameat(self.dir.handle, &temp.name, self.dir.handle, self.name());
        if (rc != 0) return self.failedPublish(temp, std.c.errno(rc));
        if (builtin.is_test) if (self.after_publish_error) return self.failedPublish(temp, .IO);
        temp.published = true;
    }
    pub fn publishCreate(self: *Parent, temp: *Temp) Error!void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.Unsupported;
        try temp.checkIdentity(self);
        const errno = if (builtin.os.tag == .macos) blk: {
            // RENAME_EXCL: same-directory atomic publication without overwrite.
            const rc = Darwin.renameatx_np(self.dir.handle, &temp.name, self.dir.handle, self.name(), 0x00000004);
            break :blk std.c.errno(rc);
        } else linux.errno(linux.renameat2(self.dir.handle, &temp.name, self.dir.handle, self.name(), .{ .NOREPLACE = true }));
        if (errno != .SUCCESS) return self.failedPublish(temp, errno);
        if (builtin.is_test) if (self.after_publish_error) return self.failedPublish(temp, .IO);
        temp.published = true;
    }
    fn failedPublish(self: *Parent, temp: *Temp, errno: std.posix.E) Error!void {
        // A syscall error must not hide an already visible new file. Reconcile
        // descriptor identities before returning an ordinary precommit error.
        if (try paths.statAt(self.dir.handle, self.name())) |entry| if (entry.identity.eql(temp.identity)) {
            temp.published = true;
            return;
        };
        temp.checkIdentity(self) catch return error.RecoveryRequired;
        return switch (errno) {
            .EXIST => error.VersionConflict,
            .NOSYS, .OPNOTSUPP, .INVAL => error.Unsupported,
            .ACCES, .PERM => error.OutOfScope,
            else => error.IoFailure,
        };
    }
    pub fn sync(self: *Parent) Error!void {
        while (true) {
            const rc = std.c.fsync(self.dir.handle);
            if (rc == 0) return;
            switch (std.c.errno(rc)) {
                .INTR => continue,
                .INVAL, .OPNOTSUPP => return error.Unsupported,
                else => return error.DurabilityFailed,
            }
        }
    }
};

pub const Original = struct {
    file: Io.File,
    metadata: Metadata,
    pub fn readAll(self: *Original, io: Io, bytes: []u8, cancel: core.Cancel) Error!void {
        if (bytes.len != self.metadata.size) return error.InvalidArgument;
        var offset: usize = 0;
        while (offset < bytes.len) {
            try cancel.check();
            const end = @min(bytes.len, offset + core.limits.values.chunk_bytes);
            const n = self.file.readPositional(io, &.{bytes[offset..end]}, offset) catch return error.IoFailure;
            if (n == 0) return error.VersionConflict;
            offset += n;
        }
        var extra: [1]u8 = undefined;
        if ((self.file.readPositional(io, &.{&extra}, bytes.len) catch return error.IoFailure) != 0) return error.VersionConflict;
        if (!self.metadata.same(try Metadata.read(self.file.handle))) return error.VersionConflict;
    }
    pub fn checkUnchanged(self: *Original, io: Io, parent: *Parent, scratch: []u8, expected: core.ContentHash, cancel: core.Cancel) Error!void {
        // A mediated replace unlinks the retained old descriptor. Recognize the
        // changed directory entry before interpreting its now-zero link count.
        const named = try paths.statAt(parent.dir.handle, parent.name()) orelse return error.VersionConflict;
        if (named.kind != .regular or !named.identity.eql(self.metadata.identity)) return error.VersionConflict;
        if (!self.metadata.same(try Metadata.read(self.file.handle))) return error.VersionConflict;
        try self.readAll(io, scratch, cancel);
        var actual: core.ContentHash = undefined;
        std.crypto.hash.sha2.Sha256.hash(scratch, &actual, .{});
        if (!std.mem.eql(u8, &actual, &expected)) return error.VersionConflict;
        const current = try paths.statAt(parent.dir.handle, parent.name()) orelse return error.VersionConflict;
        if (current.kind != .regular or !current.identity.eql(self.metadata.identity)) return error.VersionConflict;
    }
};

pub const Temp = struct {
    file: Io.File,
    name: [41:0]u8,
    identity: paths.Identity,
    published: bool = false,
    probe: if (builtin.is_test) ?TempProbe else void = if (builtin.is_test) null else {},
    fn observe(self: *Temp, stage: TempStage) void {
        if (builtin.is_test) if (self.probe) |probe| probe.call(probe.context, stage);
    }
    pub fn checkIdentity(self: *Temp, parent: *Parent) Error!void {
        const entry = try paths.statAt(parent.dir.handle, &self.name) orelse return error.RecoveryRequired;
        if (entry.kind != .regular or !entry.identity.eql(self.identity)) return error.RecoveryRequired;
        const metadata = try Metadata.read(self.file.handle);
        if (!metadata.identity.eql(self.identity)) return error.RecoveryRequired;
    }
    pub fn cleanupName(self: *Temp, parent: *Parent) Error!void {
        if (self.published) return;
        try self.checkIdentity(parent);
        const rc = std.c.unlinkat(parent.dir.handle, &self.name, 0);
        if (rc != 0) return error.IoFailure;
    }
    pub fn writeAll(self: *Temp, io: Io, bytes: []const u8, cancel: core.Cancel) Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try cancel.check();
            const end = @min(bytes.len, offset + core.limits.values.chunk_bytes);
            const n = self.file.writePositional(io, &.{bytes[offset..end]}, offset) catch return error.IoFailure;
            if (n == 0) return error.IoFailure;
            offset += n;
            self.observe(.after_write_chunk);
        }
    }
    pub fn copyMetadata(self: *Temp, original: ?*Original) Error!void {
        const mode: u32 = if (original) |old| old.metadata.mode else 0o600;
        if (original) |old| {
            try noAttributes(old.file.handle);
            const current = try Metadata.read(self.file.handle);
            if (current.uid != old.metadata.uid or current.gid != old.metadata.gid) return error.Unsupported;
        }
        try noAttributes(self.file.handle);
        if (builtin.os.tag == .macos) if (original) |old| {
            var old_value: [64]u8 = undefined;
            var new_value: [64]u8 = undefined;
            // The kernel gives the temp its own provenance and ignores attempts to set
            // another, so a differing value cannot be preserved: refuse before commit.
            const kept = provenanceCompatible(try provenanceValue(old.file.handle, &old_value), try provenanceValue(self.file.handle, &new_value));
            if (!kept) return error.Unsupported;
        };
        self.observe(.before_metadata);
        if (std.c.fchmod(self.file.handle, @intCast(mode)) != 0) return error.IoFailure;
    }
    pub fn sync(self: *Temp, io: Io) Error!void {
        self.file.sync(io) catch return error.DurabilityFailed;
    }
};

fn mapOpen(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.SymLinkLoop => error.PathEscape,
        error.IsDir => error.NotRegular,
        error.AccessDenied, error.PermissionDenied => error.OutOfScope,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => error.ResourceExhausted,
        else => error.IoFailure,
    };
}
