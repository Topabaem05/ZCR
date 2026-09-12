//! Trusted ignore handles. Atomic replacement requires an explicit session rebind;
//! stale handles must never silently keep using superseded ignore policy.
const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const metadata = @import("zcr_fs_read").metadata;
const Io = std.Io;
const max_bytes = 1024 * 1024;

pub const BoundFile = struct {
    root: Io.Dir,
    path: []const u8,
    file: ?Io.File,
    identity: ?policy.paths.Identity,

    /// Root and path are borrowed; the opened file is owned by this binding.
    pub fn init(io: Io, root: Io.Dir, path: []const u8) !BoundFile {
        const opened = metadata.openRegular(io, root, path) catch |err| {
            if (err == error.NotFound) return .{ .root = root, .path = path, .file = null, .identity = null };
            return err;
        };
        errdefer opened.file.close(io);
        if (opened.before.size > max_bytes) return error.ResourceExhausted;
        var binding: BoundFile = .{ .root = root, .path = path, .file = opened.file, .identity = opened.before.identity };
        try binding.validate(io);
        return binding;
    }

    pub fn deinit(self: *BoundFile, io: Io) void {
        if (self.file) |file| file.close(io);
        self.file = null;
    }

    pub fn validate(self: *const BoundFile, io: Io) core.AuthorizeError!void {
        const current = metadata.pathIdentity(io, self.root, self.path) catch return error.OutOfScope;
        if (self.identity) |expected| {
            if (current == null or !expected.eql(current.?)) return error.OutOfScope;
            const held = policy.paths.statHandle((self.file orelse return error.OutOfScope).handle) catch return error.OutOfScope;
            if (held.kind != .regular or !expected.eql(held.identity)) return error.OutOfScope;
        } else if (current != null) return error.OutOfScope;
    }
};

pub const AbsoluteFile = struct {
    binding: BoundFile,
    parent: Io.Dir,
    parent_path: []const u8,
    parent_id: policy.paths.Identity,

    pub fn init(io: Io, path: []const u8) !AbsoluteFile {
        if (path.len > 4096 or !std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return error.InvalidArgument;
        const parent_path = std.fs.path.dirname(path) orelse return error.InvalidArgument;
        const name = std.fs.path.basename(path);
        try policy.paths.validate(name);
        const parent = try Io.Dir.openDirAbsolute(io, parent_path, .{ .follow_symlinks = false });
        errdefer parent.close(io);
        const entry = try policy.paths.statHandle(parent.handle);
        var binding = try BoundFile.init(io, parent, name);
        errdefer binding.deinit(io);
        var result: AbsoluteFile = .{ .binding = binding, .parent = parent, .parent_path = parent_path, .parent_id = entry.identity };
        try result.validate(io);
        return result;
    }

    pub fn deinit(self: *AbsoluteFile, io: Io) void {
        self.binding.deinit(io);
        self.parent.close(io);
    }

    pub fn validate(self: *const AbsoluteFile, io: Io) core.AuthorizeError!void {
        const current = Io.Dir.openDirAbsolute(io, self.parent_path, .{ .follow_symlinks = false }) catch return error.OutOfScope;
        defer current.close(io);
        const entry = policy.paths.statHandle(current.handle) catch return error.OutOfScope;
        if (entry.kind != .directory or !entry.identity.eql(self.parent_id)) return error.OutOfScope;
        var buf: [4096]u8 = undefined;
        const len = current.realPath(io, &buf) catch return error.OutOfScope;
        if (!std.mem.eql(u8, self.parent_path, buf[0..len])) return error.OutOfScope;
        try self.binding.validate(io);
    }
};
