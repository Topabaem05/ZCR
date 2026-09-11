//! Git-aware streaming traversal (T05, I04; docs/05 §6, docs/07 §3, docs/11 §4).
//!
//! `Traverser.init` allocates every buffer the walk will use: directory frames up
//! to the depth limit, the ignore rule stack, one ignore-file buffer, the path
//! cache for sorted order, and the path buffer. `enumerate` allocates nothing,
//! so memory does not depend on the number of files.
//!
//! The walk starts from a handle-relative, no-follow open of the capability path,
//! applies .gitignore files from the root down (git ls-files --exclude-standard
//! semantics for per-directory files; info/exclude and core.excludesFile are not
//! read), never enters an ignored directory, and pushes matching regular files to
//! the sink as root-relative paths that are valid only during the push.
//!
//! Nothing is dropped silently. Unreadable directories, names that are not valid
//! ZCR paths, ignore files over the size or rule limit (their subtree is not
//! listed, since it could otherwise leak ignored files) and the depth limit are
//! counted in `Coverage.skipped` with a reason; the result is complete only when
//! that count is zero and the result limit was not reached. Policy filters (`.git`,
//! hidden names, symlinks, special files) are reported but do not make a result
//! incomplete.
//!
//! Order `discovery` streams directory order. `path_then_offset` sorts each
//! directory's entries by name bytes before descending, which yields component-wise
//! byte order (`a/b` before `a-c`). A directory that does not fit the path cache
//! falls back to discovery order, with a reason.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ignore = @import("ignore.zig");

const path_max = core.limits.values.path_max_utf8_bytes;
const cancel_check_interval = 256;

pub const Caps = struct {
    /// Entries one sorted walk may hold across the current directory stack.
    path_cache_entries: u32 = 4096,
    /// Name bytes one sorted walk may hold across the current directory stack.
    path_cache_bytes: usize = 256 * 1024,
    max_ignore_file_bytes: usize = core.limits.values.max_ignore_file_bytes,
    max_ignore_rules: u32 = core.limits.values.max_ignore_rules,
    max_depth: u32 = core.limits.values.directory_max_depth,

    /// Pool for the text of all ignore files on the current path.
    pub fn ignorePoolBytes(caps: Caps) usize {
        return @max(2 * caps.max_ignore_file_bytes, 64 * 1024);
    }

    /// Bytes `Traverser.init` allocates for these caps.
    pub fn defaultBytes(caps: Caps) u64 {
        return @as(u64, caps.max_depth + 1) * @sizeOf(Frame) +
            @as(u64, caps.max_ignore_rules) * @sizeOf(ignore.Rule) +
            caps.ignorePoolBytes() +
            caps.max_ignore_file_bytes +
            @as(u64, caps.path_cache_entries) * @sizeOf(CacheEntry) +
            caps.path_cache_bytes;
    }
};

pub const Report = struct {
    complete: bool = false,
    truncated: bool = false,
    order_fallback: bool = false,
    start_ignored: bool = false,
    emitted: u64 = 0,
    entries_seen: u64 = 0,
    files_seen: u64 = 0,
    directories_visited: u64 = 0,
    // Incomplete: counted in Coverage.skipped.
    unreadable_directories: u64 = 0,
    unsupported_names: u64 = 0,
    ignore_limits_exceeded: u64 = 0,
    depth_limited: u64 = 0,
    // Policy filters: reported, not incomplete.
    symlinks_not_followed: u64 = 0,
    special_files: u64 = 0,
    vanished_entries: u64 = 0,

    pub fn skipped(r: Report) u64 {
        return r.unreadable_directories + r.unsupported_names + r.ignore_limits_exceeded + r.depth_limited;
    }
};

const Kind = enum(u8) { directory, file, symlink, other };

const CacheEntry = struct { offset: u32, len: u16, kind: Kind };

const Frame = struct {
    dir: Io.Dir,
    iter: Io.Dir.Iterator,
    path_len: usize,
    rules_mark: ignore.RuleStack.Mark,
    sorted: bool,
    cache_entries_mark: u32,
    cache_bytes_mark: usize,
    next: u32,
};

pub const Traverser = struct {
    allocator: Allocator,
    root: core.TrustedRoot,
    workspace_id: core.WorkspaceId,
    caps: Caps,
    frames: []Frame,
    top: usize = 0,
    rules: ignore.RuleStack,
    ignore_buf: []u8,
    cache_entries: []CacheEntry,
    cache_entries_len: u32 = 0,
    cache_bytes: []u8,
    cache_bytes_len: usize = 0,
    path_buf: [path_max]u8 = undefined,
    scope_buf: [path_max]u8 = undefined,
    reasons_buf: [8][]const u8 = undefined,
    last: Report = .{},

    pub fn init(allocator: Allocator, root: core.TrustedRoot, workspace_id: core.WorkspaceId, caps: Caps) Allocator.Error!Traverser {
        const frames = try allocator.alloc(Frame, caps.max_depth + 1);
        errdefer allocator.free(frames);
        var rules = try ignore.RuleStack.init(allocator, caps.max_ignore_rules, caps.ignorePoolBytes());
        errdefer rules.deinit();
        const ignore_buf = try allocator.alloc(u8, caps.max_ignore_file_bytes);
        errdefer allocator.free(ignore_buf);
        const cache_entries = try allocator.alloc(CacheEntry, caps.path_cache_entries);
        errdefer allocator.free(cache_entries);
        const cache_bytes = try allocator.alloc(u8, caps.path_cache_bytes);
        return .{
            .allocator = allocator,
            .root = root,
            .workspace_id = workspace_id,
            .caps = caps,
            .frames = frames,
            .rules = rules,
            .ignore_buf = ignore_buf,
            .cache_entries = cache_entries,
            .cache_bytes = cache_bytes,
        };
    }

    pub fn deinit(self: *Traverser) void {
        self.allocator.free(self.cache_bytes);
        self.allocator.free(self.cache_entries);
        self.allocator.free(self.ignore_buf);
        self.rules.deinit();
        self.allocator.free(self.frames);
    }

    /// Counters of the last `enumerate` call.
    pub fn report(self: *const Traverser) Report {
        return self.last;
    }

    pub fn enumerate(
        self: *Traverser,
        io: Io,
        capability: core.Capability,
        spec: core.FileSpec,
        sink: core.Sink(core.RelativePath),
        cancel: core.Cancel,
    ) core.ReadError!core.Coverage {
        try self.checkRequest(capability, spec);
        self.last = .{};
        if (cancel.isRequested()) return error.Cancelled;

        const start = capability.path.bytes;
        const scope_len = @min(start.len, self.scope_buf.len);
        @memcpy(self.scope_buf[0..scope_len], start[0..scope_len]);

        const rules_start = self.rules.mark();
        defer self.rules.restore(rules_start);
        defer self.closeFrames(io);

        if (try self.openStart(io, start)) |opened| {
            try self.walk(io, opened.dir, opened.path_len, spec, sink, cancel);
        }

        self.last.complete = self.last.skipped() == 0 and !self.last.truncated;
        return .{
            .scope = self.scope_buf[0..scope_len],
            .skipped = self.last.skipped(),
            .index_state = .live,
            .reasons = self.reasons(),
        };
    }

    comptime {
        core.conforms(core.EnumerateFn(Traverser), Traverser.enumerate);
    }

    fn checkRequest(self: *const Traverser, capability: core.Capability, spec: core.FileSpec) core.ReadError!void {
        if (capability.operation != .enumerate and capability.operation != .search) return error.OutOfScope;
        if (!capability.workspace_id.eql(self.workspace_id)) return error.OutOfScope;
        policy.paths.validate(capability.path.bytes) catch |err| return err;
        if (spec.consistency != .checked_live) return error.Unsupported;
        if (spec.limit == 0 or spec.limit > core.limits.values.max_file_results) return error.InvalidArgument;
        if (spec.glob.len == 0 or spec.glob.len > path_max) return error.InvalidArgument;
    }

    const Start = struct { dir: Io.Dir, path_len: usize };

    /// Opens the start directory, applying the ignore files of its ancestors. Null
    /// when the start directory itself is ignored.
    fn openStart(self: *Traverser, io: Io, start: []const u8) core.ReadError!?Start {
        var dir = self.root.dir.openDir(io, ".", .{ .iterate = true }) catch return error.IoFailure;
        if (std.mem.eql(u8, start, ".")) return .{ .dir = dir, .path_len = 0 };
        errdefer dir.close(io);

        var path_len: usize = 0;
        var components = std.mem.splitScalar(u8, start, '/');
        while (components.next()) |component| {
            if (!self.loadIgnore(io, dir, path_len)) {
                dir.close(io);
                return null;
            }
            const child = dir.openDir(io, component, .{ .iterate = true, .follow_symlinks = false }) catch |err| return switch (err) {
                error.FileNotFound => error.NotFound,
                error.NotDir => error.NotRegular,
                error.SymLinkLoop => error.PathEscape,
                error.AccessDenied, error.PermissionDenied => error.OutOfScope,
                else => error.IoFailure,
            };
            dir.close(io);
            dir = child;
            path_len = self.appendPath(path_len, component) orelse return error.InvalidArgument;
            if (self.rules.isIgnored(self.path_buf[0..path_len], true)) {
                self.last.start_ignored = true;
                dir.close(io);
                return null;
            }
        }
        return .{ .dir = dir, .path_len = path_len };
    }

    fn walk(self: *Traverser, io: Io, start_dir: Io.Dir, start_len: usize, spec: core.FileSpec, sink: core.Sink(core.RelativePath), cancel: core.Cancel) core.ReadError!void {
        try self.enterDir(io, start_dir, start_len, spec);

        while (self.top > 0) {
            self.last.entries_seen += 1;
            if (self.last.entries_seen % cancel_check_interval == 0 and cancel.isRequested()) return error.Cancelled;

            const frame = &self.frames[self.top - 1];
            const entry = self.nextEntry(io, frame) catch {
                self.last.unreadable_directories += 1;
                self.popFrame(io);
                continue;
            } orelse {
                self.popFrame(io);
                continue;
            };

            if (std.ascii.eqlIgnoreCase(entry.name, ".git")) continue;
            if (!spec.include_hidden and entry.name[0] == '.') continue;
            const rel_len = self.appendPath(frame.path_len, entry.name) orelse {
                self.last.unsupported_names += 1;
                continue;
            };
            const rel = self.path_buf[0..rel_len];
            policy.paths.validate(rel) catch {
                self.last.unsupported_names += 1;
                continue;
            };

            switch (entry.kind) {
                .directory => {
                    if (self.rules.isIgnored(rel, true)) continue;
                    if (self.top > self.caps.max_depth) {
                        self.last.depth_limited += 1;
                        continue;
                    }
                    const child = frame.dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
                        switch (err) {
                            error.AccessDenied, error.PermissionDenied => self.last.unreadable_directories += 1,
                            error.SymLinkLoop, error.NotDir => self.last.symlinks_not_followed += 1,
                            error.FileNotFound => self.last.vanished_entries += 1,
                            else => return error.IoFailure,
                        }
                        continue;
                    };
                    try self.enterDir(io, child, rel_len, spec);
                },
                .file => {
                    self.last.files_seen += 1;
                    if (self.rules.isIgnored(rel, false)) continue;
                    if (!ignore.wildmatch(spec.glob, rel)) continue;
                    if (self.last.emitted == spec.limit) {
                        self.last.truncated = true;
                        return;
                    }
                    try sink.push(.{ .bytes = rel });
                    self.last.emitted += 1;
                },
                .symlink => self.last.symlinks_not_followed += 1,
                .other => self.last.special_files += 1,
            }
        }
    }

    const Entry = struct { name: []const u8, kind: Kind };

    fn nextEntry(self: *Traverser, io: Io, frame: *Frame) Io.Dir.Iterator.Error!?Entry {
        if (frame.sorted) {
            if (frame.next == self.cache_entries_len) return null;
            const cached = self.cache_entries[frame.next];
            frame.next += 1;
            return .{ .name = self.cache_bytes[cached.offset..][0..cached.len], .kind = cached.kind };
        }
        while (try frame.iter.next(io)) |entry| {
            return .{ .name = entry.name, .kind = try self.kindOf(frame.dir, entry) orelse continue };
        }
        return null;
    }

    /// Maps a directory entry kind, asking the file system when the entry does not say.
    fn kindOf(self: *Traverser, dir: Io.Dir, entry: Io.Dir.Entry) Io.Dir.Iterator.Error!?Kind {
        return switch (entry.kind) {
            .directory => .directory,
            .file => .file,
            .sym_link => .symlink,
            .unknown => blk: {
                var name: [path_max + 1]u8 = undefined;
                if (entry.name.len > path_max) break :blk .other;
                @memcpy(name[0..entry.name.len], entry.name);
                name[entry.name.len] = 0;
                const stat = policy.paths.statAt(dir.handle, name[0..entry.name.len :0]) catch break :blk .other;
                const found = stat orelse {
                    self.last.vanished_entries += 1;
                    break :blk null;
                };
                break :blk switch (found.kind) {
                    .directory => .directory,
                    .regular => .file,
                    .symlink => .symlink,
                    .other => .other,
                };
            },
            else => .other,
        };
    }

    /// Pushes a frame for `dir`, loading its .gitignore and, for sorted order, its sorted entries.
    fn enterDir(self: *Traverser, io: Io, dir: Io.Dir, path_len: usize, spec: core.FileSpec) core.ReadError!void {
        self.frames[self.top] = .{
            .dir = dir,
            .iter = dir.iterate(),
            .path_len = path_len,
            .rules_mark = self.rules.mark(),
            .sorted = false,
            .cache_entries_mark = self.cache_entries_len,
            .cache_bytes_mark = self.cache_bytes_len,
            .next = self.cache_entries_len,
        };
        self.top += 1;
        self.last.directories_visited += 1;

        if (!self.loadIgnore(io, dir, path_len)) {
            self.popFrame(io);
            return;
        }
        if (spec.order == .path_then_offset) self.sortEntries(io, &self.frames[self.top - 1]) catch {
            self.last.unreadable_directories += 1;
            self.popFrame(io);
        };
    }

    /// Reads a directory's entries into the path cache and sorts them; when the cache is
    /// too small, the frame iterates in discovery order instead.
    fn sortEntries(self: *Traverser, io: Io, frame: *Frame) Io.Dir.Iterator.Error!void {
        while (try frame.iter.next(io)) |entry| {
            const kind = try self.kindOf(frame.dir, entry) orelse continue;
            if (self.cache_entries_len == self.cache_entries.len or
                self.cache_bytes.len - self.cache_bytes_len < entry.name.len or
                entry.name.len > std.math.maxInt(u16))
            {
                self.cache_entries_len = frame.cache_entries_mark;
                self.cache_bytes_len = frame.cache_bytes_mark;
                self.last.order_fallback = true;
                frame.iter = frame.dir.iterate();
                return;
            }
            @memcpy(self.cache_bytes[self.cache_bytes_len..][0..entry.name.len], entry.name);
            self.cache_entries[self.cache_entries_len] = .{ .offset = @intCast(self.cache_bytes_len), .len = @intCast(entry.name.len), .kind = kind };
            self.cache_entries_len += 1;
            self.cache_bytes_len += entry.name.len;
        }
        const entries = self.cache_entries[frame.cache_entries_mark..self.cache_entries_len];
        std.mem.sort(CacheEntry, entries, self.cache_bytes, struct {
            fn lessThan(bytes: []u8, a: CacheEntry, b: CacheEntry) bool {
                return std.mem.lessThan(u8, bytes[a.offset..][0..a.len], bytes[b.offset..][0..b.len]);
            }
        }.lessThan);
        frame.sorted = true;
        frame.next = frame.cache_entries_mark;
    }

    /// Loads `dir/.gitignore` onto the rule stack. False when it is over a limit, in
    /// which case the directory must not be listed.
    fn loadIgnore(self: *Traverser, io: Io, dir: Io.Dir, path_len: usize) bool {
        const file = dir.openFile(io, ".gitignore", .{ .follow_symlinks = false, .allow_directory = false }) catch return true;
        defer file.close(io);
        const stat = file.stat(io) catch return true;
        if (stat.kind != .file) return true;
        if (stat.size > self.caps.max_ignore_file_bytes) {
            self.last.ignore_limits_exceeded += 1;
            return false;
        }
        const n = file.readPositionalAll(io, self.ignore_buf[0..@intCast(stat.size)], 0) catch {
            self.last.ignore_limits_exceeded += 1;
            return false;
        };
        self.rules.pushFile(self.path_buf[0..path_len], self.ignore_buf[0..n]) catch {
            self.last.ignore_limits_exceeded += 1;
            return false;
        };
        return true;
    }

    fn popFrame(self: *Traverser, io: Io) void {
        const frame = &self.frames[self.top - 1];
        self.rules.restore(frame.rules_mark);
        self.cache_entries_len = frame.cache_entries_mark;
        self.cache_bytes_len = frame.cache_bytes_mark;
        frame.dir.close(io);
        self.top -= 1;
    }

    fn closeFrames(self: *Traverser, io: Io) void {
        while (self.top > 0) self.popFrame(io);
    }

    /// Writes `name` after the path of length `parent_len`; null when the result is too long.
    fn appendPath(self: *Traverser, parent_len: usize, name: []const u8) ?usize {
        const sep: usize = if (parent_len == 0) 0 else 1;
        const len = parent_len + sep + name.len;
        if (len > self.path_buf.len) return null;
        if (sep == 1) self.path_buf[parent_len] = '/';
        @memcpy(self.path_buf[parent_len + sep ..][0..name.len], name);
        return len;
    }

    fn reasons(self: *Traverser) []const []const u8 {
        var n: usize = 0;
        const r = self.last;
        const table = [_]struct { active: bool, text: []const u8 }{
            .{ .active = r.unreadable_directories > 0, .text = "unreadable directories were not listed" },
            .{ .active = r.unsupported_names > 0, .text = "names that are not valid ZCR paths were not listed" },
            .{ .active = r.ignore_limits_exceeded > 0, .text = "ignore files over the size or rule limit: their directories were not listed" },
            .{ .active = r.depth_limited > 0, .text = "directory depth limit reached" },
            .{ .active = r.truncated, .text = "result limit reached" },
            .{ .active = r.order_fallback, .text = "path cache full: some directories are in discovery order" },
            .{ .active = r.start_ignored, .text = "the start directory is ignored" },
        };
        for (table) |item| {
            if (!item.active) continue;
            self.reasons_buf[n] = item.text;
            n += 1;
        }
        return self.reasons_buf[0..n];
    }
};
