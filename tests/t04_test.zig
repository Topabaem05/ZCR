//! T04 tests: exact, bounded range reads (IO-001..IO-006) through the I01
//! authorizer and I02 reservations.
//!
//! Run: `zig build test -Dtest-group=io`.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const admission = @import("zcr_admission");
const fs_read = @import("zcr_fs_read");

const testing = std.testing;
const io = testing.io;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const KiB = core.limits.KiB;
const MiB = core.limits.MiB;

const workspace: core.WorkspaceId = .{ .registry_uuid = @splat(0x11), .incarnation = @splat(0x22) };
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

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

const Harness = struct {
    arena: std.mem.Allocator,
    tmp: testing.TmpDir,
    root: core.TrustedRoot,
    authorizer: policy.Authorizer,
    counters: memory.accounting.Counters = .{},
    budget: memory.Budget = undefined,
    reader: fs_read.Reader,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    fn init(arena: std.mem.Allocator) !*Harness {
        const h = try arena.create(Harness);
        h.* = .{ .arena = arena, .tmp = testing.tmpDir(.{}), .root = undefined, .authorizer = undefined, .reader = undefined };
        const root_path = try h.tmp.dir.realPathFileAlloc(io, ".", arena);
        const dir = try Io.Dir.openDirAbsolute(io, root_path, .{});
        h.root = .{ .dir = dir, .canonical_path = root_path };
        h.authorizer = try policy.Authorizer.init(arena, io, h.root, workspace, task, .{
            .digest = digest,
            .state = .active,
            .read_paths = &.{.{ .bytes = "." }},
            .write_paths = &.{},
            .immutable_paths = &.{},
            .operations = &.{ .read, .batch_read, .patch },
            .max_changed_files = 1,
        }, .{ .git_dir = null, .common_dir = null });
        h.budget = memory.Budget.init(1, .{ .bytes = 64 * MiB, .fds = 16, .cpu = 4, .output_bytes = 16 * MiB }, &h.counters);
        h.reader = fs_read.Reader.init(h.root, workspace, 7);
        return h;
    }

    fn deinit(h: *Harness) void {
        h.root.dir.close(io);
        h.tmp.cleanup();
    }

    fn write(h: *Harness, sub: []const u8, data: []const u8) !void {
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    fn cancel(h: *Harness) core.Cancel {
        return .{ .requested = &h.cancel_flag };
    }

    const Read = struct {
        owned: core.Owned(core.ReadResult),
        reservation: core.Reservation,
        reserved: *memory.ReservedAllocator,

        fn lines(r: *const Read) []const core.Line {
            return r.owned.value.lines;
        }
    };

    fn spec(path: []const u8, first: u32, count: u32) core.ReadSpec {
        return .{ .path = .{ .bytes = path }, .lines = .{ .first = first, .count = count } };
    }

    fn reserveFor(h: *Harness, s: core.ReadSpec) !core.Reservation {
        const cost = try admission.estimate(.{ .operation = .read, .frame_bytes = 1 * KiB, .output_bytes = s.output_bytes });
        return h.budget.reserve(session(), cost);
    }

    fn read(h: *Harness, s: core.ReadSpec) !Read {
        const capability = try h.authorizer.authorize(io, session(), .read, s.path);
        var reservation = try h.reserveFor(s);
        errdefer h.budget.release(&reservation) catch unreachable;
        const reserved = try h.arena.create(memory.ReservedAllocator);
        reserved.* = memory.ReservedAllocator.init(testing.allocator, &reservation, &h.counters, null);
        const owned = try h.reader.readRange(io, reserved.allocator(), capability, s, &reservation, h.cancel());
        return .{ .owned = owned, .reservation = reservation, .reserved = reserved };
    }

    /// Frees the result, then returns the reservation; nothing may remain tracked.
    fn finish(h: *Harness, r: *Read) !void {
        r.owned.deinit();
        try testing.expectEqual(@as(u64, 0), r.reserved.liveBytes());
        try h.budget.release(&r.reservation);
        try testing.expectEqual(@as(u64, 0), h.budget.usage().bytes);
    }

    /// Reads that must fail still return every byte and the reservation.
    fn expectReadError(h: *Harness, expected: anyerror, s: core.ReadSpec) !void {
        const capability = try h.authorizer.authorize(io, session(), .read, s.path);
        var reservation = try h.reserveFor(s);
        var reserved = memory.ReservedAllocator.init(testing.allocator, &reservation, &h.counters, null);
        const result = h.reader.readRange(io, reserved.allocator(), capability, s, &reservation, h.cancel());
        if (result) |ok| {
            var owned = ok;
            owned.deinit();
            try h.budget.release(&reservation);
            std.debug.print("expected {t}, read succeeded\n", .{expected});
            return error.TestUnexpectedSuccess;
        } else |err| {
            try testing.expectEqual(expected, @as(anyerror, err));
        }
        try testing.expectEqual(@as(u64, 0), reserved.liveBytes());
        try h.budget.release(&reservation);
    }
};

fn sha256Hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
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

// ------------------------------------------------------------------ IO-001, IO-002

test "IO-001 two lines come back with exact byte offsets and no phantom EOF line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.write("a.txt", "alpha\nbeta\n");

    var r = try h.read(Harness.spec("a.txt", 1, 2));
    try testing.expectEqual(@as(usize, 2), r.lines().len);
    try testing.expectEqual(@as(u32, 1), r.lines()[0].number);
    try testing.expectEqual(core.ByteSpan{ .start = 0, .end = 6 }, r.lines()[0].span);
    try testing.expectEqualStrings("alpha\n", r.lines()[0].text);
    try testing.expectEqual(@as(u32, 2), r.lines()[1].number);
    try testing.expectEqual(core.ByteSpan{ .start = 6, .end = 11 }, r.lines()[1].span);
    try testing.expectEqualStrings("beta\n", r.lines()[1].text);
    try testing.expect(r.owned.value.status.complete);
    try testing.expect(!r.owned.value.status.truncated);
    try testing.expectEqual(core.Consistency.checked_live, r.owned.value.status.consistency);
    try testing.expectEqual(@as(u64, 11), r.owned.value.version.size);
    try testing.expect(r.owned.value.version.sha256 == null);
    try testing.expectEqual(@as(u64, 7), r.owned.value.version.generation);
    try testing.expect(r.owned.value.version.workspace_id.eql(workspace));
    try h.finish(&r);

    // Asking for more lines than exist returns the same two lines.
    var more = try h.read(Harness.spec("a.txt", 1, 5));
    try testing.expectEqual(@as(usize, 2), more.lines().len);
    try testing.expect(more.owned.value.status.complete);
    try h.finish(&more);
}

test "IO-002 empty files have no lines and an unterminated last line is one line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.write("empty.txt", "");
    try h.write("tail.txt", "a\nb");

    var empty = try h.read(Harness.spec("empty.txt", 1, 200));
    try testing.expectEqual(@as(usize, 0), empty.lines().len);
    try testing.expect(empty.owned.value.status.complete);
    try testing.expectEqual(@as(u64, 0), empty.owned.value.version.size);
    try h.finish(&empty);

    var tail = try h.read(Harness.spec("tail.txt", 1, 200));
    try testing.expectEqual(@as(usize, 2), tail.lines().len);
    try testing.expectEqualStrings("b", tail.lines()[1].text);
    try testing.expectEqual(core.ByteSpan{ .start = 2, .end = 3 }, tail.lines()[1].span);
    try testing.expect(tail.owned.value.status.complete);
    try h.finish(&tail);

    var beyond = try h.read(Harness.spec("tail.txt", 10, 5));
    try testing.expectEqual(@as(usize, 0), beyond.lines().len);
    try testing.expect(beyond.owned.value.status.complete);
    try h.finish(&beyond);
}

// ------------------------------------------------------------------ IO-003

test "IO-003 BOM, CRLF, mixed newlines and Hangul keep raw bytes and the whole-file SHA-256" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    const bytes = "\xEF\xBB\xBF첫 줄\r\n둘째 줄\n\r\n셋째\r\n마지막";
    try h.write("mixed.txt", bytes);

    var s = Harness.spec("mixed.txt", 1, 200);
    s.write_intent = true;
    var r = try h.read(s);
    try testing.expectEqual(@as(usize, 5), r.lines().len);
    var joined: std.ArrayList(u8) = .empty;
    var expected_start: u64 = 0;
    for (r.lines(), 1..) |line, n| {
        try testing.expectEqual(@as(u32, @intCast(n)), line.number);
        try testing.expectEqual(expected_start, line.span.start);
        try testing.expectEqual(line.span.len(), line.text.len);
        try testing.expectEqualStrings(bytes[line.span.start..line.span.end], line.text);
        expected_start = line.span.end;
        try joined.appendSlice(h.arena, line.text);
    }
    try testing.expectEqualStrings(bytes, joined.items);
    try testing.expectEqualStrings("\xEF\xBB\xBF첫 줄\r\n", r.lines()[0].text);
    try testing.expectEqualStrings("\r\n", r.lines()[2].text);
    const expected = sha256Hex(bytes);
    try testing.expectEqualStrings(&expected, &std.fmt.bytesToHex(r.owned.value.version.sha256.?, .lower));
    try h.finish(&r);
}

// ------------------------------------------------------------------ IO-004

test "IO-004 5000 lines, a line longer than a chunk and small output budgets stay bounded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();

    var many: std.ArrayList(u8) = .empty;
    for (0..5000) |i| try many.print(h.arena, "line {d:0>5}\n", .{i + 1});
    try h.write("many.txt", many.items);
    var s = Harness.spec("many.txt", 1, 5000);
    s.output_bytes = 2 * MiB;
    var all = try h.read(s);
    try testing.expectEqual(@as(usize, 5000), all.lines().len);
    try testing.expectEqualStrings("line 05000\n", all.lines()[4999].text);
    try testing.expect(all.owned.value.status.complete);
    try h.finish(&all);

    // One line of 300 KiB crosses chunk boundaries.
    const long = try h.arena.alloc(u8, 300 * KiB + 1);
    @memset(long[0 .. long.len - 1], 'x');
    long[long.len - 1] = '\n';
    const long_file = try std.mem.concat(h.arena, u8, &.{ "short\n", long, "after\n" });
    try h.write("long.txt", long_file);
    var ls = Harness.spec("long.txt", 2, 1);
    ls.output_bytes = 1 * MiB;
    var one = try h.read(ls);
    try testing.expectEqual(@as(usize, 1), one.lines().len);
    try testing.expectEqual(@as(usize, long.len), one.lines()[0].text.len);
    try testing.expectEqual(core.ByteSpan{ .start = 6, .end = 6 + long.len }, one.lines()[0].span);
    try h.finish(&one);

    // 64 KiB of 100-byte lines with a 1 KiB budget: explicit truncation.
    var sixty_four: std.ArrayList(u8) = .empty;
    for (0..640) |_| try sixty_four.appendSlice(h.arena, "y" ** 99 ++ "\n");
    try h.write("64k.txt", sixty_four.items);
    var small = Harness.spec("64k.txt", 1, 200);
    small.output_bytes = 1 * KiB;
    var cut = try h.read(small);
    try testing.expectEqual(@as(usize, 10), cut.lines().len);
    try testing.expect(cut.owned.value.status.truncated);
    try testing.expect(!cut.owned.value.status.complete);
    var returned: u64 = 0;
    for (cut.lines()) |line| returned += line.text.len;
    try testing.expect(returned <= small.output_bytes);
    try h.finish(&cut);

    // A first line that alone exceeds the budget is an output-budget error, not a partial line.
    var too_small = Harness.spec("long.txt", 2, 1);
    too_small.output_bytes = 1 * KiB;
    try h.expectReadError(error.OutputBudgetExceeded, too_small);
}

// ------------------------------------------------------------------ IO-005

const Mutation = struct {
    h: *Harness,
    path: []const u8,
    remaining: u32,
    replace: bool = false,

    fn afterOpen(context: ?*anyopaque, attempt: u32) void {
        _ = attempt;
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        if (self.remaining == 0) return;
        self.remaining -= 1;
        if (self.replace) {
            self.h.write("replacement.tmp", "replaced one\nreplaced two\n") catch unreachable;
            self.h.tmp.dir.rename("replacement.tmp", self.h.tmp.dir, self.path, io) catch unreachable;
        } else {
            self.h.write(self.path, "changed one\nchanged two\nchanged three\n") catch unreachable;
        }
    }
};

test "IO-005 short reads and interrupted reads give the same result as a plain read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    var text: std.ArrayList(u8) = .empty;
    for (0..300) |i| try text.print(h.arena, "row {d} with some text\n", .{i});
    try h.write("rows.txt", text.items);

    var plain = try h.read(Harness.spec("rows.txt", 100, 50));
    var fault: fs_read.ReadFault = .{ .max_read_bytes = 7, .interrupt_every = 3 };
    h.reader.fault = &fault;
    var faulty = try h.read(Harness.spec("rows.txt", 100, 50));
    h.reader.fault = null;

    try testing.expect(fault.reads > 100);
    try testing.expect(fault.interrupts > 0);
    try testing.expectEqual(plain.lines().len, faulty.lines().len);
    for (plain.lines(), faulty.lines()) |a, b| {
        try testing.expectEqual(a.span, b.span);
        try testing.expectEqualStrings(a.text, b.text);
    }
    try h.finish(&plain);
    try h.finish(&faulty);
}

test "IO-005 a change after open is retried once and never mixes versions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    const original = "original one\noriginal two\n";

    // Changed once: the retry reads only the new version.
    try h.write("c.txt", original);
    var once: Mutation = .{ .h = h, .path = "c.txt", .remaining = 1 };
    var fault: fs_read.ReadFault = .{ .after_open = Mutation.afterOpen, .context = &once };
    h.reader.fault = &fault;
    var retried = try h.read(Harness.spec("c.txt", 1, 10));
    try testing.expectEqual(@as(u32, 2), fault.attempts);
    try testing.expectEqual(@as(usize, 3), retried.lines().len);
    for (retried.lines()) |line| try testing.expect(std.mem.startsWith(u8, line.text, "changed"));
    try testing.expectEqual(@as(u64, 38), retried.owned.value.version.size);
    try h.finish(&retried);

    // Replaced by rename once: retried against the new file identity.
    try h.write("r.txt", original);
    const before = try h.tmp.dir.statFile(io, "r.txt", .{});
    var replace: Mutation = .{ .h = h, .path = "r.txt", .remaining = 1, .replace = true };
    fault = .{ .after_open = Mutation.afterOpen, .context = &replace };
    var replaced = try h.read(Harness.spec("r.txt", 1, 10));
    try testing.expectEqualStrings("replaced one\n", replaced.lines()[0].text);
    try testing.expect(replaced.owned.value.version.file_id.inode != before.inode);
    try h.finish(&replaced);

    // Changing on every attempt: a version conflict, not a merged result.
    try h.write("c.txt", original);
    var always: Mutation = .{ .h = h, .path = "c.txt", .remaining = 100 };
    fault = .{ .after_open = Mutation.afterOpen, .context = &always };
    try h.expectReadError(error.VersionConflict, Harness.spec("c.txt", 1, 10));
    h.reader.fault = null;
}

// ------------------------------------------------------------------ IO-006

test "IO-006 write intent hashes the whole 8 MiB file and every descriptor and byte is returned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();

    const big = try h.arena.alloc(u8, 8 * MiB);
    for (big, 0..) |*byte, i| byte.* = if (i % 64 == 63) '\n' else @intCast('a' + i % 26);
    try h.write("big.txt", big);
    const whole = sha256Hex(big);
    const fds_before = try openFdCount();

    var with_intent = Harness.spec("big.txt", 60_000, 200);
    with_intent.write_intent = true;
    var hashed = try h.read(with_intent);
    try testing.expectEqual(@as(usize, 200), hashed.lines().len);
    try testing.expectEqualStrings(&whole, &std.fmt.bytesToHex(hashed.owned.value.version.sha256.?, .lower));
    const middle = hashed.lines()[0];
    try testing.expectEqualStrings(big[middle.span.start..middle.span.end], middle.text);
    try h.finish(&hashed);

    var without = try h.read(Harness.spec("big.txt", 60_000, 200));
    try testing.expect(without.owned.value.version.sha256 == null);
    try testing.expectEqual(hashed.owned.value.version.size, without.owned.value.version.size);
    try h.finish(&without);

    // One byte over the write limit: no whole-file digest, and a stated reason.
    try h.write("over.txt", try std.mem.concat(h.arena, u8, &.{ big, "z" }));
    var over_spec = Harness.spec("over.txt", 1, 1);
    over_spec.write_intent = true;
    var over = try h.read(over_spec);
    try testing.expect(over.owned.value.version.sha256 == null);
    try testing.expect(over.owned.value.status.coverage.reasons.len > 0);
    try h.finish(&over);

    for (0..20) |_| {
        var again = try h.read(with_intent);
        try h.finish(&again);
    }
    try testing.expectEqual(fds_before, try openFdCount());
    try testing.expectEqual(@as(u64, 0), h.counters.snapshot().live_bytes);
}

// ------------------------------------------------------------------ handles, cancellation, contracts

test "T04 only regular files are opened; directories, FIFOs and symlinks are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.write("target.txt", "t\n");
    try h.tmp.dir.createDirPath(io, "dir");
    try h.tmp.dir.symLink(io, "target.txt", "link.txt", .{});
    const fifo_path = try std.fmt.allocPrintSentinel(h.arena, "{s}/pipe", .{h.root.canonical_path}, 0);
    try testing.expectEqual(@as(c_int, 0), mkfifo(fifo_path.ptr, 0o600));

    // Capabilities forged past the authorizer: the reader re-checks the file itself.
    const forged = struct {
        fn cap(path: []const u8) core.Capability {
            return .{ .handle = @enumFromInt(99), .operation = .read, .workspace_id = workspace, .task_id = task, .policy_digest = digest, .path = .{ .bytes = path } };
        }
    };
    for ([_]struct { path: []const u8, err: anyerror }{
        .{ .path = "pipe", .err = error.NotRegular },
        .{ .path = "dir", .err = error.NotRegular },
        .{ .path = "link.txt", .err = error.PathEscape },
        .{ .path = "missing.txt", .err = error.NotFound },
    }) |case| {
        const s = Harness.spec(case.path, 1, 1);
        var reservation = try h.reserveFor(s);
        var reserved = memory.ReservedAllocator.init(testing.allocator, &reservation, &h.counters, null);
        const result = h.reader.readRange(io, reserved.allocator(), forged.cap(case.path), s, &reservation, h.cancel());
        try testing.expectError(case.err, result);
        try testing.expectEqual(@as(u64, 0), reserved.liveBytes());
        try h.budget.release(&reservation);
    }
}

const CancelAfterChunk = struct {
    flag: *std.atomic.Value(bool),

    fn afterChunk(context: ?*anyopaque, chunk: u32) void {
        const self: *CancelAfterChunk = @ptrCast(@alignCast(context.?));
        if (chunk == 1) self.flag.store(true, .release);
    }
};

test "T04 cancellation before open and between chunks closes the file and frees scratch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    const data = try h.arena.alloc(u8, 2 * MiB);
    for (data, 0..) |*byte, i| byte.* = if (i % 80 == 79) '\n' else 'c';
    try h.write("big.txt", data);
    const fds_before = try openFdCount();

    h.cancel_flag.store(true, .release);
    try h.expectReadError(error.Cancelled, Harness.spec("big.txt", 20_000, 10));
    h.cancel_flag.store(false, .release);

    var on_chunk: CancelAfterChunk = .{ .flag = &h.cancel_flag };
    var fault: fs_read.ReadFault = .{ .after_chunk = CancelAfterChunk.afterChunk, .context = &on_chunk };
    h.reader.fault = &fault;
    try h.expectReadError(error.Cancelled, Harness.spec("big.txt", 20_000, 10));
    h.reader.fault = null;
    h.cancel_flag.store(false, .release);

    try testing.expectEqual(fds_before, try openFdCount());
    try testing.expectEqual(@as(u64, 0), h.counters.snapshot().live_bytes);
    var ok = try h.read(Harness.spec("big.txt", 20_000, 10));
    try h.finish(&ok);
}

test "T04 capability, reservation and consistency must match the request" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator());
    defer h.deinit();
    try h.write("a.txt", "alpha\n");
    try h.write("b.txt", "beta\n");
    const s = Harness.spec("a.txt", 1, 1);

    const cap_b = try h.authorizer.authorize(io, session(), .read, .{ .bytes = "b.txt" });
    var cap_patch = try h.authorizer.authorize(io, session(), .read, .{ .bytes = "a.txt" });
    cap_patch.operation = .patch; // a write capability is not a read capability
    var other_workspace = try h.authorizer.authorize(io, session(), .read, .{ .bytes = "a.txt" });
    other_workspace.workspace_id.incarnation = @splat(0x99);

    for ([_]core.Capability{ cap_b, cap_patch, other_workspace }) |capability| {
        var reservation = try h.reserveFor(s);
        var reserved = memory.ReservedAllocator.init(testing.allocator, &reservation, &h.counters, null);
        try testing.expectError(error.OutOfScope, h.reader.readRange(io, reserved.allocator(), capability, s, &reservation, h.cancel()));
        try h.budget.release(&reservation);
    }

    const cap_a = try h.authorizer.authorize(io, session(), .read, .{ .bytes = "a.txt" });
    var tiny = try h.budget.reserve(session(), .{ .input_bytes = 1 * KiB, .output_bytes = 1 * KiB, .fds = 1 });
    var tiny_alloc = memory.ReservedAllocator.init(testing.allocator, &tiny, &h.counters, null);
    try testing.expectError(error.OutputBudgetExceeded, h.reader.readRange(io, tiny_alloc.allocator(), cap_a, s, &tiny, h.cancel()));
    var small_spec = s;
    small_spec.output_bytes = 1 * KiB;
    try testing.expectError(error.ResourceExhausted, h.reader.readRange(io, tiny_alloc.allocator(), cap_a, small_spec, &tiny, h.cancel()));
    try h.budget.release(&tiny);

    var managed = s;
    managed.consistency = .managed_generation;
    try h.expectReadError(error.Unsupported, managed);

    // Bytes that are not UTF-8 text need a binary capability (docs/09).
    try h.write("bin.dat", "ok\n\x00\xff\xfe\n");
    try h.expectReadError(error.Unsupported, Harness.spec("bin.dat", 1, 2));
    var text_part = try h.read(Harness.spec("bin.dat", 1, 1));
    try testing.expectEqualStrings("ok\n", text_part.lines()[0].text);
    try h.finish(&text_part);
}
