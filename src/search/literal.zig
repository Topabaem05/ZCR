//! Literal search with context (T06, I05; docs/07 §3, docs/12 §1).
//!
//! `Searcher.init` allocates every buffer: the traverser (T05), one scan window of
//! `chunk_bytes + literal - 1` bytes, match, interval and line tables, and the
//! output text buffer. `search` allocates nothing.
//!
//! For each candidate file from the traversal (glob, hidden and ignore rules
//! applied), in one attempt:
//!   1. open no-follow as a regular file; files over `max_file_bytes` are skipped;
//!   2. scan windows of `chunk_bytes` new bytes plus the last `literal.len - 1`
//!      bytes of the previous window, accepting only matches that start at or after
//!      the end of the previous match (global offsets, non-overlapping, leftmost),
//!      and counting lines in the same pass. A NUL byte or invalid UTF-8 anywhere in
//!      the file skips it, since results must be text (docs/09 §9);
//!   3. merge context windows and re-read them (context.zig), then check size,
//!      mtime and identity again and that the path still names the file.
//! A changed file is retried once; a second change skips it. Lines from two
//! versions are never combined.
//!
//! Output budget counts context text bytes. `limit` counts matches across files.
//! When either stops the search, the result is truncated and says so. SearchSpec
//! has no output or deadline field (see handoff): the budget is `output_bytes` on
//! the searcher and a deadline is expressed through `Cancel`.
//!
//! Candidates stream from a dedicated traversal. The files API's returned-path
//! limit does not limit the internal candidate scan; match/output limits still do.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const fs_read = @import("zcr_fs_read");
const traverse = @import("zcr_fs_traverse");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const metadata = fs_read.metadata;

pub const scalar = @import("scalar.zig");
pub const context = @import("context.zig");

const max_literal_bytes = core.limits.values.path_max_utf8_bytes;
const max_matches = core.limits.values.max_search_matches;

pub const Caps = struct {
    chunk_bytes: usize = core.limits.values.chunk_bytes,
    /// Output text capacity; `Searcher.output_bytes` may lower it per call.
    output_bytes: u64 = core.limits.values.default_output_bytes,
    max_context_lines: u32 = 4096,
    traverse: traverse.Caps = .{},

    /// Bytes `Searcher.init` allocates for these caps.
    pub fn defaultBytes(caps: Caps) u64 {
        return caps.traverse.defaultBytes() +
            caps.chunk_bytes + max_literal_bytes +
            max_matches * (@sizeOf(context.FileMatch) + @sizeOf(core.SearchMatch) + @sizeOf(context.Interval)) +
            @as(u64, caps.max_context_lines) * @sizeOf(core.Line) +
            caps.output_bytes;
    }
};

/// Test hooks for docs/12 §7.
pub const SearchFault = struct {
    after_scan: ?*const fn (context: ?*anyopaque, path: []const u8) void = null,
    /// Runs after each scanned chunk of a file.
    after_chunk: ?*const fn (context: ?*anyopaque, chunk: u32) void = null,
    context: ?*anyopaque = null,
};

pub const Report = struct {
    complete: bool = false,
    truncated: bool = false,
    files_considered: u64 = 0,
    files_matched: u64 = 0,
    matches: u64 = 0,
    output_bytes: u64 = 0,
    retries: u64 = 0,
    // Skipped: counted in Coverage.skipped.
    oversize_skipped: u64 = 0,
    binary_skipped: u64 = 0,
    invalid_utf8_skipped: u64 = 0,
    changed_skipped: u64 = 0,
    open_failed: u64 = 0,
    /// Nanoseconds from the start of the call (awake clock).
    first_match_ns: ?u64 = null,
    first_push_ns: ?u64 = null,
    finished_ns: u64 = 0,
    traversal: traverse.Report = .{},

    pub fn searchSkipped(r: Report) u64 {
        return r.oversize_skipped + r.binary_skipped + r.invalid_utf8_skipped + r.changed_skipped + r.open_failed;
    }
};

pub const Searcher = struct {
    allocator: Allocator,
    root: core.TrustedRoot,
    workspace_id: core.WorkspaceId,
    generation: u64,
    caps: Caps,
    traverser: traverse.Traverser,
    window: []u8,
    matches: []context.FileMatch,
    results: []core.SearchMatch,
    intervals: []context.Interval,
    lines: []core.Line,
    text: []u8,
    /// Output budget for the next calls, at most `caps.output_bytes`.
    output_bytes: u64,
    fault: ?*SearchFault = null,
    path_buf: [core.limits.values.path_max_utf8_bytes]u8 = undefined,
    reasons_buf: [16][]const u8 = undefined,
    last: Report = .{},
    run: Run = undefined,

    const Run = struct {
        io: Io,
        spec: core.SearchSpec,
        sink: core.Sink(core.SearchFileResult),
        cancel: core.Cancel,
        started: Io.Clock.Timestamp,
        remaining_matches: u32,
        output_used: u64,
        stop: bool,
        failure: ?core.ReadError,
    };

    pub fn init(allocator: Allocator, root: core.TrustedRoot, workspace_id: core.WorkspaceId, generation: u64, caps: Caps) (Allocator.Error || error{InvalidArgument})!Searcher {
        if (caps.chunk_bytes == 0 or caps.output_bytes > core.limits.values.max_output_bytes) return error.InvalidArgument;
        var traverser = try traverse.Traverser.init(allocator, root, workspace_id, caps.traverse);
        errdefer traverser.deinit();
        const window = try allocator.alloc(u8, caps.chunk_bytes + max_literal_bytes);
        errdefer allocator.free(window);
        const matches = try allocator.alloc(context.FileMatch, max_matches);
        errdefer allocator.free(matches);
        const results = try allocator.alloc(core.SearchMatch, max_matches);
        errdefer allocator.free(results);
        const intervals = try allocator.alloc(context.Interval, max_matches);
        errdefer allocator.free(intervals);
        const lines = try allocator.alloc(core.Line, caps.max_context_lines);
        errdefer allocator.free(lines);
        const text = try allocator.alloc(u8, @intCast(caps.output_bytes));
        return .{
            .allocator = allocator,
            .root = root,
            .workspace_id = workspace_id,
            .generation = generation,
            .caps = caps,
            .traverser = traverser,
            .window = window,
            .matches = matches,
            .results = results,
            .intervals = intervals,
            .lines = lines,
            .text = text,
            .output_bytes = caps.output_bytes,
        };
    }

    pub fn deinit(self: *Searcher) void {
        self.allocator.free(self.text);
        self.allocator.free(self.lines);
        self.allocator.free(self.intervals);
        self.allocator.free(self.results);
        self.allocator.free(self.matches);
        self.allocator.free(self.window);
        self.traverser.deinit();
    }

    /// Counters of the last `search` call.
    pub fn report(self: *const Searcher) Report {
        return self.last;
    }

    pub fn search(
        self: *Searcher,
        io: Io,
        capability: core.Capability,
        spec: core.SearchSpec,
        sink: core.Sink(core.SearchFileResult),
        cancel: core.Cancel,
    ) core.ReadError!core.Coverage {
        try self.checkRequest(capability, spec);
        self.last = .{};
        self.run = .{
            .io = io,
            .spec = spec,
            .sink = sink,
            .cancel = cancel,
            .started = Io.Clock.Timestamp.now(io, .awake),
            .remaining_matches = spec.limit,
            .output_used = 0,
            .stop = false,
            .failure = null,
        };
        try cancel.check();

        const file_spec: core.FileSpec = .{
            .glob = spec.glob,
            .limit = core.limits.values.max_file_results,
            .include_hidden = spec.include_hidden,
            .order = spec.order,
        };
        const walk_sink: core.Sink(core.RelativePath) = .{ .context = self, .push_fn = onFile };
        _ = self.traverser.enumerateSearchCandidates(io, capability, file_spec, walk_sink, cancel) catch |err| {
            if (self.run.failure) |failure| return failure;
            if (!(err == error.Cancelled and self.run.stop)) return err;
        };

        try cancel.check();
        const walk = self.traverser.report();
        self.last.traversal = walk;
        self.last.finished_ns = self.elapsed();
        const skipped = walk.skipped() + self.last.searchSkipped();
        self.last.complete = skipped == 0 and !self.last.truncated and !walk.truncated;
        return .{
            .scope = capability.path.bytes,
            .skipped = skipped,
            .index_state = .live,
            .reasons = self.reasons(walk),
        };
    }

    comptime {
        core.conforms(core.SearchLiteralFn(Searcher), Searcher.search);
    }

    fn checkRequest(self: *const Searcher, capability: core.Capability, spec: core.SearchSpec) core.ReadError!void {
        const v = core.limits.values;
        if (capability.operation != .search) return error.OutOfScope;
        if (!capability.workspace_id.eql(self.workspace_id)) return error.OutOfScope;
        if (spec.consistency != .checked_live) return error.Unsupported;
        if (spec.literal.len == 0 or spec.literal.len > max_literal_bytes) return error.InvalidArgument;
        if (!std.unicode.utf8ValidateSlice(spec.literal)) return error.InvalidArgument;
        if (std.mem.indexOfScalar(u8, spec.literal, '\n') != null) return error.Unsupported;
        if (spec.context_lines > context.max_context_lines) return error.InvalidArgument;
        if (spec.limit == 0 or spec.limit > v.max_search_matches) return error.InvalidArgument;
        if (spec.max_file_bytes == 0 or spec.max_file_bytes > v.max_search_file_bytes) return error.InvalidArgument;
        if (self.output_bytes == 0 or self.output_bytes > self.caps.output_bytes) return error.InvalidArgument;
    }

    fn elapsed(self: *const Searcher) u64 {
        const now = Io.Clock.Timestamp.now(self.run.io, .awake);
        return @intCast(@max(0, now.raw.nanoseconds - self.run.started.raw.nanoseconds));
    }

    /// Traversal sink: searches one candidate. Errors that the sink type cannot carry are
    /// kept in `run.failure` and the traversal is stopped with `Cancelled`.
    fn onFile(ctx: *anyopaque, item: core.RelativePath) core.SinkError!void {
        const self: *Searcher = @ptrCast(@alignCast(ctx));
        if (self.run.stop) return error.Cancelled;
        self.searchFile(item.bytes) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.Busy => {
                self.run.failure = error.Busy;
                return error.Busy;
            },
            error.OutputBudgetExceeded => {
                self.run.failure = error.OutputBudgetExceeded;
                return error.OutputBudgetExceeded;
            },
            else => {
                self.run.failure = err;
                return error.Cancelled;
            },
        };
        if (self.run.stop) return error.Cancelled;
    }

    fn searchFile(self: *Searcher, candidate: []const u8) core.ReadError!void {
        const io = self.run.io;
        self.last.files_considered += 1;
        @memcpy(self.path_buf[0..candidate.len], candidate);
        const path = self.path_buf[0..candidate.len];

        var attempt: u32 = 0;
        while (attempt < 2) : (attempt += 1) {
            if (attempt == 1) self.last.retries += 1;
            try self.run.cancel.check();

            const opened = metadata.openRegular(io, self.root.dir, path) catch |err| switch (err) {
                error.IoFailure => return error.IoFailure,
                error.Changed => continue,
                else => {
                    self.last.open_failed += 1;
                    return;
                },
            };
            defer opened.file.close(io);
            const before = opened.before;
            if (before.size > self.run.spec.max_file_bytes) {
                self.last.oversize_skipped += 1;
                return;
            }

            const scan = try self.scanFile(opened.file, before.size);
            switch (scan.outcome) {
                .changed => continue,
                .binary => {
                    self.last.binary_skipped += 1;
                    return;
                },
                .invalid_utf8 => {
                    self.last.invalid_utf8_skipped += 1;
                    return;
                },
                .text => {},
            }
            if (self.fault) |f| if (f.after_scan) |hook| hook(f.context, path);
            try self.run.cancel.check();
            if (scan.matches == 0) {
                const after_scan = metadata.snapshot(io, opened.file) catch return error.IoFailure;
                if (!metadata.sameVersion(before, after_scan)) continue;
                const current = metadata.pathIdentity(io, self.root.dir, path) catch continue;
                if (current == null or !current.?.eql(before.identity)) continue;
                return;
            }

            const found = self.matches[0..scan.matches];
            const interval_count = context.buildIntervals(found, self.run.spec.context_lines, self.intervals);
            const projection = try context.project(
                io,
                opened.file,
                self,
                self.run.spec.literal,
                found,
                self.intervals[0..interval_count],
                self.output_bytes - self.run.output_used,
                self.lines,
                self.text,
                self.results,
            );
            if (projection.changed) continue;
            const after = metadata.snapshot(io, opened.file) catch return error.IoFailure;
            if (!metadata.sameVersion(before, after)) continue;
            const now = metadata.pathIdentity(io, self.root.dir, path) catch continue;
            if (now == null or !now.?.eql(before.identity)) continue;

            if (projection.matches > 0) {
                try self.run.cancel.check();
                try self.run.sink.push(.{
                    .path = .{ .bytes = path },
                    .matches = self.results[0..projection.matches],
                    .context = self.lines[0..projection.lines],
                    .version = metadata.fileVersion(self.workspace_id, self.generation, before, null),
                });
                if (self.last.first_push_ns == null) self.last.first_push_ns = self.elapsed();
                self.last.files_matched += 1;
                self.last.matches += projection.matches;
                self.last.output_bytes += projection.text;
                self.run.output_used += projection.text;
                self.run.remaining_matches -= @intCast(projection.matches);
            }
            if (scan.limit_reached or projection.truncated) {
                self.last.truncated = true;
                self.run.stop = true;
            }
            return;
        }
        self.last.changed_skipped += 1;
    }

    const ScanOutcome = enum { text, binary, invalid_utf8, changed };
    const Scan = struct { outcome: ScanOutcome, matches: usize, limit_reached: bool };

    fn scanFile(self: *Searcher, file: Io.File, size: u64) core.ReadError!Scan {
        const literal = self.run.spec.literal;
        const context_lines = self.run.spec.context_lines;
        const capacity = @min(self.run.remaining_matches, self.matches.len);
        const overlap = literal.len - 1;

        var lines: LineTracker = .{ .context_lines = context_lines };
        var utf8: Utf8Stream = .{};
        var window_start: u64 = 0;
        var keep: usize = 0;
        var next_start: u64 = 0;
        var count: usize = 0;
        var limit_reached = false;
        var chunk: u32 = 0;

        while (true) {
            try self.run.cancel.check();
            const n = try self.readAt(self.run.io, file, self.window[keep..][0..self.caps.chunk_bytes], window_start + keep);
            if (n == 0) break;
            const fresh = self.window[keep..][0..n];
            if (std.mem.indexOfScalar(u8, fresh, 0) != null) return .{ .outcome = .binary, .matches = 0, .limit_reached = false };
            if (!utf8.feed(fresh)) return .{ .outcome = .invalid_utf8, .matches = 0, .limit_reached = false };

            const data = self.window[0 .. keep + n];
            if (!limit_reached) {
                var pos: usize = if (next_start > window_start) @intCast(next_start - window_start) else 0;
                while (scalar.find(data, literal, pos)) |at| {
                    const start = window_start + at;
                    if (count == capacity) {
                        limit_reached = true;
                        break;
                    }
                    lines.advance(data, window_start, start);
                    self.matches[count] = .{
                        .start = start,
                        .end = start + literal.len,
                        .line = lines.line,
                        .window_first = lines.windowFirst(),
                        .window_start = lines.windowStart(),
                    };
                    count += 1;
                    if (self.last.first_match_ns == null) self.last.first_match_ns = self.elapsed();
                    next_start = start + literal.len;
                    pos = at + literal.len;
                }
            }

            const next_keep = @min(overlap, data.len);
            const boundary = window_start + data.len - next_keep;
            lines.advance(data, window_start, boundary);
            std.mem.copyForwards(u8, self.window[0..next_keep], data[data.len - next_keep ..]);
            window_start = boundary;
            keep = next_keep;
            if (self.fault) |f| if (f.after_chunk) |hook| hook(f.context, chunk);
            chunk += 1;
        }
        if (!utf8.finish()) return .{ .outcome = .invalid_utf8, .matches = 0, .limit_reached = false };
        if (window_start + keep != size) return .{ .outcome = .changed, .matches = 0, .limit_reached = false };
        return .{ .outcome = .text, .matches = count, .limit_reached = limit_reached };
    }

    pub fn readAt(self: *Searcher, io: Io, file: Io.File, buffer: []u8, offset: u64) (error{IoFailure} || core.errors.InterruptError)!usize {
        try self.run.cancel.check();
        return file.readPositional(io, &.{buffer}, offset) catch return error.IoFailure;
    }

    fn reasons(self: *Searcher, walk: traverse.Report) []const []const u8 {
        const r = self.last;
        const table = [_]struct { active: bool, text: []const u8 }{
            .{ .active = walk.unreadable_directories > 0, .text = "unreadable directories were not searched" },
            .{ .active = walk.unsupported_names > 0, .text = "names that are not valid ZCR paths were not searched" },
            .{ .active = walk.ignore_limits_exceeded > 0, .text = "ignore files over the size or rule limit: their directories were not searched" },
            .{ .active = walk.unreadable_ignore_files > 0, .text = "ignore files unreadable, changed or non-regular: their directories were not searched" },
            .{ .active = walk.depth_limited > 0, .text = "directory depth limit reached" },
            .{ .active = walk.truncated, .text = "candidate file limit reached" },
            .{ .active = r.truncated, .text = "match limit or output budget reached" },
            .{ .active = r.oversize_skipped > 0, .text = "files over max_file_bytes were not searched" },
            .{ .active = r.binary_skipped > 0, .text = "files containing NUL bytes were not searched" },
            .{ .active = r.invalid_utf8_skipped > 0, .text = "files that are not valid UTF-8 were not searched" },
            .{ .active = r.changed_skipped > 0, .text = "files that changed twice during the search were skipped" },
            .{ .active = r.open_failed > 0, .text = "files that could not be opened as regular files were skipped" },
        };
        var n: usize = 0;
        for (table) |item| {
            if (!item.active) continue;
            self.reasons_buf[n] = item.text;
            n += 1;
        }
        return self.reasons_buf[0..n];
    }
};

/// Line number and recent line starts while scanning forward.
const LineTracker = struct {
    context_lines: u32,
    line: u32 = 1,
    cursor: u64 = 0,
    /// Ring of the last `context_lines + 1` line starts.
    starts: [context.max_context_lines + 1]Start = [_]Start{.{ .line = 1, .offset = 0 }} ++ [_]Start{undefined} ** context.max_context_lines,
    head: usize = 0,
    len: usize = 1,

    const Start = struct { line: u32, offset: u64 };

    /// Counts newlines in `data` between the cursor and `target` (both global offsets).
    fn advance(t: *LineTracker, data: []const u8, window_start: u64, target: u64) void {
        if (target <= t.cursor) return;
        var index: usize = @intCast(t.cursor - window_start);
        const end: usize = @intCast(target - window_start);
        while (std.mem.indexOfScalarPos(u8, data[0..end], index, '\n')) |newline| {
            t.line += 1;
            t.push(.{ .line = t.line, .offset = window_start + newline + 1 });
            index = newline + 1;
        }
        t.cursor = target;
    }

    fn push(t: *LineTracker, start: Start) void {
        const size = t.context_lines + 1;
        t.head = (t.head + 1) % size;
        t.starts[t.head] = start;
        t.len = @min(t.len + 1, size);
    }

    fn windowFirst(t: *const LineTracker) u32 {
        return if (t.line > t.context_lines) t.line - t.context_lines else 1;
    }

    fn windowStart(t: *const LineTracker) u64 {
        const first = t.windowFirst();
        const size = t.context_lines + 1;
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            const s = t.starts[(t.head + size - i) % size];
            if (s.line == first) return s.offset;
        }
        unreachable; // the ring always holds the last context_lines + 1 starts
    }
};

/// Streaming UTF-8 validation across chunk boundaries.
const Utf8Stream = struct {
    pending: [4]u8 = undefined,
    pending_len: usize = 0,

    fn feed(s: *Utf8Stream, bytes: []const u8) bool {
        var index: usize = 0;
        if (s.pending_len > 0) {
            const need = sequenceLength(s.pending[0]);
            const take = @min(need - s.pending_len, bytes.len);
            @memcpy(s.pending[s.pending_len..][0..take], bytes[0..take]);
            s.pending_len += take;
            index = take;
            if (s.pending_len < need) return true;
            if (!std.unicode.utf8ValidateSlice(s.pending[0..need])) return false;
            s.pending_len = 0;
        }
        var end = bytes.len;
        var back: usize = 1;
        while (back <= 3 and back <= bytes.len - index) : (back += 1) {
            const b = bytes[bytes.len - back];
            if (b & 0xC0 == 0x80) continue;
            const len = sequenceLength(b);
            if (len == 0) return false;
            if (len > back) end = bytes.len - back;
            break;
        }
        if (!std.unicode.utf8ValidateSlice(bytes[index..end])) return false;
        @memcpy(s.pending[0 .. bytes.len - end], bytes[end..]);
        s.pending_len = bytes.len - end;
        return true;
    }

    fn finish(s: *const Utf8Stream) bool {
        return s.pending_len == 0;
    }

    fn sequenceLength(lead: u8) usize {
        return switch (lead) {
            0x00...0x7F => 1,
            0xC2...0xDF => 2,
            0xE0...0xEF => 3,
            0xF0...0xF4 => 4,
            else => 0,
        };
    }
};
