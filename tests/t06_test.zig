//! T06 tests: scalar literal search with merged context (SR-001..SR-006).
//!
//! Every result is compared with an independent oracle written here: a plain
//! non-overlapping `indexOfPos` loop over the whole file, line numbers from
//! counting newlines, and context from splitting the whole file into lines.
//!
//! Run: `zig build test -Dtest-group=search`.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const search = @import("zcr_search");

const testing = std.testing;
const io = testing.io;
const Io = std.Io;
const Allocator = std.mem.Allocator;
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

/// Deep copy of one pushed file result.
const FileHit = struct {
    path: []const u8,
    matches: []core.SearchMatch,
    context: []core.Line,
    size: u64,
};

const Collector = struct {
    arena: Allocator,
    files: std.ArrayList(FileHit) = .empty,
    cancel_after: ?usize = null,
    flag: ?*std.atomic.Value(bool) = null,

    fn push(context: *anyopaque, item: core.SearchFileResult) core.SinkError!void {
        const self: *Collector = @ptrCast(@alignCast(context));
        const lines = self.arena.alloc(core.Line, item.context.len) catch return error.OutputBudgetExceeded;
        for (lines, item.context) |*dst, src| {
            dst.* = src;
            dst.text = self.arena.dupe(u8, src.text) catch return error.OutputBudgetExceeded;
        }
        self.files.append(self.arena, .{
            .path = self.arena.dupe(u8, item.path.bytes) catch return error.OutputBudgetExceeded,
            .matches = self.arena.dupe(core.SearchMatch, item.matches) catch return error.OutputBudgetExceeded,
            .context = lines,
            .size = item.version.size,
        }) catch return error.OutputBudgetExceeded;
        if (self.cancel_after) |n| if (self.files.items.len >= n) self.flag.?.store(true, .release);
    }

    fn sink(self: *Collector) core.Sink(core.SearchFileResult) {
        return .{ .context = self, .push_fn = push };
    }

    fn find(self: *const Collector, path: []const u8) ?FileHit {
        for (self.files.items) |f| if (std.mem.eql(u8, f.path, path)) return f;
        return null;
    }

    fn totalMatches(self: *const Collector) usize {
        var n: usize = 0;
        for (self.files.items) |f| n += f.matches.len;
        return n;
    }
};

const Harness = struct {
    arena: Allocator,
    tmp: testing.TmpDir,
    root: core.TrustedRoot,
    authorizer: policy.Authorizer,
    counters: memory.accounting.Counters = .{},
    budget: memory.Budget = undefined,
    reservation: core.Reservation = undefined,
    reserved: memory.ReservedAllocator = undefined,
    searcher: search.Searcher = undefined,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    fn init(arena: Allocator, caps: search.Caps) !*Harness {
        const h = try arena.create(Harness);
        h.* = .{ .arena = arena, .tmp = testing.tmpDir(.{}), .root = undefined, .authorizer = undefined };
        const root_path = try h.tmp.dir.realPathFileAlloc(io, ".", arena);
        h.root = .{ .dir = try Io.Dir.openDirAbsolute(io, root_path, .{}), .canonical_path = root_path };
        h.authorizer = try policy.Authorizer.init(arena, io, h.root, workspace, task, .{
            .digest = digest,
            .state = .active,
            .read_paths = &.{.{ .bytes = "." }},
            .write_paths = &.{},
            .immutable_paths = &.{},
            .operations = &.{ .search, .enumerate, .read },
            .max_changed_files = 1,
        }, .{ .git_dir = null, .common_dir = null });
        h.budget = memory.Budget.init(1, .{ .bytes = 256 * MiB, .fds = 64, .cpu = 4, .output_bytes = 16 * MiB }, &h.counters);
        h.reservation = try h.budget.reserve(session(), .{ .scratch_bytes = search.Caps.defaultBytes(caps) + 1 * MiB, .fds = 32 });
        h.reserved = memory.ReservedAllocator.init(testing.allocator, &h.reservation, &h.counters, null);
        h.searcher = try search.Searcher.init(h.reserved.allocator(), h.root, workspace, 3, caps);
        return h;
    }

    fn deinit(h: *Harness) void {
        h.searcher.deinit();
        h.budget.release(&h.reservation) catch unreachable;
        h.root.dir.close(io);
        h.tmp.cleanup();
    }

    fn write(h: *Harness, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |parent| try h.tmp.dir.createDirPath(io, parent);
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    fn cancel(h: *Harness) core.Cancel {
        return .{ .requested = &h.cancel_flag };
    }

    fn run(h: *Harness, spec: core.SearchSpec, collector: *Collector) !core.Coverage {
        const capability = try h.authorizer.authorize(io, session(), .search, .{ .bytes = "." });
        return h.searcher.search(io, capability, spec, collector.sink(), h.cancel());
    }
};

// ------------------------------------------------------------------ oracle

const OracleMatch = struct { start: u64, end: u64, line: u32 };

fn oracleMatches(arena: Allocator, bytes: []const u8, literal: []const u8) ![]OracleMatch {
    var out: std.ArrayList(OracleMatch) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, literal)) |start| {
        const line: u32 = @intCast(std.mem.count(u8, bytes[0..start], "\n") + 1);
        try out.append(arena, .{ .start = start, .end = start + literal.len, .line = line });
        pos = start + literal.len;
    }
    return out.items;
}

/// Whole-file lines with terminators, 1-based by index + 1.
fn oracleLines(arena: Allocator, bytes: []const u8) ![]core.Line {
    var out: std.ArrayList(core.Line) = .empty;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = if (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |nl| nl + 1 else bytes.len;
        try out.append(arena, .{ .number = @intCast(out.items.len + 1), .span = .{ .start = start, .end = end }, .text = bytes[start..end] });
        start = end;
    }
    return out.items;
}

fn oracleContext(arena: Allocator, bytes: []const u8, matches: []const OracleMatch, context_lines: u32) ![]core.Line {
    const lines = try oracleLines(arena, bytes);
    var wanted = try arena.alloc(bool, lines.len + 1);
    @memset(wanted, false);
    for (matches) |m| {
        const first = if (m.line > context_lines) m.line - context_lines else 1;
        const last = @min(lines.len, m.line + context_lines);
        for (first..last + 1) |n| wanted[n] = true;
    }
    var out: std.ArrayList(core.Line) = .empty;
    for (lines) |line| if (wanted[line.number]) try out.append(arena, line);
    return out.items;
}

fn expectFileMatchesOracle(arena: Allocator, hit: FileHit, bytes: []const u8, literal: []const u8, context_lines: u32) !void {
    const expected = try oracleMatches(arena, bytes, literal);
    try testing.expectEqual(expected.len, hit.matches.len);
    for (expected, hit.matches) |e, a| {
        try testing.expectEqual(e.start, a.span.start);
        try testing.expectEqual(e.end, a.span.end);
        try testing.expectEqual(e.line, a.line);
    }
    const context = try oracleContext(arena, bytes, expected, context_lines);
    try testing.expectEqual(context.len, hit.context.len);
    for (context, hit.context) |e, a| {
        try testing.expectEqual(e.number, a.number);
        try testing.expectEqual(e.span, a.span);
        try testing.expectEqualStrings(e.text, a.text);
    }
}

// ------------------------------------------------------------------ SR-001

test "SR-001 a literal across the 256 KiB chunk boundary matches the scalar oracle exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();

    const size = 600 * KiB;
    const bytes = try h.arena.alloc(u8, size);
    for (bytes, 0..) |*b, i| b.* = if (i % 97 == 96) '\n' else 'x';
    const literal = "NEEDLE-lit";
    const chunk = core.limits.values.chunk_bytes;
    for ([_]usize{ chunk - 3, 2 * chunk - 1, 100, size - literal.len }) |at| @memcpy(bytes[at..][0..literal.len], literal);
    try h.write("big.txt", bytes);

    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.run(.{ .literal = literal, .context_lines = 1 }, &collector);
    try testing.expectEqual(@as(usize, 1), collector.files.items.len);
    try expectFileMatchesOracle(h.arena, collector.files.items[0], bytes, literal, 1);
    try testing.expectEqual(@as(u64, 0), coverage.skipped);
    try testing.expect(h.searcher.report().complete);
}

test "SR-001 tiny chunks over random files never duplicate or miss a match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed_0601);
    const random = prng.random();

    for ([_]usize{ 1, 2, 3, 7, 16 }) |chunk_bytes| {
        const h = try Harness.init(arena, .{ .chunk_bytes = chunk_bytes });
        defer h.deinit();
        for ([_][]const u8{ "aba", "aa", "ab a", "b" }) |literal| {
            const bytes = try arena.alloc(u8, 200 + random.uintLessThan(usize, 300));
            for (bytes) |*b| b.* = "ab \n"[random.uintLessThan(usize, 4)];
            try h.write("r.txt", bytes);
            var collector: Collector = .{ .arena = arena };
            _ = try h.run(.{ .literal = literal, .context_lines = 2, .limit = 1000 }, &collector);
            const expected = try oracleMatches(arena, bytes, literal);
            if (expected.len == 0) {
                try testing.expectEqual(@as(usize, 0), collector.files.items.len);
                continue;
            }
            try testing.expectEqual(@as(usize, 1), collector.files.items.len);
            expectFileMatchesOracle(arena, collector.files.items[0], bytes, literal, 2) catch |err| {
                std.debug.print("chunk={d} literal={s}\n", .{ chunk_bytes, literal });
                return err;
            };
        }
    }
}

// ------------------------------------------------------------------ SR-002

test "SR-002 several matches on one line and overlapping context return each line once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();

    const bytes = "zero\none\nfoo bar foo foo\nthree\nfoo four\nfive\nsix\nseven\neight\nnine foo\nten\n";
    try h.write("ctx.txt", bytes);
    var collector: Collector = .{ .arena = h.arena };
    _ = try h.run(.{ .literal = "foo", .context_lines = 2 }, &collector);
    const hit = collector.find("ctx.txt").?;
    try expectFileMatchesOracle(h.arena, hit, bytes, "foo", 2);

    // Lines 1..7 merge into one block, 8..11 into another; no line appears twice.
    try testing.expectEqual(@as(usize, 5), hit.matches.len);
    var previous: u32 = 0;
    for (hit.context) |line| {
        try testing.expect(line.number > previous);
        previous = line.number;
    }
    try testing.expectEqual(@as(usize, 11), hit.context.len);
    try testing.expectEqualStrings("foo bar foo foo\n", hit.context[2].text);
}

// ------------------------------------------------------------------ SR-003

test "SR-003 empty literals are refused and regex-looking literals match as plain bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    const bytes = "a.*b\naxxb\n(foo|bar)\n[x]+\n";
    try h.write("re.txt", bytes);

    var collector: Collector = .{ .arena = h.arena };
    try testing.expectError(error.InvalidArgument, h.run(.{ .literal = "" }, &collector));
    try testing.expectError(error.InvalidArgument, h.run(.{ .literal = "a" ** 4097 }, &collector));
    try testing.expectError(error.InvalidArgument, h.run(.{ .literal = "\xff\xfe" }, &collector));
    try testing.expectError(error.Unsupported, h.run(.{ .literal = "a\nb" }, &collector));

    for ([_][]const u8{ ".*", "(foo|bar)", "[x]+" }) |literal| {
        var hits: Collector = .{ .arena = h.arena };
        _ = try h.run(.{ .literal = literal, .context_lines = 0 }, &hits);
        try expectFileMatchesOracle(h.arena, hits.files.items[0], bytes, literal, 0);
        try testing.expectEqual(@as(usize, 1), hits.files.items[0].matches.len);
    }
}

// ------------------------------------------------------------------ SR-004

test "SR-004 binary, invalid UTF-8 and oversized files are skipped with exact coverage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{ .chunk_bytes = 8 });
    defer h.deinit();

    try h.write("text.txt", "one needle here\n");
    try h.write("binary.bin", "needle\x00needle\n");
    try h.write("late-nul.txt", "needle\n" ++ "pad\n" ** 10 ++ "\x00");
    try h.write("latin1.txt", "needle caf\xe9\n");
    try h.write("split-utf8.txt", "needle \xea\xb0");
    try h.write("big.txt", "needle " ++ "x" ** 200 ++ "\n");

    var collector: Collector = .{ .arena = h.arena };
    const coverage = try h.run(.{ .literal = "needle", .max_file_bytes = 128 }, &collector);
    try testing.expectEqual(@as(usize, 1), collector.files.items.len);
    try testing.expectEqualStrings("text.txt", collector.files.items[0].path);

    const report = h.searcher.report();
    try testing.expectEqual(@as(u64, 2), report.binary_skipped);
    try testing.expectEqual(@as(u64, 2), report.invalid_utf8_skipped);
    try testing.expectEqual(@as(u64, 1), report.oversize_skipped);
    try testing.expectEqual(@as(u64, 5), coverage.skipped);
    try testing.expect(coverage.reasons.len >= 3);
    try testing.expect(!report.complete);
    try testing.expectEqual(@as(u64, 6), report.files_considered);
}

// ------------------------------------------------------------------ SR-005

test "SR-005 match, output and deadline caps stop the search honestly without allocating" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    for (0..10) |i| try h.write(try std.fmt.allocPrint(h.arena, "f{d}.txt", .{i}), "hit\nmiss\nhit\n");
    const live = h.reserved.liveBytes();

    var limited: Collector = .{ .arena = h.arena };
    const coverage = try h.run(.{ .literal = "hit", .limit = 3, .order = .path_then_offset, .context_lines = 0 }, &limited);
    try testing.expectEqual(@as(usize, 3), limited.totalMatches());
    try testing.expect(h.searcher.report().truncated);
    try testing.expect(!h.searcher.report().complete);
    try testing.expect(coverage.reasons.len > 0);

    // Output budget: context bytes returned never exceed it.
    h.searcher.output_bytes = 20;
    var small: Collector = .{ .arena = h.arena };
    _ = try h.run(.{ .literal = "hit", .context_lines = 1, .limit = 100 }, &small);
    var returned: u64 = 0;
    for (small.files.items) |f| for (f.context) |line| {
        returned += line.text.len;
    };
    try testing.expect(returned <= 20);
    try testing.expect(small.files.items.len >= 1);
    try testing.expect(h.searcher.report().truncated);
    h.searcher.output_bytes = core.limits.values.default_output_bytes;

    // Deadline expressed as cancellation during the search.
    var deadline: Collector = .{ .arena = h.arena, .cancel_after = 1, .flag = &h.cancel_flag };
    try testing.expectError(error.Cancelled, h.run(.{ .literal = "hit", .limit = 100 }, &deadline));
    try testing.expectEqual(@as(usize, 1), deadline.files.items.len);
    h.cancel_flag.store(false, .release);

    try testing.expectEqual(live, h.reserved.liveBytes());
    const report = h.searcher.report();
    try testing.expect(report.first_match_ns != null);
}

test "SR-005 internal first-match time and delivery time are recorded separately" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    try h.write("a.txt", "target\n");
    var collector: Collector = .{ .arena = h.arena };
    _ = try h.run(.{ .literal = "target" }, &collector);
    const report = h.searcher.report();
    try testing.expect(report.first_match_ns.? <= report.first_push_ns.?);
    try testing.expect(report.first_push_ns.? <= report.finished_ns);
    try testing.expectEqual(@as(u64, 1), report.files_matched);
    try testing.expectEqual(@as(u64, 1), report.matches);
}

// ------------------------------------------------------------------ SR-006

const Rewrite = struct {
    h: *Harness,
    remaining: u32,

    fn afterScan(context: ?*anyopaque, path: []const u8) void {
        const self: *Rewrite = @ptrCast(@alignCast(context.?));
        if (self.remaining == 0) return;
        self.remaining -= 1;
        self.h.write(path, "inserted line\ninserted line\nkey = value\nkey again\n") catch unreachable;
    }
};

test "SR-006 a file that changes between scan and context read is retried once or skipped, never mixed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    const original = "alpha\nkey = value\nomega\n";
    const changed = "inserted line\ninserted line\nkey = value\nkey again\n";

    try h.write("cfg.txt", original);
    var once: Rewrite = .{ .h = h, .remaining = 1 };
    var fault: search.SearchFault = .{ .after_scan = Rewrite.afterScan, .context = &once };
    h.searcher.fault = &fault;
    var retried: Collector = .{ .arena = h.arena };
    _ = try h.run(.{ .literal = "key", .context_lines = 1 }, &retried);
    try testing.expectEqual(@as(usize, 1), retried.files.items.len);
    try expectFileMatchesOracle(h.arena, retried.files.items[0], changed, "key", 1);
    try testing.expectEqual(@as(u64, 1), h.searcher.report().retries);

    try h.write("cfg.txt", original);
    var always: Rewrite = .{ .h = h, .remaining = 1000 };
    fault = .{ .after_scan = Rewrite.afterScan, .context = &always };
    var skipped: Collector = .{ .arena = h.arena };
    const coverage = try h.run(.{ .literal = "key", .context_lines = 1 }, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.files.items.len);
    try testing.expectEqual(@as(u64, 1), h.searcher.report().changed_skipped);
    try testing.expectEqual(@as(u64, 1), coverage.skipped);
    h.searcher.fault = null;
}

// ------------------------------------------------------------------ contracts

test "T06 capability and search spec are validated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const h = try Harness.init(arena_state.allocator(), .{});
    defer h.deinit();
    try h.write("a.txt", "x\n");
    var collector: Collector = .{ .arena = h.arena };

    const read_cap = try h.authorizer.authorize(io, session(), .read, .{ .bytes = "a.txt" });
    try testing.expectError(error.OutOfScope, h.searcher.search(io, read_cap, .{ .literal = "x" }, collector.sink(), h.cancel()));
    var other = try h.authorizer.authorize(io, session(), .search, .{ .bytes = "." });
    other.workspace_id.incarnation = @splat(0x98);
    try testing.expectError(error.OutOfScope, h.searcher.search(io, other, .{ .literal = "x" }, collector.sink(), h.cancel()));

    try testing.expectError(error.Unsupported, h.run(.{ .literal = "x", .consistency = .managed_generation }, &collector));
    try testing.expectError(error.InvalidArgument, h.run(.{ .literal = "x", .context_lines = 21 }, &collector));
    try testing.expectError(error.InvalidArgument, h.run(.{ .literal = "x", .limit = 0 }, &collector));
    try testing.expectError(error.InvalidArgument, h.run(.{ .literal = "x", .limit = 1001 }, &collector));
    try testing.expectError(error.InvalidArgument, h.run(.{ .literal = "x", .max_file_bytes = 0 }, &collector));
    try testing.expectError(error.InvalidArgument, h.run(.{ .literal = "x", .max_file_bytes = core.limits.values.max_search_file_bytes + 1 }, &collector));

    // The scalar kernel is the oracle T19 SIMD kernels must match.
    try testing.expectEqual(@as(?usize, 3), search.scalar.find("abcabc", "abc", 1));
    try testing.expectEqual(@as(?usize, null), search.scalar.find("abcabc", "abd", 0));
}
