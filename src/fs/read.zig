//! Bounded range reads (T04, I03; docs/07 §2, docs/09 §6).
//!
//! `readRange` follows `open → fstat → bounded pread → fstat → close` on a
//! handle-relative, no-follow open of a regular file, in two passes per attempt:
//!   1. scan with one scratch chunk: count lines up to the requested range, decide
//!      truncation, and hash the whole file when write intent asks for it;
//!   2. free the scratch, allocate the result as one block, and read exactly the
//!      range bytes into it.
//! Keeping scratch and result apart, and the result in one block, bounds tracked
//! memory by the reservation even though the result arena grows nodes by 1.5x.
//! If size, mtime or identity differ after the read, or the path now names another
//! file, the attempt is discarded and retried once; a second change is
//! `VersionConflict`. Lines from two versions are never combined.
//!
//! Lines keep their terminator: a span covers the line bytes including `\n` or
//! `\r\n`, and the texts of all lines concatenate to the original bytes. There is
//! no line after a final newline. Text that is not UTF-8, or contains NUL, needs a
//! binary capability and is `Unsupported` (docs/09 §9). Live files are read with
//! pread; mmap is not used.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const cache = @import("zcr_cache");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const metadata = @import("metadata.zig");

pub const max_attempts = 2;

/// Space for the arena node header, alignment and length rounding.
const node_slack_bytes = 256;

pub const reason_output_budget = "output_bytes reached before the requested range ended";
pub const reason_reservation = "reservation cannot hold the full requested range";
pub const reason_no_digest = "file is larger than the 8 MiB write limit; whole-file digest not computed";

/// Test hooks for docs/12 §7 fault injection. Production readers leave `fault` null.
pub const ReadFault = struct {
    /// Upper bound for bytes returned by one positional read, to force short reads.
    max_read_bytes: ?usize = null,
    /// Every Nth read makes no progress, as an interrupted call that is retried.
    interrupt_every: ?u32 = null,
    /// Runs after open and the first metadata snapshot of each attempt.
    after_open: ?*const fn (context: ?*anyopaque, attempt: u32) void = null,
    /// Runs after each scanned chunk.
    after_chunk: ?*const fn (context: ?*anyopaque, chunk: u32) void = null,
    context: ?*anyopaque = null,
    reads: u32 = 0,
    interrupts: u32 = 0,
    attempts: u32 = 0,
};

pub const Reader = struct {
    root: core.TrustedRoot,
    workspace_id: core.WorkspaceId,
    /// Workspace generation from the registry (T10); reported, not interpreted.
    generation: u64,
    fault: ?*ReadFault = null,
    /// Optional request-local facade. Batch/bulk readers leave this null.
    cache_session: ?*cache.Session = null,
    cache_result: core.CacheResult = .not_applicable,

    pub fn init(root: core.TrustedRoot, workspace_id: core.WorkspaceId, generation: u64) Reader {
        return .{ .root = root, .workspace_id = workspace_id, .generation = generation };
    }

    /// `allocator` must draw from `reservation` (for example a `zcr_memory.ReservedAllocator`).
    /// The caller releases the reservation after `Owned.deinit`.
    pub fn readRange(
        self: *Reader,
        io: Io,
        allocator: Allocator,
        capability: core.Capability,
        spec: core.ReadSpec,
        reservation: *core.Reservation,
        cancel: core.Cancel,
    ) core.ReadError!core.Owned(core.ReadResult) {
        try self.checkRequest(capability, spec, reservation);
        const effective_cancel = cancel.withTimeout(io, spec.deadline_ms);
        try effective_cancel.check();

        var owned: core.Owned(core.ReadResult) = .{ .value = undefined, .arena = .init(allocator) };
        errdefer owned.arena.deinit();

        var cache_copy: ?cache.Session = if (self.cache_session) |source| source.* else null;
        if (cache_copy) |*bound| {
            bound.cancel = effective_cancel;
            if (!bound.context.bound_workspace.eql(self.workspace_id)) return error.OutOfScope;
            const reader_root = try policy.paths.statHandle(self.root.dir.handle);
            const cache_root = try policy.paths.statHandle(bound.authorizer.root.dir.handle);
            if (!reader_root.identity.eql(cache_root.identity)) return error.OutOfScope;
            self.generation = try bound.currentGeneration();
            self.cache_result = .miss;
            if (try self.readCached(&owned, capability, spec, reservation, bound, effective_cancel)) return owned;
        }

        var attempt: u32 = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            try effective_cancel.check();
            if (self.fault) |f| f.attempts += 1;
            self.readOnce(io, allocator, &owned, spec, reservation, effective_cancel, attempt) catch |err| switch (err) {
                error.Changed => {
                    owned.arena.deinit();
                    owned.arena = .init(allocator);
                    continue;
                },
                else => |e| return e,
            };
            if (cache_copy) |*bound| {
                if (try bound.currentGeneration() != self.generation) return error.VersionConflict;
                try observeComplete(bound, capability, spec, &owned.value, effective_cancel);
            }
            return owned;
        }
        return error.VersionConflict;
    }

    comptime {
        core.conforms(core.ReadRangeFn(Reader), Reader.readRange);
    }

    fn checkRequest(self: *const Reader, capability: core.Capability, spec: core.ReadSpec, reservation: *const core.Reservation) core.ReadError!void {
        const v = core.limits.values;
        if (capability.operation != .read and capability.operation != .batch_read) return error.OutOfScope;
        if (!capability.workspace_id.eql(self.workspace_id)) return error.OutOfScope;
        if (!std.mem.eql(u8, capability.path.bytes, spec.path.bytes)) return error.OutOfScope;
        if (spec.consistency != .checked_live) return error.Unsupported;
        policy.paths.validate(spec.path.bytes) catch |err| return err;
        _ = core.LineRange.init(spec.lines.first, spec.lines.count) catch return error.InvalidArgument;
        if (spec.output_bytes == 0 or spec.output_bytes > v.max_output_bytes) return error.InvalidArgument;
        if (spec.deadline_ms == 0 or spec.deadline_ms > v.max_deadline_ms) return error.InvalidArgument;

        if (reservation.released) return error.ResourceExhausted;
        if (spec.output_bytes > reservation.output) return error.OutputBudgetExceeded;
        if (reservation.fd < 1 or reservation.bytes < v.chunk_bytes) return error.ResourceExhausted;
    }

    fn cacheFailure(err: core.ReadError, cancel: core.Cancel) core.ReadError!void {
        try cancel.check();
        // A failed optimization never supplies bytes. Authority and cancellation
        // failures stay errors; the filesystem reader owns other fallback behavior.
        switch (err) {
            error.OutOfScope, error.PathEscape, error.Cancelled, error.DeadlineExceeded, error.ManifestUnbound => return err,
            else => {},
        }
    }
    fn observeComplete(bound: *cache.Session, capability: core.Capability, spec: core.ReadSpec, result: *const core.ReadResult, cancel: core.Cancel) core.ReadError!void {
        if (!result.status.complete or result.status.truncated or spec.lines.first != 1 or result.version.size > bound.store.options.max_file_bytes) return;
        const raw: []const u8 = if (result.lines.len == 0) blk: {
            if (result.version.size != 0) return;
            break :blk "";
        } else blk: {
            const first = result.lines[0];
            const last = result.lines[result.lines.len - 1];
            if (first.span.start != 0 or last.span.end != result.version.size) return;
            break :blk first.text.ptr[0..@intCast(result.version.size)];
        };
        var version = result.version;
        var digest: core.ContentHash = undefined;
        var hasher = Sha256.init(.{});
        var offset: usize = 0;
        while (offset < raw.len) {
            try cancel.check();
            const end = @min(raw.len, offset + cache.verification_scratch_bytes);
            hasher.update(raw[offset..end]);
            offset = end;
        }
        digest = hasher.finalResult();
        version.sha256 = digest;
        _ = bound.observe(capability, raw, version, .interactive) catch |err| {
            try cacheFailure(err, cancel);
            return;
        };
    }
    fn readCached(self: *Reader, owned: *core.Owned(core.ReadResult), capability: core.Capability, spec: core.ReadSpec, reservation: *const core.Reservation, bound: *cache.Session, cancel: core.Cancel) core.ReadError!bool {
        const current = bound.cacheGetCurrent(capability, .{ .max_pinned_bytes = bound.store.budget.caps.bytes }) catch |err| {
            try cacheFailure(err, cancel);
            return false;
        };
        self.generation = current.version.generation;
        const pin = current.pin orelse return false;
        defer bound.unpin(pin) catch unreachable;
        const selected = try cache.lines.select(pin.bytes, try bound.lineIndex(pin), spec.lines);
        const budget: Budget = .{ .output_bytes = spec.output_bytes, .payload_bytes = ((reservation.bytes -| node_slack_bytes) * 2) / 3, .fixed_bytes = spec.path.bytes.len + 2 * @sizeOf([]const u8) };
        var plan: Plan = .{ .digest = if (spec.write_intent) current.version.sha256 else null };
        var cursor: usize = @intCast(selected.span.start);
        while (cursor < selected.span.end) {
            try cancel.check();
            const end = if (std.mem.indexOfScalarPos(u8, pin.bytes, cursor, '\n')) |newline| newline + 1 else pin.bytes.len;
            if (try budget.add(&plan, cursor, end)) break;
            cursor = end;
        }
        const reason_count: usize = @intFromBool(plan.stop != null);
        const text_len: usize = @intCast(plan.end - plan.start);
        const lines_bytes = plan.lines * @sizeOf(core.Line);
        const reasons_bytes = reason_count * @sizeOf([]const u8);
        const total = lines_bytes + reasons_bytes + spec.path.bytes.len + text_len;
        const block = try owned.arena.allocator().alignedAlloc(u8, .of(core.Line), total);
        const result_lines = @as([*]core.Line, @ptrCast(@alignCast(block.ptr)))[0..plan.lines];
        const reasons = @as([*][]const u8, @ptrCast(@alignCast(block[lines_bytes..].ptr)))[0..reason_count];
        if (plan.stop) |stop| reasons[0] = if (stop == .output_budget) reason_output_budget else reason_reservation;
        const path = block[lines_bytes + reasons_bytes ..][0..spec.path.bytes.len];
        @memcpy(path, spec.path.bytes);
        const text = block[total - text_len ..];
        @memcpy(text, pin.bytes[@intCast(plan.start)..@intCast(plan.end)]);
        splitLines(result_lines, text, plan.start, spec.lines.first) catch return error.VersionConflict;
        try cancel.check();
        if (try bound.currentGeneration() != current.version.generation) return error.VersionConflict;
        var version = current.version;
        version.sha256 = plan.digest; // Preserve the public write-intent digest contract.
        owned.value = .{ .path = .{ .bytes = path }, .lines = result_lines, .version = version, .status = .{ .complete = plan.stop == null, .truncated = plan.stop != null, .consistency = .checked_live, .coverage = .{ .scope = path, .skipped = 0, .index_state = .live, .reasons = reasons } } };
        self.cache_result = .hit;
        return true;
    }

    const AttemptError = core.ReadError || error{Changed};

    fn readOnce(
        self: *Reader,
        io: Io,
        allocator: Allocator,
        owned: *core.Owned(core.ReadResult),
        spec: core.ReadSpec,
        reservation: *const core.Reservation,
        cancel: core.Cancel,
        attempt: u32,
    ) AttemptError!void {
        const opened = try metadata.openRegular(io, self.root.dir, spec.path.bytes);
        defer opened.file.close(io);
        const before = opened.before;
        if (self.fault) |f| if (f.after_open) |hook| hook(f.context, attempt);

        const hash_whole = spec.write_intent and before.size <= core.limits.values.max_write_file_bytes;
        const plan = try self.scan(io, allocator, opened.file, before.size, spec, reservation, cancel, hash_whole);
        try cancel.check();

        // Result block: [lines][reasons][path][text], one arena allocation.
        var reasons_buf: [2][]const u8 = undefined;
        var reason_count: usize = 0;
        if (plan.stop) |stop| {
            reasons_buf[reason_count] = switch (stop) {
                .output_budget => reason_output_budget,
                .reservation => reason_reservation,
            };
            reason_count += 1;
        }
        if (spec.write_intent and !hash_whole) {
            reasons_buf[reason_count] = reason_no_digest;
            reason_count += 1;
        }
        const text_len: usize = @intCast(plan.end - plan.start);
        const lines_bytes = plan.lines * @sizeOf(core.Line);
        const reasons_bytes = reason_count * @sizeOf([]const u8);
        const total = lines_bytes + reasons_bytes + spec.path.bytes.len + text_len;
        const block = try owned.arena.allocator().alignedAlloc(u8, .of(core.Line), total);

        const lines = @as([*]core.Line, @ptrCast(@alignCast(block.ptr)))[0..plan.lines];
        const reasons = @as([*][]const u8, @ptrCast(@alignCast(block[lines_bytes..].ptr)))[0..reason_count];
        @memcpy(reasons, reasons_buf[0..reason_count]);
        const path = block[lines_bytes + reasons_bytes ..][0..spec.path.bytes.len];
        @memcpy(path, spec.path.bytes);
        const text = block[total - text_len ..];

        try self.readExact(io, opened.file, text, plan.start, cancel);
        try splitLines(lines, text, plan.start, spec.lines.first);
        if (!validText(text)) return error.Unsupported;

        const after = metadata.snapshot(io, opened.file) catch return error.IoFailure;
        if (!metadata.sameVersion(before, after)) return error.Changed;
        const now = metadata.pathIdentity(io, self.root.dir, spec.path.bytes) catch |err| switch (err) {
            error.NotFound => return error.Changed,
            error.Changed => return error.Changed,
            else => |e| return e,
        };
        if (now == null or !now.?.eql(before.identity)) return error.Changed;
        try cancel.check();

        owned.value = .{
            .path = .{ .bytes = path },
            .lines = lines,
            .version = metadata.fileVersion(self.workspace_id, self.generation, before, plan.digest),
            .status = .{
                .complete = plan.stop == null,
                .truncated = plan.stop != null,
                .consistency = .checked_live,
                .coverage = .{ .scope = path, .skipped = 0, .index_state = .live, .reasons = reasons },
            },
        };
    }

    const Stop = enum { output_budget, reservation };

    const Plan = struct {
        start: u64 = 0,
        end: u64 = 0,
        lines: usize = 0,
        stop: ?Stop = null,
        digest: ?core.ContentHash = null,
    };

    fn scan(
        self: *Reader,
        io: Io,
        allocator: Allocator,
        file: Io.File,
        size: u64,
        spec: core.ReadSpec,
        reservation: *const core.Reservation,
        cancel: core.Cancel,
        hash_whole: bool,
    ) AttemptError!Plan {
        const scratch_len: usize = @intCast(@max(1, @min(core.limits.values.chunk_bytes, size)));
        const scratch = try allocator.alloc(u8, scratch_len);
        defer allocator.free(scratch);

        const first: u64 = spec.lines.first;
        const last: u64 = first + spec.lines.count - 1;
        const budget: Budget = .{
            .output_bytes = spec.output_bytes,
            // The result arena asks its child for about 1.5x the block (ArenaAllocator node growth).
            .payload_bytes = ((reservation.bytes -| node_slack_bytes) * 2) / 3,
            .fixed_bytes = spec.path.bytes.len + 2 * @sizeOf([]const u8),
        };

        var plan: Plan = .{};
        var hasher = Sha256.init(.{});
        var line_number: u64 = 1;
        var line_start: u64 = 0;
        var offset: u64 = 0;
        var collecting = true;
        var chunk: u32 = 0;

        while (true) {
            try cancel.check();
            const n = try self.readAt(io, file, scratch, offset, cancel);
            if (n == 0) break;
            const data = scratch[0..n];
            if (hash_whole) hasher.update(data);

            if (collecting) {
                var i: usize = 0;
                while (std.mem.indexOfScalarPos(u8, data, i, '\n')) |newline| {
                    const line_end = offset + newline + 1;
                    if (line_number >= first) {
                        if (try budget.add(&plan, line_start, line_end)) {
                            collecting = false;
                            break;
                        }
                    }
                    line_number += 1;
                    line_start = line_end;
                    if (line_number > last) {
                        collecting = false;
                        break;
                    }
                    i = newline + 1;
                }
            }
            offset += n;
            if (self.fault) |f| if (f.after_chunk) |hook| hook(f.context, chunk);
            chunk += 1;
            if (!collecting and !hash_whole) break;
        }

        // A last line without a terminator is still a line; nothing follows a final newline.
        if (collecting and line_start < offset and line_number >= first and line_number <= last) {
            _ = try budget.add(&plan, line_start, offset);
        }
        if (hash_whole) {
            if (offset != size) return error.Changed;
            plan.digest = hasher.finalResult();
        }
        return plan;
    }

    const Budget = struct {
        output_bytes: u64,
        payload_bytes: u64,
        fixed_bytes: u64,

        /// Adds one line to the plan; returns true when the range stops here.
        fn add(b: Budget, plan: *Plan, start: u64, end: u64) error{ OutputBudgetExceeded, ResourceExhausted }!bool {
            const text = (if (plan.lines == 0) 0 else plan.end - plan.start) + (end - start);
            const payload = text + (plan.lines + 1) * @sizeOf(core.Line) + b.fixed_bytes;
            const stop: ?Stop = if (text > b.output_bytes) .output_budget else if (payload > b.payload_bytes) .reservation else null;
            if (stop) |reason| {
                if (plan.lines == 0) return if (reason == .output_budget) error.OutputBudgetExceeded else error.ResourceExhausted;
                plan.stop = reason;
                return true;
            }
            if (plan.lines == 0) plan.start = start;
            plan.end = end;
            plan.lines += 1;
            return false;
        }
    };

    fn readAt(self: *Reader, io: Io, file: Io.File, buffer: []u8, offset: u64, cancel: core.Cancel) (error{IoFailure} || core.errors.InterruptError)!usize {
        while (true) {
            try cancel.check();
            var want = buffer.len;
            if (self.fault) |f| {
                f.reads += 1;
                if (f.interrupt_every) |every| if (f.reads % every == 0) {
                    f.interrupts += 1;
                    continue;
                };
                if (f.max_read_bytes) |limit| want = @min(want, limit);
            }
            return file.readPositional(io, &.{buffer[0..want]}, offset) catch return error.IoFailure;
        }
    }

    fn readExact(self: *Reader, io: Io, file: Io.File, buffer: []u8, offset: u64, cancel: core.Cancel) AttemptError!void {
        var filled: usize = 0;
        while (filled < buffer.len) {
            try cancel.check();
            const end = filled + @min(buffer.len - filled, core.limits.values.chunk_bytes);
            const n = try self.readAt(io, file, buffer[filled..end], offset + filled, cancel);
            if (n == 0) return error.Changed; // the file got shorter since the scan
            filled += n;
        }
    }
};

/// Rebuilds line records from the range bytes; a different line count than the
/// scan found means the bytes changed between passes.
fn splitLines(lines: []core.Line, text: []const u8, start: u64, first_number: u32) error{Changed}!void {
    var index: usize = 0;
    var line_start: usize = 0;
    while (line_start < text.len) : (index += 1) {
        if (index == lines.len) return error.Changed;
        const line_end = if (std.mem.indexOfScalarPos(u8, text, line_start, '\n')) |newline| newline + 1 else text.len;
        lines[index] = .{
            .number = first_number + @as(u32, @intCast(index)),
            .span = .{ .start = start + line_start, .end = start + line_end },
            .text = text[line_start..line_end],
        };
        line_start = line_end;
    }
    if (index != lines.len) return error.Changed;
}

fn validText(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, 0) == null and std.unicode.utf8ValidateSlice(text);
}
