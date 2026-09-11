//! T07 tests: batch read (BA-001..BA-003) through the I01 authorizer, I02
//! reservations and I03 reads, and the common compact output projection.
//!
//! Run: `zig build test -Dtest-group=batch`.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const admission = @import("zcr_admission");
const fs_read = @import("zcr_fs_read");
const batch = @import("zcr_batch");
const projection = @import("zcr_projection");

const testing = std.testing;
const io = testing.io;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const KiB = core.limits.KiB;
const MiB = core.limits.MiB;

const workspace: core.WorkspaceId = .{ .registry_uuid = @splat(0x11), .incarnation = @splat(0x22) };
const other_workspace: core.WorkspaceId = .{ .registry_uuid = @splat(0x11), .incarnation = @splat(0x99) };
const task: core.TaskId = .{ .uuid = @splat(0x33) };
const digest: core.PolicyDigest = @splat(0x44);

fn session() core.SessionContext {
    return .{
        .session_id = .{ .uuid = @splat(0x55) },
        .security_domain = .{ .id = 1 },
        .policy_digest = digest,
        .bound_workspace = workspace,
        .bound_task = task,
        .capability_handle = .none,
    };
}

const Harness = struct {
    arena: Allocator,
    tmp: testing.TmpDir,
    outside: testing.TmpDir,
    root: core.TrustedRoot,
    authorizer: policy.Authorizer,
    counters: memory.accounting.Counters = .{},
    budget: memory.Budget = undefined,
    reader: fs_read.Reader,
    batcher: batch.Batcher,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    fn init(arena: Allocator, caps: batch.Caps) !*Harness {
        const h = try arena.create(Harness);
        h.* = .{
            .arena = arena,
            .tmp = testing.tmpDir(.{}),
            .outside = testing.tmpDir(.{}),
            .root = undefined,
            .authorizer = undefined,
            .reader = undefined,
            .batcher = undefined,
        };
        const root_path = try h.tmp.dir.realPathFileAlloc(io, ".", arena);
        const dir = try Io.Dir.openDirAbsolute(io, root_path, .{});
        h.root = .{ .dir = dir, .canonical_path = root_path };
        h.authorizer = try policy.Authorizer.init(arena, io, h.root, workspace, task, .{
            .digest = digest,
            .state = .active,
            .read_paths = &.{.{ .bytes = "." }},
            .write_paths = &.{},
            .immutable_paths = &.{},
            .operations = &.{ .read, .batch_read },
            .max_changed_files = 1,
        }, .{ .git_dir = null, .common_dir = null });
        h.budget = memory.Budget.init(1, .{ .bytes = 512 * MiB, .fds = 128, .cpu = 4, .output_bytes = 64 * MiB }, &h.counters);
        h.reader = fs_read.Reader.init(h.root, workspace, 7);
        h.batcher = batch.Batcher.init(&h.authorizer, &h.reader, caps, .{ .requested = &h.cancel_flag });
        return h;
    }

    fn deinit(h: *Harness) void {
        h.root.dir.close(io);
        h.tmp.cleanup();
        h.outside.cleanup();
    }

    fn write(h: *Harness, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |parent| try h.tmp.dir.createDirPath(io, parent);
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    const Run = struct {
        owned: core.Owned(core.BatchResult),
        reservation: core.Reservation,
        counters: *memory.accounting.Counters,
        reserved: *memory.ReservedAllocator,

        fn items(r: *const Run) []const core.BatchItem {
            return r.owned.value.items;
        }
    };

    /// Reserves with `plannedCost` (optionally adjusted) and runs one batch.
    fn run(h: *Harness, items: []const core.BatchReadItem, output: u64, concurrency: u32) !Run {
        const cost = try batch.plannedCost(items, output, concurrency);
        return h.runWithCost(items, cost, null);
    }

    fn runWithCost(h: *Harness, items: []const core.BatchReadItem, cost: core.ResourceCost, fault: ?*memory.FaultPlan) !Run {
        var reservation = try h.budget.reserve(session(), cost);
        errdefer h.budget.release(&reservation) catch unreachable;
        const counters = try h.arena.create(memory.accounting.Counters);
        counters.* = .{};
        const reserved = try h.arena.create(memory.ReservedAllocator);
        reserved.* = memory.ReservedAllocator.init(testing.allocator, &reservation, counters, fault);
        const owned = try h.batcher.batchRead(io, reserved.allocator(), session(), items, &reservation);
        return .{ .owned = owned, .reservation = reservation, .counters = counters, .reserved = reserved };
    }

    /// Frees the result, then returns the reservation; nothing may remain tracked.
    fn finish(h: *Harness, r: *Run) !void {
        r.owned.deinit();
        try testing.expectEqual(@as(u64, 0), r.reserved.liveBytes());
        try h.budget.release(&r.reservation);
    }

    /// A batch that must fail leaves no tracked bytes and returns the reservation.
    fn expectBatchError(h: *Harness, expected: anyerror, context: core.SessionContext, items: []const core.BatchReadItem, cost: core.ResourceCost) !void {
        var reservation = try h.budget.reserve(session(), cost);
        var counters: memory.accounting.Counters = .{};
        var reserved = memory.ReservedAllocator.init(testing.allocator, &reservation, &counters, null);
        const result = h.batcher.batchRead(io, reserved.allocator(), context, items, &reservation);
        if (result) |ok| {
            var owned = ok;
            owned.deinit();
            try h.budget.release(&reservation);
            std.debug.print("expected {t}, batch succeeded\n", .{expected});
            return error.TestUnexpectedSuccess;
        } else |err| {
            try testing.expectEqual(expected, @as(anyerror, err));
        }
        try testing.expectEqual(@as(u64, 0), reserved.liveBytes());
        try h.budget.release(&reservation);
    }

    /// The same item read on its own through I01 and I03: the batch must match it.
    const Oracle = union(enum) {
        ok: struct { owned: core.Owned(core.ReadResult), reservation: core.Reservation },
        err: core.errors.Error,
    };

    fn oracle(h: *Harness, it: core.BatchReadItem) !Oracle {
        const capability = h.authorizer.authorize(io, session(), .read, it.spec.path) catch |err| return .{ .err = err };
        var cost = try admission.estimate(.{ .operation = .read, .frame_bytes = 1 * KiB, .output_bytes = it.spec.output_bytes });
        cost.scratch_bytes += 16 * MiB;
        var reservation = try h.budget.reserve(session(), cost);
        const owned = h.reader.readRange(io, h.arena, capability, it.spec, &reservation, h.cancel()) catch |err| {
            try h.budget.release(&reservation);
            return .{ .err = err };
        };
        return .{ .ok = .{ .owned = owned, .reservation = reservation } };
    }

    fn releaseOracle(h: *Harness, o: *Oracle) !void {
        switch (o.*) {
            .ok => |*ok| {
                ok.owned.deinit();
                try h.budget.release(&ok.reservation);
            },
            .err => {},
        }
    }

    fn cancel(h: *Harness) core.Cancel {
        return .{ .requested = &h.cancel_flag };
    }
};

fn item(id: []const u8, path: []const u8, first: u32, count: u32) core.BatchReadItem {
    return .{ .item_id = id, .spec = .{ .path = .{ .bytes = path }, .lines = .{ .first = first, .count = count } } };
}

fn expectSameItem(expected: Harness.Oracle, got: core.BatchItem) !void {
    switch (expected) {
        .err => |err| {
            const code = core.errors.wireCode(err);
            switch (got.result) {
                .ok => {
                    std.debug.print("item {s}: expected {t}, got a result\n", .{ got.item_id, code });
                    return error.TestExpectedEqual;
                },
                .err => |info| {
                    try testing.expectEqual(code, info.code);
                    try testing.expectEqual(core.errors.defaultRetryable(code), info.retryable);
                    try testing.expect(info.message.len > 0);
                },
            }
        },
        .ok => |ok| {
            const want = ok.owned.value;
            const r = switch (got.result) {
                .ok => |r| r,
                .err => |info| {
                    std.debug.print("item {s}: expected a result, got {t}\n", .{ got.item_id, info.code });
                    return error.TestExpectedEqual;
                },
            };
            try testing.expectEqualStrings(want.path.bytes, r.path.bytes);
            try testing.expectEqual(want.lines.len, r.lines.len);
            for (want.lines, r.lines) |a, b| {
                try testing.expectEqual(a.number, b.number);
                try testing.expectEqual(a.span, b.span);
                try testing.expectEqualStrings(a.text, b.text);
            }
            try testing.expectEqual(want.version.file_id, r.version.file_id);
            try testing.expectEqual(want.version.size, r.version.size);
            try testing.expectEqual(want.version.generation, r.version.generation);
            try testing.expectEqual(want.version.sha256, r.version.sha256);
            try testing.expect(want.version.workspace_id.eql(r.version.workspace_id));
            try testing.expectEqual(want.status.complete, r.status.complete);
            try testing.expectEqual(want.status.truncated, r.status.truncated);
            try testing.expectEqual(want.status.consistency, r.status.consistency);
            try testing.expectEqualStrings(want.status.coverage.scope, r.status.coverage.scope);
            try testing.expectEqual(want.status.coverage.reasons.len, r.status.coverage.reasons.len);
            for (want.status.coverage.reasons, r.status.coverage.reasons) |a, b| try testing.expectEqualStrings(a, b);
        },
    }
}

fn textBytes(result: core.ReadResult) u64 {
    var total: u64 = 0;
    for (result.lines) |line| total += line.text.len;
    return total;
}

fn openFdCount() !usize {
    if (builtin.os.tag != .macos) return 0;
    var dir = try Io.Dir.openDirAbsolute(io, "/dev/fd", .{ .iterate = true });
    defer dir.close(io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |_| count += 1;
    return count;
}

// ------------------------------------------------------------------ BA-001

/// 32 items: distinct ranges, an exact duplicate, overlapping ranges, missing
/// files, a directory, write intent, EOF edges, CRLF, invalid UTF-8 and small
/// per-item output caps.
fn ba001Items(h: *Harness) ![32]core.BatchReadItem {
    for (0..20) |i| {
        var text: std.ArrayList(u8) = .empty;
        for (1..31) |l| try text.print(h.arena, "f{d:0>2} line {d}\n", .{ i, l });
        try h.write(try std.fmt.allocPrint(h.arena, "f{d:0>2}.txt", .{i}), text.items);
    }
    try h.tmp.dir.createDirPath(io, "dir");
    try h.write("crlf.txt", "a\r\nb\r\nc\r\n");
    try h.write("bad.bin", "ok\n\xff\xfe\n");

    var items: [32]core.BatchReadItem = undefined;
    for (0..20) |i| {
        const path = try std.fmt.allocPrint(h.arena, "f{d:0>2}.txt", .{i});
        const id = try std.fmt.allocPrint(h.arena, "item-{d}", .{i});
        items[i] = item(id, path, @intCast(1 + i % 5), @intCast(3 + i % 7));
    }
    items[20] = items[3];
    items[20].item_id = try h.arena.dupe(u8, "dup-3");
    items[21] = item("overlap-3", "f03.txt", 5, 11);
    items[22] = item("missing", "nope.txt", 1, 10);
    items[23] = item("directory", "dir", 1, 10);
    items[24] = item("hash-5", "f05.txt", 1, 2);
    items[24].spec.write_intent = true;
    items[25] = item("tail-19", "f19.txt", 25, 20);
    items[26] = item("past-eof-7", "f07.txt", 100, 10);
    items[27] = item("crlf", "crlf.txt", 1, 3);
    items[28] = item("invalid-utf8", "bad.bin", 1, 2);
    items[29] = item("missing-again", "nope.txt", 1, 5);
    items[30] = item("tiny-output", "f00.txt", 1, 1);
    items[30].spec.output_bytes = 5;
    items[31] = item("truncated-1", "f01.txt", 1, 30);
    items[31].spec.output_bytes = 50;
    return items;
}

test "BA-001 32 items keep input order, item ids and per-item errors, and match single reads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{ .max_concurrency = 4 });
    defer h.deinit();
    var items = try ba001Items(h);

    var oracles: [32]Harness.Oracle = undefined;
    for (items, 0..) |it, i| oracles[i] = try h.oracle(it);
    defer for (&oracles) |*o| h.releaseOracle(o) catch {};

    // Item ids must be copied: the caller's buffers can change after the call.
    var ids: [32][]u8 = undefined;
    for (&items, 0..) |*it, i| {
        ids[i] = try h.arena.dupe(u8, it.item_id);
        it.item_id = ids[i];
    }

    const fds_before = try openFdCount();
    var r = try h.run(&items, 1 * MiB, 4);
    for (ids) |id| @memset(id, 'X');
    // Result bytes must be copied too.
    try h.write("f03.txt", "rewritten\n");

    try testing.expectEqual(@as(usize, 32), r.items().len);
    const expected_ids = [_][]const u8{
        "item-0",  "item-1",  "item-2",  "item-3",  "item-4",  "item-5",     "item-6",    "item-7",
        "item-8",  "item-9",  "item-10", "item-11", "item-12", "item-13",    "item-14",   "item-15",
        "item-16", "item-17", "item-18", "item-19", "dup-3",   "overlap-3",  "missing",   "directory",
        "hash-5",  "tail-19", "past-eof-7", "crlf", "invalid-utf8", "missing-again", "tiny-output", "truncated-1",
    };
    for (r.items(), expected_ids, oracles) |got, id, o| {
        try testing.expectEqualStrings(id, got.item_id);
        try expectSameItem(o, got);
    }

    // Spot checks on the oracle itself, so a broken reader cannot hide a broken batch.
    try testing.expectEqual(core.errors.WireCode.E_NOT_FOUND, r.items()[22].result.err.code);
    try testing.expectEqual(core.errors.WireCode.E_NOT_REGULAR, r.items()[23].result.err.code);
    try testing.expectEqual(core.errors.WireCode.E_UNSUPPORTED, r.items()[28].result.err.code);
    try testing.expectEqual(core.errors.WireCode.E_OUTPUT_BUDGET, r.items()[30].result.err.code);
    try testing.expect(r.items()[24].result.ok.version.sha256 != null);
    try testing.expectEqual(@as(usize, 0), r.items()[26].result.ok.lines.len);
    try testing.expect(r.items()[31].result.ok.status.truncated);
    try testing.expectEqual(@as(usize, 6), r.items()[25].result.ok.lines.len);
    try testing.expectEqualStrings("f03 line 4\n", r.items()[3].result.ok.lines[0].text);

    const status = r.owned.value.status;
    try testing.expect(!status.complete);
    try testing.expect(status.truncated);
    try testing.expectEqual(core.Consistency.checked_live, status.consistency);
    try testing.expectEqual(@as(u64, 5), status.coverage.skipped);

    const rep = h.batcher.report();
    try testing.expectEqual(@as(u32, 32), rep.items);
    try testing.expectEqual(@as(u32, 1), rep.deduplicated);
    try testing.expectEqual(@as(u32, 3), rep.merged);
    try testing.expectEqual(@as(u32, 25), rep.jobs);
    try testing.expectEqual(@as(u32, 5), rep.item_errors);
    try testing.expect(rep.peak_running <= 4);

    try h.finish(&r);
    try testing.expectEqual(fds_before, try openFdCount());
}

test "BA-001 results do not depend on how many items run at once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{ .max_concurrency = 1 });
    defer h.deinit();
    const items = try ba001Items(h);

    var serial = try h.run(&items, 1 * MiB, 1);
    try testing.expectEqual(@as(u32, 1), h.batcher.report().peak_running);
    h.batcher.caps.max_concurrency = 8;
    var parallel = try h.run(&items, 1 * MiB, 8);
    try testing.expect(h.batcher.report().peak_running <= 8);

    for (serial.items(), parallel.items()) |a, b| {
        try testing.expectEqualStrings(a.item_id, b.item_id);
        try testing.expectEqual(std.meta.activeTag(a.result), std.meta.activeTag(b.result));
        switch (a.result) {
            .ok => |ra| {
                const rb = b.result.ok;
                try testing.expectEqual(ra.lines.len, rb.lines.len);
                for (ra.lines, rb.lines) |la, lb| try testing.expectEqualStrings(la.text, lb.text);
            },
            .err => |ea| try testing.expectEqual(ea.code, b.result.err.code),
        }
    }
    try h.finish(&serial);
    try h.finish(&parallel);
}

// ------------------------------------------------------------------ BA-002

test "BA-002 more than 32 items, bad item ids and another workspace are refused before any read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    try h.write("a.txt", "alpha\n");

    var many: [33]core.BatchReadItem = undefined;
    for (&many, 0..) |*it, i| it.* = item(try std.fmt.allocPrint(h.arena, "i{d}", .{i}), "a.txt", 1, 1);
    const cost = try batch.plannedCost(many[0..32], 64 * KiB, 2);

    try h.expectBatchError(error.InvalidArgument, session(), &many, cost);
    try h.expectBatchError(error.InvalidArgument, session(), many[0..0], cost);
    try testing.expectError(error.InvalidArgument, batch.plannedCost(&many, 64 * KiB, 2));

    var empty_id = [_]core.BatchReadItem{item("", "a.txt", 1, 1)};
    try h.expectBatchError(error.InvalidArgument, session(), &empty_id, cost);
    var long_id = [_]core.BatchReadItem{item("x" ** 65, "a.txt", 1, 1)};
    try h.expectBatchError(error.InvalidArgument, session(), &long_id, cost);
    var duplicate_ids = [_]core.BatchReadItem{ item("same", "a.txt", 1, 1), item("same", "a.txt", 1, 1) };
    try h.expectBatchError(error.InvalidArgument, session(), &duplicate_ids, cost);
    var bad_range = [_]core.BatchReadItem{item("zero", "a.txt", 0, 1)};
    try h.expectBatchError(error.InvalidArgument, session(), &bad_range, cost);

    // A session bound to a different workspace cannot use this workspace's batcher.
    var other = session();
    other.bound_workspace = other_workspace;
    var one = [_]core.BatchReadItem{item("one", "a.txt", 1, 1)};
    try h.expectBatchError(error.OutOfScope, other, &one, cost);

    // A released reservation is not a grant.
    var reservation = try h.budget.reserve(session(), cost);
    try h.budget.release(&reservation);
    var counters: memory.accounting.Counters = .{};
    var reserved = memory.ReservedAllocator.init(testing.allocator, &reservation, &counters, null);
    try testing.expectError(error.ResourceExhausted, h.batcher.batchRead(io, reserved.allocator(), session(), &one, &reservation));
    try testing.expectEqual(@as(u64, 0), counters.allocations.load(.monotonic));
}

test "BA-002 paths that leave the root fail only their own item" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    try h.write("a.txt", "alpha\nbeta\n");
    try h.outside.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "other workspace\n" });
    const outside_path = try h.outside.dir.realPathFileAlloc(io, "secret.txt", h.arena);
    try h.tmp.dir.symLink(io, outside_path, "link.txt", .{});
    const outside_root = try h.outside.dir.realPathFileAlloc(io, ".", h.arena);
    try h.tmp.dir.symLink(io, outside_root, "linkdir", .{ .is_directory = true });

    const items = [_]core.BatchReadItem{
        item("ok-first", "a.txt", 1, 2),
        item("dotdot", "../secret.txt", 1, 1),
        item("absolute", outside_path, 1, 1),
        item("symlink", "link.txt", 1, 1),
        item("symlink-dir", "linkdir/secret.txt", 1, 1),
        item("inner-dotdot", "sub/../a.txt", 1, 1),
        item("ok-last", "a.txt", 2, 1),
    };
    var r = try h.run(&items, 64 * KiB, 2);
    const got = r.items();
    try testing.expectEqual(@as(usize, 7), got.len);
    try testing.expectEqualStrings("alpha\n", got[0].result.ok.lines[0].text);
    for (got[1..6]) |g| {
        try testing.expectEqual(core.errors.WireCode.E_PATH_ESCAPE, g.result.err.code);
        try testing.expect(!g.result.err.retryable);
    }
    try testing.expectEqualStrings("beta\n", got[6].result.ok.lines[0].text);
    for (got) |g| switch (g.result) {
        .ok => |res| for (res.lines) |line| try testing.expect(std.mem.indexOf(u8, line.text, "other workspace") == null),
        .err => {},
    };
    try h.finish(&r);
}

// ------------------------------------------------------------------ BA-003

const Running = struct {
    current: std.atomic.Value(u32) = .init(0),
    peak: std.atomic.Value(u32) = .init(0),
    starts: std.atomic.Value(u32) = .init(0),
    cancel_on_start: ?*std.atomic.Value(bool) = null,

    fn onJob(context: ?*anyopaque, event: batch.JobEvent) void {
        const self: *Running = @ptrCast(@alignCast(context.?));
        if (event.started) {
            _ = self.starts.fetchAdd(1, .monotonic);
            const now = self.current.fetchAdd(1, .monotonic) + 1;
            var peak = self.peak.load(.monotonic);
            while (now > peak) peak = self.peak.cmpxchgWeak(peak, now, .monotonic, .monotonic) orelse break;
            if (self.cancel_on_start) |flag| flag.store(true, .release);
        } else {
            _ = self.current.fetchSub(1, .monotonic);
        }
    }
};

const big_lines = 180;
const big_line_bytes = 1400;
const big_file_bytes = big_lines * big_line_bytes;

fn ba003Items(h: *Harness) ![32]core.BatchReadItem {
    var items: [32]core.BatchReadItem = undefined;
    const content = try h.arena.alloc(u8, big_file_bytes);
    for (0..32) |i| {
        for (0..big_lines) |l| {
            const line = content[l * big_line_bytes ..][0..big_line_bytes];
            @memset(line, 'a' + @as(u8, @intCast(i % 26)));
            line[big_line_bytes - 1] = '\n';
        }
        const path = try std.fmt.allocPrint(h.arena, "big/f{d:0>2}.txt", .{i});
        try h.write(path, content);
        items[i] = item(try std.fmt.allocPrint(h.arena, "big-{d}", .{i}), path, 1, big_lines);
        items[i].spec.output_bytes = 256 * KiB;
    }
    return items;
}

test "BA-003 32 items asking for 8 MiB share a 2 MiB output cap under a small group budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{ .max_concurrency = 32 });
    defer h.deinit();
    const items = try ba003Items(h);

    var running: Running = .{};
    var fault: batch.BatchFault = .{ .on_job = Running.onJob, .context = &running };
    h.batcher.fault = &fault;

    // Room for the result store and two full items; handles do not limit it.
    const output = core.limits.values.max_output_bytes;
    var cost = try batch.plannedCost(&items, output, 2);
    cost.fds = 32;
    var r = try h.runWithCost(&items, cost, null);

    const rep = h.batcher.report();
    const pool = r.reservation.bytes - rep.store_bytes;
    try testing.expect(rep.peak_running >= 1);
    try testing.expect(rep.peak_running <= pool / core.limits.values.chunk_bytes);
    try testing.expect(rep.peak_running < 32);
    try testing.expectEqual(rep.peak_running, running.peak.load(.monotonic));
    try testing.expect(r.counters.peak_live_bytes.load(.monotonic) <= r.reservation.bytes);
    try testing.expect(r.counters.peak_live_bytes.load(.monotonic) < 32 * big_file_bytes);

    var ok_text: u64 = 0;
    var ok_items: u32 = 0;
    var refused: u32 = 0;
    for (r.items(), items) |got, it| {
        try testing.expectEqualStrings(it.item_id, got.item_id);
        switch (got.result) {
            .ok => |res| {
                try testing.expect(res.status.complete);
                try testing.expectEqual(@as(usize, big_lines), res.lines.len);
                ok_text += textBytes(res);
                ok_items += 1;
            },
            .err => |info| {
                try testing.expectEqual(core.errors.WireCode.E_OUTPUT_BUDGET, info.code);
                try testing.expect(!info.retryable);
                refused += 1;
            },
        }
    }
    // Earlier items get the budget first: 8 whole items fit in 2 MiB, the rest are refused.
    try testing.expectEqual(@as(u32, 8), ok_items);
    for (r.items()[0..8]) |got| try testing.expect(got.result == .ok);
    try testing.expectEqual(@as(u32, 24), refused);
    try testing.expect(ok_text <= output);
    try testing.expectEqual(ok_text, rep.output_used);
    try testing.expectEqual(@as(u32, 24), rep.output_refused);
    try testing.expectEqual(@as(u32, 0), rep.resource_refused);

    const status = r.owned.value.status;
    try testing.expect(status.truncated);
    try testing.expect(!status.complete);
    try testing.expect(status.coverage.reasons.len > 0);
    try h.finish(&r);
}

test "BA-003 a reservation without room for the store or any item is refused honestly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{ .max_concurrency = 32 });
    defer h.deinit();
    const items = try ba003Items(h);
    const output = core.limits.values.max_output_bytes;
    const store = batch.storeCharge(&items, output);

    // The output text lives in the store, so the reservation's output bytes are part of its charge.
    // Not even the result store fits: the whole batch is refused and nothing stays allocated.
    try h.expectBatchError(error.ResourceExhausted, session(), &items, .{ .scratch_bytes = store -| (1 + output), .output_bytes = output, .fds = 32 });

    // The store fits but no single item does: every item says so, retryably.
    var r = try h.runWithCost(&items, .{ .scratch_bytes = (store + core.limits.values.chunk_bytes / 2) -| output, .output_bytes = output, .fds = 32 }, null);
    for (r.items()) |got| {
        try testing.expectEqual(core.errors.WireCode.E_RESOURCE, got.result.err.code);
        try testing.expect(got.result.err.retryable);
    }
    try testing.expectEqual(@as(u32, 32), h.batcher.report().resource_refused);
    try testing.expect(!r.owned.value.status.complete);
    try h.finish(&r);
}

// ------------------------------------------------------------------ failure paths

test "T07 cancellation during a batch returns Cancelled after every job has stopped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{ .max_concurrency = 2 });
    defer h.deinit();
    const items = try ba003Items(h);

    var running: Running = .{ .cancel_on_start = &h.cancel_flag };
    var fault: batch.BatchFault = .{ .on_job = Running.onJob, .context = &running };
    h.batcher.fault = &fault;
    const fds_before = try openFdCount();
    try h.expectBatchError(error.Cancelled, session(), &items, try batch.plannedCost(&items, 2 * MiB, 2));
    try testing.expectEqual(@as(u32, 0), running.current.load(.monotonic));
    try testing.expect(running.starts.load(.monotonic) < 32);
    try testing.expectEqual(fds_before, try openFdCount());
    h.cancel_flag.store(false, .release);
}

const Changer = struct {
    h: *Harness,
    flip: bool = false,

    fn afterOpen(context: ?*anyopaque, attempt: u32) void {
        _ = attempt;
        const self: *Changer = @ptrCast(@alignCast(context.?));
        self.flip = !self.flip;
        self.h.write("changing.txt", if (self.flip) "one\ntwo\nthree\n" else "one\n") catch unreachable;
    }
};

test "T07 a file that keeps changing fails its item with a version conflict, others succeed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{ .max_concurrency = 1 });
    defer h.deinit();
    try h.write("stable.txt", "s1\ns2\n");
    try h.write("changing.txt", "one\n");
    try h.write("stable2.txt", "t1\n");

    var changer: Changer = .{ .h = h };
    var read_fault: fs_read.ReadFault = .{ .after_open = Changer.afterOpen, .context = &changer };
    h.reader.fault = &read_fault;
    defer h.reader.fault = null;

    const items = [_]core.BatchReadItem{ item("s", "stable.txt", 1, 2), item("c", "changing.txt", 1, 3), item("t", "stable2.txt", 1, 1) };
    var r = try h.run(&items, 64 * KiB, 1);
    try testing.expectEqual(@as(usize, 2), r.items()[0].result.ok.lines.len);
    try testing.expectEqual(core.errors.WireCode.E_VERSION_CONFLICT, r.items()[1].result.err.code);
    try testing.expectEqualStrings("t1\n", r.items()[2].result.ok.lines[0].text);
    try h.finish(&r);
}

test "T07 an allocation failure at any point fails an item or the batch and leaks nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{ .max_concurrency = 1 });
    defer h.deinit();
    var items: [6]core.BatchReadItem = undefined;
    for (&items, 0..) |*it, i| {
        const path = try std.fmt.allocPrint(h.arena, "s{d}.txt", .{i});
        try h.write(path, "line one\nline two\n");
        it.* = item(try std.fmt.allocPrint(h.arena, "s{d}", .{i}), path, 1, 2);
    }
    const cost = try batch.plannedCost(&items, 64 * KiB, 1);

    var clean_run = false;
    var fail_at: u64 = 1;
    while (fail_at < 200 and !clean_run) : (fail_at += 1) {
        var plan: memory.FaultPlan = .{ .fail_at = fail_at };
        var r = h.runWithCost(&items, cost, &plan) catch |err| {
            try testing.expect(err == error.OutOfMemory or err == error.ResourceExhausted);
            try testing.expectEqual(@as(u64, 1), plan.injected.load(.monotonic));
            continue;
        };
        var resource_errors: u32 = 0;
        for (r.items()) |got| switch (got.result) {
            .ok => |res| try testing.expectEqual(@as(usize, 2), res.lines.len),
            .err => |info| {
                try testing.expectEqual(core.errors.WireCode.E_RESOURCE, info.code);
                resource_errors += 1;
            },
        };
        clean_run = plan.injected.load(.monotonic) == 0;
        if (!clean_run) try testing.expectEqual(@as(u32, 1), resource_errors);
        try h.finish(&r);
    }
    try testing.expect(clean_run);
}

test "T07 batch contracts" {
    comptime core.conforms(core.BatchReadFn(batch.Batcher), batch.Batcher.batchRead);
    try testing.expectEqual(@as(usize, 64), batch.max_item_id_bytes);
    try testing.expectEqual(@as(u32, 32), core.limits.values.max_batch_items);
}

// ------------------------------------------------------------------ projection

const envelope: projection.Envelope = .{ .request_id = "req-1", .workspace_id = workspace, .generation = 7 };
const workspace_hex = "11111111111111111111111111111111:22222222222222222222222222222222";

fn version(size: u64) core.FileVersion {
    return .{ .workspace_id = workspace, .file_id = .{ .device = 1, .inode = 2 }, .generation = 7, .size = size, .mtime_ns = 0, .sha256 = null };
}

fn liveStatus(scope: []const u8) core.ResultStatus {
    return .{ .complete = true, .truncated = false, .consistency = .checked_live, .coverage = .{ .scope = scope, .skipped = 0, .index_state = .live } };
}

fn linesOf(arena: Allocator, text: []const u8) ![]core.Line {
    var out: std.ArrayList(core.Line) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| nl + 1 else text.len;
        try out.append(arena, .{ .number = @intCast(out.items.len + 1), .span = .{ .start = start, .end = end }, .text = text[start..end] });
        start = end;
    }
    return out.items;
}

/// The serialized `data` member of a response, found from the end so that escaped text cannot fool it.
fn dataSlice(bytes: []const u8) []const u8 {
    const begin = std.mem.indexOf(u8, bytes, ",\"data\":").? + 8;
    const end = std.mem.lastIndexOf(u8, bytes, ",\"error\":").?;
    return bytes[begin..end];
}

fn parse(arena: Allocator, bytes: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
}

fn project(arena: Allocator, env: projection.Envelope, data: projection.Data, status: core.ResultStatus, output: u64) !projection.Response {
    const buffer = try arena.alloc(u8, @intCast(projection.bufferBytes(env, status, output)));
    return projection.success(buffer, env, data, status, output);
}

test "T07 projection writes compact read data with exact offsets and the zcr/1 envelope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "alpha\nbeta\n";
    const result: core.ReadResult = .{ .path = .{ .bytes = "a.txt" }, .lines = try linesOf(arena, text), .version = version(11), .status = liveStatus("a.txt") };

    const response = try project(arena, envelope, .{ .read = result }, result.status, 256 * KiB);
    const data =
        \\{"path":"a.txt","lines":[{"number":1,"start":0,"end":6,"text":"alpha\n"},{"number":2,"start":6,"end":11,"text":"beta\n"}],"version":{"size":11,"file_id":"1:2","sha256":null}}
    ;
    const expected = "{\"schema_version\":\"zcr/1\",\"request_id\":\"req-1\",\"workspace_id\":\"" ++ workspace_hex ++
        "\",\"generation\":7,\"ok\":true,\"complete\":true,\"truncated\":false,\"consistency\":\"checked_live\"," ++
        "\"coverage\":{\"scope\":\"a.txt\",\"skipped\":0,\"index_state\":\"live\"},\"data\":" ++ data ++
        ",\"error\":null,\"meta\":{\"returned_bytes\":" ++ std.fmt.comptimePrint("{d}", .{data.len}) ++ "}}";
    try testing.expectEqualStrings(expected, response.bytes);
    try testing.expectEqual(@as(u64, data.len), response.returned_bytes);
    try testing.expect(response.ok and response.complete and !response.truncated);
    try testing.expectEqual(@as(u32, 0), response.omitted);

    var with_digest = result;
    with_digest.version.sha256 = @splat(0xab);
    const hashed = try project(arena, .{ .request_id = "r", .elapsed_us = 120, .cache = .miss }, .{ .read = with_digest }, result.status, 256 * KiB);
    const root = try parse(arena, hashed.bytes);
    try testing.expectEqualStrings("ab" ** 32, root.object.get("data").?.object.get("version").?.object.get("sha256").?.string);
    try testing.expect(root.object.get("workspace_id").? == .null);
    try testing.expect(root.object.get("generation").? == .null);
    try testing.expectEqual(@as(i64, 120), root.object.get("meta").?.object.get("elapsed_us").?.integer);
    try testing.expectEqualStrings("miss", root.object.get("meta").?.object.get("cache").?.string);
}

test "T07 projection escapes JSON text and keeps bytes, CR and non-ASCII exact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "q\"b\\s\tt\r\n\x01\x1f\x7f/한글\n";
    const result: core.ReadResult = .{ .path = .{ .bytes = "dir/\"odd\".txt" }, .lines = try linesOf(arena, text), .version = version(text.len), .status = liveStatus("dir") };
    const response = try project(arena, envelope, .{ .read = result }, result.status, 256 * KiB);

    try testing.expect(std.mem.indexOf(u8, response.bytes, "\\u0001\\u001f") != null);
    try testing.expect(std.mem.indexOf(u8, response.bytes, "한글") != null);
    const root = try parse(arena, response.bytes);
    const data = root.object.get("data").?.object;
    try testing.expectEqualStrings("dir/\"odd\".txt", data.get("path").?.string);
    const lines = data.get("lines").?.array.items;
    try testing.expectEqual(result.lines.len, lines.len);
    for (result.lines, lines) |want, got| {
        try testing.expectEqualStrings(want.text, got.object.get("text").?.string);
        try testing.expectEqual(@as(i64, @intCast(want.span.start)), got.object.get("start").?.integer);
        try testing.expectEqual(@as(i64, @intCast(want.span.end)), got.object.get("end").?.integer);
    }
    try testing.expectEqual(@as(u64, dataSlice(response.bytes).len), response.returned_bytes);
    try testing.expectEqual(@as(i64, @intCast(response.returned_bytes)), root.object.get("meta").?.object.get("returned_bytes").?.integer);
}

test "T07 projection keeps whole lines within output_bytes and says the result is truncated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (1..101) |l| try text.print(arena, "line number {d} with some text\n", .{l});
    const result: core.ReadResult = .{ .path = .{ .bytes = "long.txt" }, .lines = try linesOf(arena, text.items), .version = version(text.items.len), .status = liveStatus("long.txt") };

    const budget = 2 * KiB;
    const response = try project(arena, envelope, .{ .read = result }, result.status, budget);
    try testing.expect(response.returned_bytes <= budget);
    try testing.expectEqual(@as(u64, dataSlice(response.bytes).len), response.returned_bytes);
    try testing.expect(response.truncated and !response.complete and response.ok);
    const root = try parse(arena, response.bytes);
    try testing.expect(root.object.get("truncated").?.bool);
    try testing.expect(!root.object.get("complete").?.bool);
    const kept = root.object.get("data").?.object.get("lines").?.array.items;
    try testing.expect(kept.len > 0 and kept.len < 100);
    try testing.expectEqual(@as(u32, @intCast(100 - kept.len)), response.omitted);
    for (kept, 0..) |line, i| try testing.expectEqualStrings(result.lines[i].text, line.object.get("text").?.string);
    const reasons = root.object.get("coverage").?.object.get("reasons").?.array.items;
    try testing.expectEqualStrings(projection.reason_output_budget, reasons[reasons.len - 1].string);

    // One more byte of budget never loses a line; a budget below the first line is an error.
    const wider = try project(arena, envelope, .{ .read = result }, result.status, budget + 64);
    try testing.expect(wider.omitted <= response.omitted);
    try testing.expectError(error.OutputBudgetExceeded, project(arena, envelope, .{ .read = result }, result.status, 60));

    const info: core.errors.ErrorInfo = .{ .code = .E_OUTPUT_BUDGET, .message = "first line exceeds output_bytes", .retryable = false };
    const buffer = try arena.alloc(u8, @intCast(projection.failureBufferBytes(envelope, info)));
    const failed = try projection.failure(buffer, envelope, info);
    const failed_root = try parse(arena, failed.bytes);
    try testing.expect(!failed_root.object.get("ok").?.bool);
    try testing.expect(!failed.ok and !failed.complete and !failed.truncated);
    try testing.expectEqualStrings("E_OUTPUT_BUDGET", failed_root.object.get("error").?.object.get("code").?.string);
    try testing.expectEqualStrings("not_applicable", failed_root.object.get("consistency").?.string);
    try testing.expectEqual(@as(u64, 2), failed.returned_bytes);
}

test "T07 batch projection keeps every item id in order and marks items that do not fit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const small: core.ReadResult = .{ .path = .{ .bytes = "s.txt" }, .lines = try linesOf(arena, "tiny\n"), .version = version(5), .status = liveStatus("s.txt") };
    const big_text = try arena.alloc(u8, 3000);
    @memset(big_text, 'z');
    big_text[big_text.len - 1] = '\n';
    const big: core.ReadResult = .{ .path = .{ .bytes = "b.txt" }, .lines = try linesOf(arena, big_text), .version = version(3000), .status = liveStatus("b.txt") };
    const missing: core.errors.ErrorInfo = .{ .code = .E_NOT_FOUND, .message = "file not found", .retryable = false };
    const items = [_]core.BatchItem{
        .{ .item_id = "a", .result = .{ .ok = small } },
        .{ .item_id = "b", .result = .{ .err = missing } },
        .{ .item_id = "c", .result = .{ .ok = big } },
        .{ .item_id = "d", .result = .{ .ok = small } },
        .{ .item_id = "e", .result = .{ .ok = big } },
    };
    const value: core.BatchResult = .{ .items = &items, .status = .{ .complete = false, .truncated = false, .consistency = .checked_live, .coverage = .{ .scope = "requested_files", .skipped = 1, .index_state = .live } } };

    const budget = 2 * KiB;
    const response = try project(arena, envelope, .{ .batch_read = value }, value.status, budget);
    try testing.expect(response.returned_bytes <= budget);
    try testing.expectEqual(@as(u64, dataSlice(response.bytes).len), response.returned_bytes);
    try testing.expect(response.truncated and !response.complete);
    try testing.expectEqual(@as(u32, 2), response.omitted);

    const root = try parse(arena, response.bytes);
    const got = root.object.get("data").?.object.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 5), got.len);
    const ids = [_][]const u8{ "a", "b", "c", "d", "e" };
    const oks = [_]bool{ true, false, false, true, false };
    const codes = [_]?[]const u8{ null, "E_NOT_FOUND", "E_OUTPUT_BUDGET", null, "E_OUTPUT_BUDGET" };
    for (got, ids, oks, codes) |g, id, ok, code| {
        const obj = g.object;
        try testing.expectEqualStrings(id, obj.get("item_id").?.string);
        try testing.expectEqual(ok, obj.get("ok").?.bool);
        if (code) |c| {
            try testing.expect(obj.get("data").? == .null);
            try testing.expectEqualStrings(c, obj.get("error").?.object.get("code").?.string);
        } else {
            try testing.expect(obj.get("error").? == .null);
            try testing.expectEqualStrings("tiny\n", obj.get("data").?.object.get("lines").?.array.items[0].object.get("text").?.string);
        }
    }

    // A budget too small for even the error forms of all items is refused.
    try testing.expectError(error.OutputBudgetExceeded, project(arena, envelope, .{ .batch_read = value }, value.status, 100));
}

test "T07 files and search projection keep whole entries within output_bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var paths: [200]core.RelativePath = undefined;
    for (&paths, 0..) |*p, i| p.* = .{ .bytes = try std.fmt.allocPrint(arena, "src/module_{d:0>3}.zig", .{i}) };
    const files_status = liveStatus(".");
    const files = try project(arena, envelope, .{ .files = .{ .paths = &paths, .order = .path_then_offset } }, files_status, 1 * KiB);
    try testing.expect(files.returned_bytes <= 1 * KiB and files.truncated);
    const files_root = try parse(arena, files.bytes);
    const kept = files_root.object.get("data").?.object.get("paths").?.array.items;
    try testing.expectEqual(@as(u32, @intCast(200 - kept.len)), files.omitted);
    for (kept, 0..) |p, i| try testing.expectEqualStrings(paths[i].bytes, p.string);
    try testing.expectEqualStrings("path_then_offset", files_root.object.get("data").?.object.get("order").?.string);

    const context_lines = try linesOf(arena, "before\nneedle here\nafter\n");
    var results: [20]core.SearchFileResult = undefined;
    const matches = [_]core.SearchMatch{.{ .span = .{ .start = 7, .end = 13 }, .line = 2 }};
    for (&results, 0..) |*res, i| res.* = .{ .path = .{ .bytes = try std.fmt.allocPrint(arena, "f{d}.txt", .{i}) }, .matches = &matches, .context = context_lines, .version = version(26) };
    const search = try project(arena, envelope, .{ .search = .{ .files = &results, .order = .discovery } }, liveStatus("."), 1 * KiB);
    try testing.expect(search.returned_bytes <= 1 * KiB and search.truncated);
    const search_root = try parse(arena, search.bytes);
    const got = search_root.object.get("data").?.object.get("files").?.array.items;
    try testing.expect(got.len > 0 and got.len < 20);
    try testing.expectEqual(@as(i64, 7), got[0].object.get("matches").?.array.items[0].object.get("start").?.integer);
    try testing.expectEqualStrings("needle here\n", got[0].object.get("context").?.array.items[1].object.get("text").?.string);

    const all = try project(arena, envelope, .{ .search = .{ .files = &results, .order = .discovery } }, liveStatus("."), 256 * KiB);
    try testing.expect(!all.truncated and all.complete and all.omitted == 0);
}

test "T07 projection refuses a bad envelope and a buffer that is too small" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result: core.ReadResult = .{ .path = .{ .bytes = "a.txt" }, .lines = try linesOf(arena, "x\n"), .version = version(2), .status = liveStatus("a.txt") };
    try testing.expectError(error.InvalidArgument, project(arena, .{ .request_id = "" }, .{ .read = result }, result.status, 1 * KiB));
    try testing.expectError(error.InvalidArgument, project(arena, .{ .request_id = "r" ** 257 }, .{ .read = result }, result.status, 1 * KiB));
    try testing.expectError(error.InvalidArgument, project(arena, envelope, .{ .read = result }, result.status, core.limits.values.max_output_bytes + 1));
    var tiny: [16]u8 = undefined;
    try testing.expectError(error.InvalidArgument, projection.success(&tiny, envelope, .{ .read = result }, result.status, 1 * KiB));

    // A status that claims completeness with truncation is written as incomplete.
    var odd = result.status;
    odd.truncated = true;
    const response = try project(arena, envelope, .{ .read = result }, odd, 1 * KiB);
    try testing.expect(!response.complete and response.truncated);
}

test "T07 a real batch result projects within its output budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    const items = try ba001Items(h);
    var r = try h.run(&items, 1 * MiB, 4);
    defer h.finish(&r) catch unreachable;

    const response = try project(h.arena, envelope, .{ .batch_read = r.owned.value }, r.owned.value.status, 256 * KiB);
    try testing.expect(response.returned_bytes <= 256 * KiB);
    const root = try parse(h.arena, response.bytes);
    const got = root.object.get("data").?.object.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 32), got.len);
    for (got, r.items()) |g, want| {
        try testing.expectEqualStrings(want.item_id, g.object.get("item_id").?.string);
        try testing.expectEqual(want.result == .ok, g.object.get("ok").?.bool);
    }
    try testing.expectEqual(@as(u64, 5), @as(u64, @intCast(root.object.get("coverage").?.object.get("skipped").?.integer)));

    // Samples for schema validation outside Zig (S04): set ZCR_T07_SAMPLES to a directory.
    var env = try testing.environ.createMap(h.arena);
    if (env.get("ZCR_T07_SAMPLES")) |dir_path| {
        var dir = try Io.Dir.openDirAbsolute(io, dir_path, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "batch_read.json", .data = response.bytes });
        const read_response = try project(h.arena, envelope, .{ .read = r.items()[0].result.ok }, r.items()[0].result.ok.status, 256 * KiB);
        try dir.writeFile(io, .{ .sub_path = "read.json", .data = read_response.bytes });
        const small = try project(h.arena, envelope, .{ .batch_read = r.owned.value }, r.owned.value.status, 1 * KiB);
        try dir.writeFile(io, .{ .sub_path = "batch_read_truncated.json", .data = small.bytes });
        const info: core.errors.ErrorInfo = .{ .code = .E_OUTPUT_BUDGET, .message = "output \"budget\"", .retryable = false };
        const buffer = try h.arena.alloc(u8, @intCast(projection.failureBufferBytes(envelope, info)));
        try dir.writeFile(io, .{ .sub_path = "failure.json", .data = (try projection.failure(buffer, envelope, info)).bytes });
    }
}
