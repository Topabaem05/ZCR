//! Public FSEvents adapter. The owning thread pumps its private CFRunLoop mode.
//! An empty pump is not a delivery barrier: synchronized() remains false until
//! a bounded barrier is proved on native macOS. Consumers must retain live fallback.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");

pub const supported = builtin.os.tag == .macos;
const path_max = core.limits.values.path_max_utf8_bytes;
const events_per_poll = 512;

/// The receiver copies borrowed event paths before push returns. It must only
/// update its bounded dirty queue and must not reenter the adapter.
pub const EventSink = struct {
    context: *anyopaque,
    push: *const fn (*anyopaque, core.WatchEvent) void,
};

const CFRef = *const anyopaque;
const StreamRef = *anyopaque;
const StreamCallback = *const fn (
    *const anyopaque,
    ?*anyopaque,
    usize,
    ?*anyopaque,
    ?[*]const u32,
    ?[*]const u64,
) callconv(.c) void;
const StreamContext = extern struct {
    version: c_long = 0,
    info: ?*anyopaque,
    retain: ?*const fn (?*const anyopaque) callconv(.c) ?*const anyopaque = null,
    release: ?*const fn (?*const anyopaque) callconv(.c) void = null,
    copy_description: ?*const fn (?*const anyopaque) callconv(.c) ?CFRef = null,
};

extern "c" fn FSEventStreamCreate(?CFRef, StreamCallback, ?*StreamContext, CFRef, u64, f64, u32) ?StreamRef;
extern "c" fn FSEventStreamScheduleWithRunLoop(StreamRef, CFRef, CFRef) void;
extern "c" fn FSEventStreamStart(StreamRef) u8;
extern "c" fn FSEventStreamStop(StreamRef) void;
extern "c" fn FSEventStreamInvalidate(StreamRef) void;
extern "c" fn FSEventStreamRelease(StreamRef) void;
extern "c" fn CFRunLoopGetCurrent() CFRef;
extern "c" fn CFRunLoopRunInMode(CFRef, f64, u8) i32;
extern "c" fn CFStringCreateWithBytes(?CFRef, [*]const u8, c_long, u32, u8) ?CFRef;
extern "c" fn CFArrayCreate(?CFRef, [*]const CFRef, c_long, ?*const anyopaque) ?CFRef;
extern "c" fn CFRelease(CFRef) void;

const flags = struct {
    const must_scan_subdirs: u32 = 0x1;
    const user_dropped: u32 = 0x2;
    const kernel_dropped: u32 = 0x4;
    const ids_wrapped: u32 = 0x8;
    const history_done: u32 = 0x10;
    const root_changed: u32 = 0x20;
    const mount: u32 = 0x40;
    const unmount: u32 = 0x80;
};

/// Once started, this value and the EventSink context must not move or be freed
/// until stop returns. start, refresh, poll and stop belong to one native thread.
pub const Backend = struct {
    stream: ?StreamRef = null,
    root_string: ?CFRef = null,
    paths_array: ?CFRef = null,
    mode_string: ?CFRef = null,
    run_loop: ?CFRef = null,
    owner: ?std.Thread.Id = null,
    fixed_address: ?*Backend = null,
    sink: ?EventSink = null,
    root_bytes: [path_max]u8 = undefined,
    root_len: usize = 0,
    started: bool = false,
    pumping: bool = false,
    in_callback: bool = false,
    remaining_events: usize = 0,
    emitted: usize = 0,
    overflow_reported: bool = false,

    pub fn start(self: *Backend, io: std.Io, root: core.TrustedRoot, sink: EventSink, max_dirs: usize) core.ReadError!void {
        _ = io;
        if (!supported) return error.Unsupported;
        if (self.fixed_address != null or self.stream != null) return error.Busy;
        if (max_dirs == 0) return error.ResourceExhausted;
        const root_path = try checkedRootPath(root.canonical_path);
        self.fixed_address = self;
        self.owner = std.Thread.getCurrentId();
        self.sink = sink;
        self.root_len = root_path.len;
        @memcpy(self.root_bytes[0..root_path.len], root_path);
        errdefer self.releaseResources();

        self.root_string = CFStringCreateWithBytes(null, root_path.ptr, @intCast(root_path.len), 0x08000100, 0) orelse return error.OutOfMemory;
        const paths = [_]CFRef{self.root_string.?};
        // Null array callbacks do not retain elements; root_string is owned by
        // this adapter through stream release, so its lifetime covers the array.
        self.paths_array = CFArrayCreate(null, &paths, paths.len, null) orelse return error.OutOfMemory;
        var mode_buf: [64]u8 = undefined;
        const mode = std.fmt.bufPrint(&mode_buf, "zcr.watch.fsevents.{x}", .{@intFromPtr(self)}) catch unreachable;
        self.mode_string = CFStringCreateWithBytes(null, mode.ptr, @intCast(mode.len), 0x08000100, 0) orelse return error.OutOfMemory;
        self.run_loop = CFRunLoopGetCurrent();
        var context = StreamContext{ .info = self };
        // WatchRoot + NoDefer; omit UseCFTypes and FileEvents. Every ordinary
        // event names a directory whose contents require recursive rescanning.
        self.stream = FSEventStreamCreate(null, callback, &context, self.paths_array.?, std.math.maxInt(u64), 0.05, 0x4 | 0x2) orelse return error.IoFailure;
        FSEventStreamScheduleWithRunLoop(self.stream.?, self.run_loop.?, self.mode_string.?);
        if (FSEventStreamStart(self.stream.?) == 0) return error.IoFailure;
        self.started = true;
    }

    /// FSEvents registers the root recursively; there are no per-directory
    /// handles to refresh. This reports registration coverage, not synchronization.
    pub fn refresh(self: *Backend, io: std.Io, root: core.TrustedRoot, cancel: core.Cancel) core.ReadError!bool {
        _ = io;
        if (!supported) return error.Unsupported;
        try cancel.check();
        try self.checkOwner();
        const root_path = try checkedRootPath(root.canonical_path);
        if (!std.mem.eql(u8, root_path, self.root_bytes[0..self.root_len])) {
            self.emit(.root_changed, null, 0);
            return false;
        }
        return true;
    }

    /// One zero-wait source dispatch. FSEvents can retain events for its latency
    /// window, so neither a timeout nor an empty callback queue proves catch-up.
    pub fn poll(self: *Backend, io: std.Io, cancel: core.Cancel) core.ReadError!usize {
        _ = io;
        if (!supported) return error.Unsupported;
        try cancel.check();
        try self.checkOwner();
        if (self.pumping or self.in_callback) return error.Busy;
        self.pumping = true;
        defer self.pumping = false;
        self.remaining_events = events_per_poll;
        self.emitted = 0;
        self.overflow_reported = false;
        const result = CFRunLoopRunInMode(self.mode_string.?, 0, 1);
        // kCFRunLoopRunTimedOut / kCFRunLoopRunHandledSource.
        if (result != 3 and result != 4) {
            self.collapseBatch();
            return error.IoFailure;
        }
        try cancel.check();
        return self.emitted;
    }

    pub fn stop(self: *Backend, io: std.Io) void {
        _ = io;
        if (!supported) return;
        if (self.fixed_address == null and self.stream == null) return;
        // stop has no error return. Fail closed on an ownership violation rather
        // than freeing a context that a callback can still reference.
        if (self.fixed_address != self or self.owner != std.Thread.getCurrentId()) @panic("FSEvents stop must use the fixed adapter on its owning thread");
        if (self.pumping or self.in_callback) @panic("FSEvents stop cannot run during callback delivery");
        self.releaseResources();
    }

    pub fn watchedCount(self: *const Backend) usize {
        return if (self.started) 1 else 0;
    }

    pub fn synchronized(self: *const Backend) bool {
        _ = self;
        // No bounded delivery barrier has native macOS evidence. In particular,
        // CFRunLoopRunInMode returning without events is not such a barrier.
        return false;
    }

    fn checkOwner(self: *Backend) core.ReadError!void {
        if (!self.started or self.fixed_address != self) return error.InvalidArgument;
        if (self.owner != std.Thread.getCurrentId()) return error.Busy;
    }

    fn releaseResources(self: *Backend) void {
        if (self.stream) |stream| {
            if (self.started) FSEventStreamStop(stream);
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
        }
        if (self.mode_string) |mode| CFRelease(mode);
        if (self.paths_array) |paths| CFRelease(paths);
        if (self.root_string) |root| CFRelease(root);
        self.* = .{};
    }

    fn emit(self: *Backend, kind: core.WatchEventKind, path: ?core.RelativePath, cursor: u64) void {
        const sink = self.sink orelse return;
        sink.push(sink.context, .{ .kind = kind, .path = path, .cursor = cursor });
        self.emitted +|= 1;
    }

    fn collapseBatch(self: *Backend) void {
        self.remaining_events = 0;
        if (self.overflow_reported) return;
        self.overflow_reported = true;
        // Unexamined events may include RootChanged. Preserve the identity
        // requirement as well as full dirty state when dropping their details.
        self.emit(.root_changed, null, 0);
        self.emit(.overflow, null, 0);
    }

    fn ingest(self: *Backend, absolute_path: [*]const u8, event_flags: u32, cursor: u64) void {
        if (event_flags & (flags.root_changed | flags.unmount) != 0) self.emit(.root_changed, null, cursor);
        if (event_flags & flags.ids_wrapped != 0) self.emit(.cursor_wrapped, null, cursor);
        if (event_flags & (flags.user_dropped | flags.kernel_dropped) != 0) self.emit(.dropped, null, cursor);
        if (event_flags & (flags.root_changed | flags.unmount | flags.ids_wrapped | flags.user_dropped | flags.kernel_dropped) != 0) return;
        if (event_flags == flags.history_done) return;
        if (event_flags & flags.mount != 0) {
            self.emit(.modified, null, cursor);
            return;
        }

        // Callback memory is borrowed. Bound the NUL search, validate the root
        // boundary, and copy only the relative path before calling the receiver.
        var absolute_len: usize = 0;
        while (absolute_len <= path_max) : (absolute_len += 1) {
            if (absolute_path[absolute_len] == 0) break;
        }
        if (absolute_len > path_max) {
            self.collapseBatch();
            return;
        }
        const absolute = absolute_path[0..absolute_len];
        const root = self.root_bytes[0..self.root_len];
        if (std.mem.eql(u8, absolute, root)) {
            self.emit(.modified, null, cursor);
            return;
        }
        const relative = if (std.mem.eql(u8, root, "/")) blk: {
            if (absolute.len < 2 or absolute[0] != '/') {
                self.collapseBatch();
                return;
            }
            break :blk absolute[1..];
        } else blk: {
            if (absolute.len <= root.len or !std.mem.startsWith(u8, absolute, root) or absolute[root.len] != '/') {
                self.collapseBatch();
                return;
            }
            break :blk absolute[root.len + 1 ..];
        };
        var path_copy: [path_max]u8 = undefined;
        @memcpy(path_copy[0..relative.len], relative);
        const path = core.RelativePath.init(path_copy[0..relative.len]) catch {
            self.collapseBatch();
            return;
        };
        // MustScanSubDirs and ordinary directory events both require recursive
        // path rescanning. WatchEvent deliberately carries no version authority.
        self.emit(.modified, path, cursor);
    }
};

fn checkedRootPath(path: []const u8) core.ReadError![]const u8 {
    if (path.len == 0 or path.len > path_max or path[0] != '/' or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArgument;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn callback(_: *const anyopaque, info: ?*anyopaque, count: usize, event_paths: ?*anyopaque, event_flags: ?[*]const u32, event_ids: ?[*]const u64) callconv(.c) void {
    const self: *Backend = @ptrCast(@alignCast(info orelse return));
    if (!self.started) return;
    if (self.fixed_address != self or self.owner != std.Thread.getCurrentId()) @panic("FSEvents callback escaped adapter ownership");
    if (self.in_callback) @panic("FSEvents callback reentered");
    self.in_callback = true;
    defer self.in_callback = false;
    if (count == 0) return;
    if (!self.pumping or count > self.remaining_events or event_paths == null or event_flags == null or event_ids == null) {
        self.collapseBatch();
        return;
    }
    self.remaining_events -= count;
    const paths: [*]const ?[*]const u8 = @ptrCast(@alignCast(event_paths.?));
    for (0..count) |i| {
        const path = paths[i] orelse {
            self.collapseBatch();
            return;
        };
        self.ingest(path, event_flags.?[i], event_ids.?[i]);
        if (self.overflow_reported) return;
    }
}

test "WA-002 Darwin callback copies coalesced relative paths and rejects sibling prefixes" {
    const Capture = struct {
        kinds: [4]core.WatchEventKind = undefined,
        count: usize = 0,
        path: [32]u8 = undefined,
        path_len: usize = 0,
        fn push(raw: *anyopaque, event: core.WatchEvent) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kinds[self.count] = event.kind;
            self.count += 1;
            if (event.path) |path| {
                @memcpy(self.path[0..path.bytes.len], path.bytes);
                self.path_len = path.bytes.len;
            }
        }
    };
    var capture = Capture{};
    var backend = Backend{ .sink = .{ .context = &capture, .push = Capture.push } };
    backend.root_len = "/approved/work".len;
    @memcpy(backend.root_bytes[0..backend.root_len], "/approved/work");
    backend.ingest("/approved/work/dir", flags.must_scan_subdirs, 41);
    try std.testing.expectEqualStrings("dir", capture.path[0..capture.path_len]);
    try std.testing.expectEqual(core.WatchEventKind.modified, capture.kinds[0]);
    backend.ingest("/approved/work-other/file", 0, 42);
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqual(core.WatchEventKind.root_changed, capture.kinds[1]);
    try std.testing.expectEqual(core.WatchEventKind.overflow, capture.kinds[2]);
    try std.testing.expect(!backend.synchronized());
}

test "WA-005 Darwin oversized callback collapses without reading skipped event arrays" {
    const Capture = struct {
        kinds: [2]core.WatchEventKind = undefined,
        count: usize = 0,
        fn push(raw: *anyopaque, event: core.WatchEvent) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kinds[self.count] = event.kind;
            self.count += 1;
        }
    };
    var capture = Capture{};
    var backend = Backend{
        .sink = .{ .context = &capture, .push = Capture.push },
        .started = true,
        .owner = std.Thread.getCurrentId(),
        .pumping = true,
        .remaining_events = events_per_poll,
    };
    backend.fixed_address = &backend;
    callback(&backend, &backend, events_per_poll + 1, null, null, null);
    callback(&backend, &backend, events_per_poll + 1, null, null, null);
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(core.WatchEventKind.root_changed, capture.kinds[0]);
    try std.testing.expectEqual(core.WatchEventKind.overflow, capture.kinds[1]);
    try std.testing.expectEqual(@as(usize, 0), backend.remaining_events);
}
