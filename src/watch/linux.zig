//! Bounded, explicitly polled Linux inotify source. No thread or heap allocation.
//! /proc/self/fd binds watches to already validated no-follow directory handles.
const std = @import("std");
const core = @import("zcr_core");
const paths = @import("zcr_policy").paths;
const os = std.os.linux;
const Io = std.Io;
pub const supported = @import("builtin").os.tag == .linux;
pub const max_watches = 128;
pub const path_max = core.limits.values.path_max_utf8_bytes;
pub const EventSink = struct { context: *anyopaque, push: *const fn (*anyopaque, core.WatchEvent) void };
const Watch = struct { wd: i32 = -1, path: [path_max]u8 = undefined, len: usize = 0, identity: core.FileId = undefined };
pub const Backend = struct {
    fd: ?i32 = null,
    sink: EventSink = undefined,
    watches: [max_watches]Watch = @splat(.{}),
    used: usize = 0,
    limit: usize = max_watches,
    cursor: u64 = 0,
    covered: bool = false,
    drained: bool = false,
    buffer: [16 * core.limits.KiB]u8 align(@alignOf(os.inotify_event)) = undefined,
    test_force_unknown: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},
    pub fn start(b: *Backend, io: Io, root: core.TrustedRoot, sink: EventSink, limit: usize) core.ReadError!void {
        if (b.fd != null) return error.Busy;
        if (limit == 0 or limit > max_watches) return error.InvalidArgument;
        const rc = os.inotify_init1(os.IN.NONBLOCK | os.IN.CLOEXEC);
        switch (os.errno(rc)) {
            .SUCCESS => {},
            .MFILE, .NFILE, .NOMEM => return error.ResourceExhausted,
            else => return error.IoFailure,
        }
        b.* = .{ .fd = @intCast(rc), .sink = sink, .limit = limit };
        errdefer b.stop(io);
        try b.add(root.dir, "."); // Before scanning any child directory.
    }
    fn emit(b: *Backend, kind: core.WatchEventKind, path: ?[]const u8) void {
        switch (kind) {
            .overflow, .dropped, .root_changed, .cursor_wrapped => {
                b.covered = false;
                b.drained = false;
            },
            else => {},
        }
        if (b.cursor == std.math.maxInt(u64)) {
            b.cursor = 0;
            b.sink.push(b.sink.context, .{ .kind = .cursor_wrapped, .path = null, .cursor = 0 });
        }
        b.cursor += 1;
        b.sink.push(b.sink.context, .{ .kind = kind, .path = if (path) |p| .{ .bytes = p } else null, .cursor = b.cursor });
    }
    fn add(b: *Backend, dir: Io.Dir, path: []const u8) core.ReadError!void {
        const actual = try paths.statHandle(dir.handle);
        if (actual.kind != .directory) return error.NotRegular;
        for (b.watches[0..b.used]) |w| {
            if (w.wd >= 0 and std.mem.eql(u8, w.path[0..w.len], path) and actual.identity.device == w.identity.device and actual.identity.inode == w.identity.inode) return;
        }
        var slot: ?usize = null;
        for (b.watches[0..b.used], 0..) |w, i| if (w.wd < 0) {
            slot = i;
            break;
        };
        if (slot == null and b.used == b.limit) return error.ResourceExhausted;
        var proc: [64]u8 = undefined;
        const target = std.fmt.bufPrintZ(&proc, "/proc/self/fd/{d}", .{dir.handle}) catch unreachable;
        const mask = os.IN.MODIFY | os.IN.ATTRIB | os.IN.CLOSE_WRITE | os.IN.MOVE | os.IN.CREATE | os.IN.DELETE | os.IN.DELETE_SELF | os.IN.MOVE_SELF | os.IN.ONLYDIR;
        const rc = os.inotify_add_watch(b.fd.?, target, mask);
        switch (os.errno(rc)) {
            .SUCCESS => {},
            .NOSPC, .NOMEM => return error.ResourceExhausted,
            .ACCES => return error.OutOfScope,
            else => return error.IoFailure,
        }
        const wd: i32 = @intCast(rc);
        for (b.watches[0..b.used]) |w| if (w.wd == wd) {
            // A bind-mount alias cannot replace the original descriptor/path
            // mapping. Keep coverage uncertain and use a full live traversal.
            b.emit(.dropped, null);
            return;
        };
        const index = slot orelse b.used;
        if (slot == null) b.used += 1 else b.emit(.dropped, null);
        const w = &b.watches[index];
        w.* = .{ .wd = wd, .len = path.len, .identity = .{ .device = actual.identity.device, .inode = actual.identity.inode } };
        @memcpy(w.path[0..path.len], path);
    }
    /// Install reachable recursive watches before the authoritative traversal.
    pub fn refresh(b: *Backend, io: Io, root: core.TrustedRoot, cancel: core.Cancel) core.ReadError!bool {
        if (b.fd == null) return error.InvalidArgument;
        b.covered = true;
        // Recover a retired/ignored root registration before reporting coverage.
        b.add(root.dir, ".") catch {
            b.covered = false;
            b.emit(.dropped, null);
            return false;
        };
        var index: usize = 0;
        while (index < b.used) : (index += 1) {
            try cancel.check();
            const w = &b.watches[index];
            if (w.wd < 0) continue;
            const dir = openDirectory(io, root.dir, w.path[0..w.len]) catch {
                _ = os.inotify_rm_watch(b.fd.?, w.wd);
                w.wd = -1;
                b.covered = false;
                b.emit(.root_changed, null);
                continue;
            };
            defer dir.close(io);
            const current = try paths.statHandle(dir.handle);
            if (current.identity.device != w.identity.device or current.identity.inode != w.identity.inode) {
                _ = os.inotify_rm_watch(b.fd.?, w.wd);
                w.wd = -1;
                b.covered = false;
                b.emit(.root_changed, null);
                continue;
            }
            var iter = dir.iterate();
            while (iter.next(io) catch {
                b.covered = false;
                break;
            }) |entry| {
                try cancel.check();
                if (std.mem.eql(u8, entry.name, ".git")) continue;
                var kind = entry.kind;
                if (@import("builtin").is_test) if (b.test_force_unknown) {
                    kind = .unknown;
                };
                if (kind == .unknown) {
                    var name_z: [path_max + 1]u8 = undefined;
                    if (entry.name.len > path_max) {
                        b.covered = false;
                        continue;
                    }
                    @memcpy(name_z[0..entry.name.len], entry.name);
                    name_z[entry.name.len] = 0;
                    const identified = paths.statAt(dir.handle, name_z[0..entry.name.len :0]) catch {
                        b.covered = false;
                        continue;
                    };
                    if (identified) |entry_info| {
                        kind = if (entry_info.kind == .directory) .directory else .file;
                    } else continue;
                }
                if (kind != .directory) continue;
                var relative: [path_max]u8 = undefined;
                const child_path = if (std.mem.eql(u8, w.path[0..w.len], ".")) entry.name else std.fmt.bufPrint(&relative, "{s}/{s}", .{ w.path[0..w.len], entry.name }) catch {
                    b.covered = false;
                    continue;
                };
                paths.validate(child_path) catch {
                    b.covered = false;
                    continue;
                };
                const child = openDirectory(io, root.dir, child_path) catch {
                    b.covered = false;
                    continue;
                };
                defer child.close(io);
                b.add(child, child_path) catch {
                    b.covered = false;
                };
            }
        }
        if (!b.covered) b.emit(.dropped, null);
        return b.covered;
    }
    /// At most 1 MiB per poll. An event storm explicitly loses synchronization.
    pub fn poll(b: *Backend, _: Io, cancel: core.Cancel) core.ReadError!usize {
        const fd = b.fd orelse return error.InvalidArgument;
        b.drained = false;
        var total: usize = 0;
        for (0..64) |_| {
            try cancel.check();
            const rc = os.read(fd, &b.buffer, b.buffer.len);
            switch (os.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => {
                    b.drained = true;
                    return total;
                },
                .INTR => continue,
                else => {
                    b.emit(.dropped, null);
                    return error.IoFailure;
                },
            }
            if (rc == 0) {
                b.emit(.dropped, null);
                return error.IoFailure;
            }
            total += b.decode(b.buffer[0..rc]);
        }
        b.emit(.overflow, null);
        return total;
    }
    /// Bounded parser shared with malformed and kernel-overflow fixtures.
    pub fn decode(b: *Backend, bytes: []const u8) usize {
        var offset: usize = 0;
        var count: usize = 0;
        while (offset < bytes.len) {
            if (count == 512) {
                b.emit(.overflow, null);
                break;
            }
            if (bytes.len - offset < 16) {
                b.emit(.dropped, null);
                break;
            }
            const wd = std.mem.readInt(i32, bytes[offset..][0..4], @import("builtin").cpu.arch.endian());
            const mask = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], @import("builtin").cpu.arch.endian());
            const len = std.mem.readInt(u32, bytes[offset + 12 ..][0..4], @import("builtin").cpu.arch.endian());
            if (len > bytes.len - offset - 16) {
                b.emit(.dropped, null);
                break;
            }
            const raw_name = bytes[offset + 16 ..][0..len];
            offset += 16 + len;
            count += 1;
            if (mask & os.IN.Q_OVERFLOW != 0) {
                b.emit(.overflow, null);
                continue;
            }
            var found: ?*Watch = null;
            for (b.watches[0..b.used]) |*w| if (w.wd == wd and wd >= 0) {
                found = w;
                break;
            };
            const w = found orelse {
                b.emit(.dropped, null);
                continue;
            };
            if (mask & (os.IN.IGNORED | os.IN.UNMOUNT | os.IN.DELETE_SELF | os.IN.MOVE_SELF) != 0) {
                if (mask & os.IN.IGNORED != 0) w.wd = -1;
                b.emit(.root_changed, null);
                continue;
            }
            if (mask & os.IN.ISDIR != 0 and mask & (os.IN.CREATE | os.IN.DELETE | os.IN.MOVE) != 0) b.covered = false;
            var path_buffer: [path_max]u8 = undefined;
            var path: []const u8 = w.path[0..w.len];
            if (len != 0) {
                const end = std.mem.indexOfScalar(u8, raw_name, 0) orelse {
                    b.emit(.dropped, null);
                    continue;
                };
                const name = raw_name[0..end];
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
                    b.emit(.dropped, null);
                    continue;
                }
                path = if (std.mem.eql(u8, path, ".")) name else std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ path, name }) catch {
                    b.emit(.dropped, null);
                    continue;
                };
                paths.validate(path) catch {
                    b.emit(.dropped, null);
                    continue;
                };
            }
            const kind: core.WatchEventKind = if (mask & os.IN.CREATE != 0) .created else if (mask & os.IN.DELETE != 0) .removed else if (mask & os.IN.MOVE != 0) .renamed else .modified;
            b.emit(kind, path);
        }
        return count;
    }
    pub fn synchronized(b: *const Backend) bool {
        return b.drained and b.covered;
    }
    pub fn watchedCount(b: *const Backend) usize {
        var n: usize = 0;
        for (b.watches[0..b.used]) |w| if (w.wd >= 0) {
            n += 1;
        };
        return n;
    }
    /// Exclusive same-owner teardown; callbacks are synchronous inside poll.
    pub fn stop(b: *Backend, _: Io) void {
        if (b.fd) |fd| _ = os.close(fd);
        b.fd = null;
        b.used = 0;
        b.covered = false;
        b.drained = false;
    }
};
fn openDirectory(io: Io, root: Io.Dir, path: []const u8) core.ReadError!Io.Dir {
    try paths.validate(path);
    var current = root;
    var owned = false;
    errdefer if (owned) current.close(io);
    if (std.mem.eql(u8, path, ".")) return root.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false }) catch return error.IoFailure;
    var parts = std.mem.splitScalar(u8, path, '/');
    var z: [path_max + 1]u8 = undefined;
    while (parts.next()) |name| {
        @memcpy(z[0..name.len], name);
        z[name.len] = 0;
        const before = (try paths.statAt(current.handle, z[0..name.len :0])) orelse return error.NotFound;
        if (before.kind == .symlink) return error.PathEscape;
        if (before.kind != .directory) return error.NotRegular;
        const next = current.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch return error.IoFailure;
        const after = paths.statHandle(next.handle) catch |err| {
            next.close(io);
            return err;
        };
        if (!before.identity.eql(after.identity)) {
            next.close(io);
            return error.VersionConflict;
        }
        if (owned) current.close(io);
        current = next;
        owned = true;
    }
    return current;
}
