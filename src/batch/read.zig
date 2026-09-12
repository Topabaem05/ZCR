//! Batch read (T07, I06; docs/07 §4, docs/05 §7).
//!
//! `batchRead` accepts 1..32 items from one session-bound workspace and returns
//! one result or one error per item, in input order with the item ids copied.
//!
//! 1. The request is refused as a whole for a wrong item count, an empty, long,
//!    non-UTF-8 or repeated item id, an invalid line range or output size, a
//!    session bound to another workspace, or a released reservation. Nothing is
//!    read or allocated before these checks.
//! 2. Each item is authorized on its own (I01); a refused path fails that item.
//! 3. Items share a read only when path, range, write intent, consistency, output
//!    cap and deadline match. Other ranges are read independently: an invalid
//!    byte or a line that exceeds one item's cap must not fail another item.
//! 4. The result store is allocated once: item records, ids, paths, and room for
//!    at most `reservation.output` text bytes and the matching line records. What
//!    is left of the reservation is the memory pool for reads in progress.
//! 5. Reads are dispatched strictly in item order. A read takes its output grant
//!    from the shared output pool and its memory from the pool; if either would
//!    be short, it waits for running reads to finish. With nothing running, a
//!    read that still does not fit fails its items: `E_OUTPUT_BUDGET` for output,
//!    `E_RESOURCE` for memory. Because a partial output grant is only used when
//!    no earlier read is still running, results do not depend on how many reads
//!    run at once. Concurrency is bounded by `Caps.max_concurrency`, the
//!    reservation's handles and the memory pool, never by the item count.
//! 6. A read that returns fewer lines than an item asked for because the shared
//!    grant was smaller than the item's own `output_bytes` fails that item with
//!    `E_OUTPUT_BUDGET` rather than returning a silently shorter result.
//!
//! I06 has no `Cancel` parameter; the batcher holds one. Cancellation stops
//! dispatch, running reads observe it per chunk, and `Cancelled` is returned after
//! every running read has finished and all memory is released.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const fs_read = @import("zcr_fs_read");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Line = core.Line;
const WireCode = core.errors.WireCode;

pub const max_item_id_bytes = 64;
const max_items = core.limits.values.max_batch_items;
const max_output = core.limits.values.max_output_bytes;
/// Arena node header, alignment and length rounding.
const node_slack_bytes = 256;

pub const reason_output_refused = "some items exceeded the shared batch output_bytes";
pub const reason_item_errors = "some items failed; see their errors";

pub const Caps = struct {
    /// Items read at the same time, before the reservation is considered.
    max_concurrency: u32 = 4,
};

pub const JobEvent = struct { job: u32, running: u32, started: bool };

/// Test hooks for docs/12 §7. Called with the batch lock held; must not block.
pub const BatchFault = struct {
    on_job: ?*const fn (context: ?*anyopaque, event: JobEvent) void = null,
    context: ?*anyopaque = null,
};

pub const Report = struct {
    items: u32 = 0,
    /// Reads after deduplication.
    jobs: u32 = 0,
    /// Items with the same read specification as an earlier item.
    deduplicated: u32 = 0,
    /// Retained for report compatibility; unequal ranges are no longer merged.
    merged: u32 = 0,
    workers: u32 = 0,
    peak_running: u32 = 0,
    output_limit: u64 = 0,
    /// Text bytes kept in the result store.
    output_used: u64 = 0,
    /// Items failed with E_OUTPUT_BUDGET because the shared output pool was short.
    output_refused: u32 = 0,
    /// Items failed with E_RESOURCE.
    resource_refused: u32 = 0,
    item_errors: u32 = 0,
    /// Bytes charged to the reservation for the result store.
    store_bytes: u64 = 0,
};

/// Bytes an arena takes from its child for one allocation of `bytes` (node growth is about 1.5x).
fn arenaCharge(bytes: u64) u64 {
    return node_slack_bytes + bytes + bytes / 2 + 2;
}

/// Reservation bytes one read of `line_count` lines with `output_bytes` of text needs
/// (T04 `Reader`: one scratch chunk, then one result block in an arena).
pub fn jobBytes(output_bytes: u64, line_count: u32, path_len: usize) u64 {
    const payload = output_bytes + @as(u64, line_count) * @sizeOf(Line) + path_len + 2 * @sizeOf([]const u8);
    return @max(core.limits.values.chunk_bytes, arenaCharge(payload));
}

fn itemOutput(spec: core.ReadSpec) u64 {
    return @min(spec.output_bytes, max_output);
}

/// Bytes the result store takes from the reservation for these items and output cap.
pub fn storeCharge(items: []const core.BatchReadItem, output_bytes: u64) u64 {
    return arenaCharge(storeBytes(items, output_bytes));
}

/// Size of the one store allocation: item records, ids, paths, text and line records.
fn storeBytes(items: []const core.BatchReadItem, output_bytes: u64) u64 {
    var ids: u64 = 0;
    var paths: u64 = 0;
    var text: u64 = 0;
    var lines: u64 = 0;
    for (items) |item| {
        ids += item.item_id.len;
        paths += item.spec.path.bytes.len;
        text += itemOutput(item.spec);
        lines += item.spec.lines.count;
    }
    text = @min(text, output_bytes);
    // Every returned line holds at least one byte.
    lines = @min(lines, text);
    const n: u64 = items.len;
    const records = n * (@sizeOf(core.BatchItem) + 3 * @sizeOf([]const u8)) + 2 * @sizeOf([]const u8);
    const padding = 32 * (2 * n + 1);
    return records + ids + paths + text + lines * @sizeOf(Line) + padding;
}

/// Reservation a caller needs so that `concurrency` items can be read at once.
/// The output text lives in the result store, so `output_bytes` is part of the store
/// charge and the total bytes are the store plus `concurrency` reads.
pub fn plannedCost(items: []const core.BatchReadItem, output_bytes: u64, concurrency: u32) error{InvalidArgument}!core.ResourceCost {
    try Batcher.checkRequest(items);
    if (concurrency == 0) return error.InvalidArgument;
    if (output_bytes == 0 or output_bytes > max_output) return error.InvalidArgument;
    var groups: Groups = .{};
    for (items, 0..) |_, i| _ = groups.add(items, i);
    var job_max: u64 = 0;
    for (groups.jobs[0..groups.count]) |job| {
        job_max = @max(job_max, jobBytes(@min(job.want, output_bytes), job.lineCount(), job.path.bytes.len));
    }
    const workers: u32 = @min(concurrency, groups.count);
    const total = storeCharge(items, output_bytes) + workers * job_max;
    return .{ .scratch_bytes = total -| output_bytes, .output_bytes = output_bytes, .fds = @intCast(workers) };
}

// ------------------------------------------------------------------ messages

fn message(code: WireCode) []const u8 {
    return switch (code) {
        .E_INVALID_ARGUMENT => "invalid item",
        .E_SCOPE => "path is outside the task scope",
        .E_PATH_ESCAPE => "path leaves the workspace root",
        .E_UNSUPPORTED => "unsupported consistency or file content",
        .E_NOT_FOUND => "file not found",
        .E_NOT_REGULAR => "not a regular file",
        .E_VERSION_CONFLICT => "file changed during the read",
        .E_BUSY => "busy",
        .E_RESOURCE => "batch reservation cannot hold this item",
        .E_OUTPUT_BUDGET => "first line exceeds the item's output_bytes",
        .E_CANCELLED => "cancelled",
        .E_DEADLINE => "deadline exceeded",
        .E_IO => "I/O failure",
        else => "internal error",
    };
}

fn errorInfo(code: WireCode) core.errors.ErrorInfo {
    return .{ .code = code, .message = message(code), .retryable = core.errors.defaultRetryable(code) };
}

const shared_budget_error: core.errors.ErrorInfo = .{
    .code = .E_OUTPUT_BUDGET,
    .message = "shared batch output_bytes exhausted before this item",
    .retryable = false,
};
const merged_budget_error: core.errors.ErrorInfo = .{
    .code = .E_OUTPUT_BUDGET,
    .message = "merged range reached output_bytes before this item",
    .retryable = false,
};

// ------------------------------------------------------------------ batcher

const Job = struct {
    path: core.RelativePath,
    first: u32,
    last: u32,
    write_intent: bool,
    consistency: core.RequestConsistency,
    deadline_ms: u32,
    /// Output cap shared by every member of this exact-specification group.
    want: u64,

    fn lineCount(job: Job) u32 {
        return job.last - job.first + 1;
    }
};

/// Exact read specifications share a read. A union of unequal ranges or output
/// caps can fail on bytes that a standalone member would never return.
const Groups = struct {
    jobs: [max_items]Job = undefined,
    count: u32 = 0,
    /// Read of each grouped item.
    member_of: [max_items]?u32 = @splat(null),
    deduplicated: u32 = 0,
    merged: u32 = 0,

    fn add(g: *Groups, items: []const core.BatchReadItem, i: usize) u32 {
        const spec = items[i].spec;
        const last = spec.lines.first + (spec.lines.count - 1);
        const found: ?u32 = for (g.jobs[0..g.count], 0..) |job, j| {
            if (!std.mem.eql(u8, job.path.bytes, spec.path.bytes)) continue;
            if (job.write_intent != spec.write_intent or job.consistency != spec.consistency) continue;
            if (spec.lines.first != job.first or last != job.last) continue;
            if (itemOutput(spec) != job.want or spec.deadline_ms != job.deadline_ms) continue;
            break @intCast(j);
        } else null;

        const j = found orelse {
            g.jobs[g.count] = .{
                .path = spec.path,
                .first = spec.lines.first,
                .last = last,
                .write_intent = spec.write_intent,
                .consistency = spec.consistency,
                .deadline_ms = spec.deadline_ms,
                .want = itemOutput(spec),
            };
            g.member_of[i] = g.count;
            g.count += 1;
            return g.count - 1;
        };
        g.deduplicated += 1;
        g.member_of[i] = j;
        return j;
    }
};

const Outcome = union(enum) {
    pending,
    ok: core.ReadResult,
    err: core.errors.ErrorInfo,
};

pub const Batcher = struct {
    authorizer: *policy.Authorizer,
    reader: *fs_read.Reader,
    caps: Caps,
    cancel: core.Cancel,
    fault: ?*BatchFault = null,
    last: Report = .{},

    pub fn init(authorizer: *policy.Authorizer, reader: *fs_read.Reader, caps: Caps, cancel: core.Cancel) Batcher {
        return .{ .authorizer = authorizer, .reader = reader, .caps = caps, .cancel = cancel };
    }

    /// Counters of the last `batchRead` call.
    pub fn report(self: *const Batcher) Report {
        return self.last;
    }

    /// `allocator` must draw from `reservation`; the caller releases the reservation
    /// after `Owned.deinit`.
    pub fn batchRead(
        self: *Batcher,
        io: Io,
        allocator: Allocator,
        context: core.SessionContext,
        items: []const core.BatchReadItem,
        reservation: *core.Reservation,
    ) core.ReadError!core.Owned(core.BatchResult) {
        self.last = .{};
        try checkRequest(items);
        if (!context.bound_workspace.eql(self.reader.workspace_id)) return error.OutOfScope;
        if (reservation.released or reservation.fd == 0) return error.ResourceExhausted;
        try self.cancel.check();

        var run: Run = .{
            .batcher = self,
            .io = io,
            .allocator = allocator,
            .items = items,
            .budget_id = reservation.budget_id,
            .output_pool = @min(reservation.output, max_output),
        };
        self.last.items = @intCast(items.len);
        self.last.output_limit = run.output_pool;
        run.plan(context);

        const store_bytes = storeCharge(items, run.output_pool);
        self.last.store_bytes = store_bytes;
        if (store_bytes > reservation.bytes) return error.ResourceExhausted;
        run.memory_pool = reservation.bytes - store_bytes;

        var owned: core.Owned(core.BatchResult) = .{ .value = undefined, .arena = .init(allocator) };
        errdefer owned.arena.deinit();
        const store = try owned.arena.allocator().alignedAlloc(u8, .of(Line), @intCast(storeBytes(items, run.output_pool)));
        run.store = .init(store);
        const records = run.store.allocator().alloc(core.BatchItem, items.len) catch return error.ResourceExhausted;
        for (items, records) |item, *record| {
            record.item_id = run.store.allocator().dupe(u8, item.item_id) catch return error.ResourceExhausted;
        }

        if (run.groups.count > 0) {
            const workers: u32 = @max(1, @min(@min(self.caps.max_concurrency, run.groups.count), reservation.fd));
            var group: Io.Group = .init;
            var spawned: u32 = 1;
            while (spawned < workers) : (spawned += 1) {
                group.concurrent(io, Run.worker, .{&run}) catch break;
            }
            self.last.workers = spawned;
            run.worker();
            group.await(io) catch {};
        }
        self.last.peak_running = run.peak_running;
        self.last.output_used = run.output_used;
        try self.cancel.check();
        if (run.cancelled) return error.Cancelled;

        var status: core.ResultStatus = .{
            .complete = true,
            .truncated = false,
            .consistency = .checked_live,
            .coverage = .{ .scope = "requested_files", .skipped = 0, .index_state = .live },
        };
        for (records, run.outcomes[0..items.len]) |*record, outcome| {
            switch (outcome) {
                .ok => |result| {
                    record.result = .{ .ok = result };
                    if (result.status.truncated) status.truncated = true;
                    if (!result.status.complete) status.complete = false;
                },
                .err => |info| {
                    record.result = .{ .err = info };
                    self.last.item_errors += 1;
                    status.coverage.skipped += 1;
                    status.complete = false;
                    if (info.code == .E_OUTPUT_BUDGET) status.truncated = true;
                },
                .pending => unreachable, // every job is dispatched unless the batch was cancelled
            }
        }
        self.last.output_refused = run.output_refused;
        self.last.resource_refused = run.resource_refused;

        var reasons: [2][]const u8 = undefined;
        var reason_count: usize = 0;
        if (run.output_refused > 0) {
            reasons[reason_count] = reason_output_refused;
            reason_count += 1;
        }
        if (self.last.item_errors > run.output_refused) {
            reasons[reason_count] = reason_item_errors;
            reason_count += 1;
        }
        const kept = run.store.allocator().dupe([]const u8, reasons[0..reason_count]) catch return error.ResourceExhausted;
        status.coverage.reasons = kept;

        owned.value = .{ .items = records, .status = status };
        try self.cancel.check();
        return owned;
    }

    comptime {
        core.conforms(core.BatchReadFn(Batcher), Batcher.batchRead);
    }

    fn checkRequest(items: []const core.BatchReadItem) error{InvalidArgument}!void {
        if (items.len == 0 or items.len > max_items) return error.InvalidArgument;
        for (items, 0..) |item, i| {
            const id = item.item_id;
            if (id.len == 0 or id.len > max_item_id_bytes or !std.unicode.utf8ValidateSlice(id)) return error.InvalidArgument;
            for (items[0..i]) |earlier| if (std.mem.eql(u8, earlier.item_id, id)) return error.InvalidArgument;
            _ = core.LineRange.init(item.spec.lines.first, item.spec.lines.count) catch return error.InvalidArgument;
            if (item.spec.output_bytes == 0 or item.spec.output_bytes > max_output) return error.InvalidArgument;
        }
    }
};

const Run = struct {
    batcher: *Batcher,
    io: Io,
    allocator: Allocator,
    items: []const core.BatchReadItem,
    budget_id: u32,

    groups: Groups = .{},
    capabilities: [max_items]core.Capability = undefined,
    outcomes: [max_items]Outcome = @splat(.pending),

    store: std.heap.FixedBufferAllocator = undefined,

    // Guarded by `mutex`.
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    next: u32 = 0,
    running: u32 = 0,
    peak_running: u32 = 0,
    memory_pool: u64 = 0,
    output_pool: u64,
    output_used: u64 = 0,
    output_refused: u32 = 0,
    resource_refused: u32 = 0,
    stop: bool = false,
    cancelled: bool = false,

    /// Authorizes every item and groups the authorized ones into reads.
    fn plan(run: *Run, context: core.SessionContext) void {
        const self = run.batcher;
        for (run.items, 0..) |item, i| {
            const capability = self.authorizer.authorize(run.io, context, .batch_read, item.spec.path) catch |err| {
                run.outcomes[i] = .{ .err = errorInfo(core.errors.wireCode(err)) };
                continue;
            };
            const before = run.groups.count;
            const j = run.groups.add(run.items, i);
            if (j == before) run.capabilities[j] = capability;
        }
        self.last.jobs = run.groups.count;
        self.last.deduplicated = run.groups.deduplicated;
        self.last.merged = run.groups.merged;
    }

    fn hook(run: *Run, job: u32, started: bool) void {
        const fault = run.batcher.fault orelse return;
        const f = fault.on_job orelse return;
        f(fault.context, .{ .job = job, .running = run.running, .started = started });
    }

    fn worker(run: *Run) void {
        const io = run.io;
        run.mutex.lockUncancelable(io);
        defer run.mutex.unlock(io);
        while (true) {
            if (run.stop or run.next == run.groups.count) return;
            if (run.batcher.cancel.isRequested()) {
                run.stop = true;
                run.cancelled = true;
                run.changed.broadcast(io);
                return;
            }
            const index = run.next;
            const job = &run.groups.jobs[index];
            const grant = @min(job.want, run.output_pool);
            const need = jobBytes(grant, job.lineCount(), job.path.bytes.len);
            const waits_output = grant < job.want and run.running > 0;
            const waits_memory = need > run.memory_pool and run.running > 0;
            if (waits_output or waits_memory) {
                run.changed.waitUncancelable(io, &run.mutex);
                continue;
            }
            run.next += 1;
            if (grant == 0) {
                run.refuseMembers(index, shared_budget_error);
                run.changed.broadcast(io);
                continue;
            }
            if (need > run.memory_pool) {
                run.refuseMembers(index, errorInfo(.E_RESOURCE));
                run.changed.broadcast(io);
                continue;
            }

            run.memory_pool -= need;
            run.output_pool -= grant;
            run.running += 1;
            run.peak_running = @max(run.peak_running, run.running);
            run.hook(index, true);

            run.mutex.unlock(io);
            var result = run.read(index, grant, need);
            run.mutex.lockUncancelable(io);

            run.finish(index, grant, &result);
            // The read's memory goes back to the pool only after it is freed.
            if (result) |*owned| {
                run.mutex.unlock(io);
                owned.deinit();
                run.mutex.lockUncancelable(io);
            } else |_| {}
            run.hook(index, false);
            run.running -= 1;
            run.memory_pool += need;
            run.changed.broadcast(io);
        }
    }

    fn read(run: *Run, index: u32, grant: u64, need: u64) core.ReadError!core.Owned(core.ReadResult) {
        const job = run.groups.jobs[index];
        var view: core.Reservation = .{ .budget_id = run.budget_id, .bytes = need, .fd = 1, .cpu = 0, .output = grant };
        const spec: core.ReadSpec = .{
            .path = job.path,
            .lines = .{ .first = job.first, .count = job.lineCount() },
            .write_intent = job.write_intent,
            .consistency = job.consistency,
            .output_bytes = grant,
            .deadline_ms = job.deadline_ms,
        };
        return run.batcher.reader.readRange(run.io, run.allocator, run.capabilities[index], spec, &view, run.batcher.cancel);
    }

    fn countRefusal(run: *Run, info: core.errors.ErrorInfo) void {
        if (info.message.ptr == shared_budget_error.message.ptr) run.output_refused += 1;
        if (info.code == .E_RESOURCE) run.resource_refused += 1;
    }

    fn refuseMembers(run: *Run, index: u32, info: core.errors.ErrorInfo) void {
        for (run.groups.member_of[0..run.items.len], 0..) |member, i| {
            if (member != index) continue;
            run.outcomes[i] = .{ .err = info };
            run.countRefusal(info);
        }
    }

    /// Turns one read into member outcomes and copies what they use into the store. Lock held.
    fn finish(run: *Run, index: u32, grant: u64, result: *core.ReadError!core.Owned(core.ReadResult)) void {
        const job = run.groups.jobs[index];
        const owned = result.* catch |err| {
            switch (err) {
                error.Cancelled => {
                    run.stop = true;
                    run.cancelled = true;
                },
                error.OutputBudgetExceeded => {
                    // The first line of the range exceeds the grant.
                    run.refuseMembers(index, if (grant < job.want) shared_budget_error else errorInfo(.E_OUTPUT_BUDGET));
                },
                else => |e| run.refuseMembers(index, errorInfo(core.errors.wireCode(e))),
            }
            run.output_pool += grant;
            return;
        };
        const union_result = owned.value;
        const lines = union_result.lines;
        const union_complete = union_result.status.complete;
        const shared_short = grant < job.want;

        // First pass: decide each member and how many union lines the store must keep.
        const Decision = union(enum) { lines: struct { from: usize, to: usize, own_cut: bool, covers_end: bool }, err: core.errors.ErrorInfo };
        var decisions: [max_items]Decision = undefined;
        var keep: usize = 0;
        for (run.groups.member_of[0..run.items.len], 0..) |member, i| {
            if (member != index) continue;
            const spec = run.items[i].spec;
            const last = spec.lines.first + (spec.lines.count - 1);
            var from: usize = 0;
            while (from < lines.len and lines[from].number < spec.lines.first) from += 1;
            var to = from;
            var text: u64 = 0;
            var own_cut = false;
            while (to < lines.len and lines[to].number <= last) : (to += 1) {
                text += lines[to].text.len;
                if (text > itemOutput(spec)) {
                    own_cut = true;
                    break;
                }
            }
            const covers_end = union_complete or (lines.len > 0 and lines[lines.len - 1].number >= last);
            if (own_cut and to == from) {
                decisions[i] = .{ .err = errorInfo(.E_OUTPUT_BUDGET) };
            } else if (!own_cut and !covers_end and (shared_short or to == from)) {
                decisions[i] = .{ .err = if (shared_short) shared_budget_error else merged_budget_error };
            } else {
                decisions[i] = .{ .lines = .{ .from = from, .to = to, .own_cut = own_cut, .covers_end = covers_end } };
                keep = @max(keep, to);
            }
        }

        // Copy the kept lines, their text and the path into the store.
        const kept = run.copyLines(lines[0..keep], job.path.bytes) catch {
            run.refuseMembers(index, errorInfo(.E_RESOURCE));
            run.output_pool += grant;
            return;
        };
        run.output_used += kept.text_len;
        run.output_pool += grant - kept.text_len;

        for (run.groups.member_of[0..run.items.len], 0..) |member, i| {
            if (member != index) continue;
            switch (decisions[i]) {
                .err => |info| {
                    run.outcomes[i] = .{ .err = info };
                    run.countRefusal(info);
                },
                .lines => |d| {
                    const truncated = d.own_cut or !d.covers_end;
                    const reasons = run.memberReasons(union_result.status.coverage.reasons, d.own_cut, truncated) catch {
                        run.outcomes[i] = .{ .err = errorInfo(.E_RESOURCE) };
                        run.resource_refused += 1;
                        continue;
                    };
                    run.outcomes[i] = .{ .ok = .{
                        .path = .{ .bytes = kept.path },
                        .lines = kept.lines[d.from..d.to],
                        .version = union_result.version,
                        .status = .{
                            .complete = !truncated,
                            .truncated = truncated,
                            .consistency = union_result.status.consistency,
                            .coverage = .{ .scope = kept.path, .skipped = 0, .index_state = union_result.status.coverage.index_state, .reasons = reasons },
                        },
                    } };
                },
            }
        }
    }

    const Kept = struct { lines: []Line, path: []const u8, text_len: u64 };

    fn copyLines(run: *Run, lines: []const Line, path: []const u8) Allocator.Error!Kept {
        const a = run.store.allocator();
        const text_len: usize = if (lines.len == 0) 0 else @intCast(lines[lines.len - 1].span.end - lines[0].span.start);
        const out = try a.alloc(Line, lines.len);
        const text = try a.alloc(u8, text_len);
        const path_copy = try a.dupe(u8, path);
        var offset: usize = 0;
        for (lines, out) |line, *copy| {
            @memcpy(text[offset..][0..line.text.len], line.text);
            copy.* = .{ .number = line.number, .span = line.span, .text = text[offset..][0..line.text.len] };
            offset += line.text.len;
        }
        return .{ .lines = out, .path = path_copy, .text_len = text_len };
    }

    /// Union reasons that still apply to a member, plus the member's own output cut.
    fn memberReasons(run: *Run, union_reasons: []const []const u8, own_cut: bool, truncated: bool) Allocator.Error![]const []const u8 {
        var reasons: [3][]const u8 = undefined;
        var count: usize = 0;
        if (own_cut) {
            reasons[count] = fs_read.reason_output_budget;
            count += 1;
        }
        for (union_reasons) |reason| {
            const is_stop = reason.ptr == fs_read.reason_output_budget.ptr or reason.ptr == fs_read.reason_reservation.ptr;
            if (is_stop and (!truncated or own_cut)) continue;
            reasons[count] = reason;
            count += 1;
        }
        if (count == 0) return &.{};
        return run.store.allocator().dupe([]const u8, reasons[0..count]);
    }
};
