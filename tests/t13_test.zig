const std = @import("std");
const core = @import("zcr_core");
const policy_mod = @import("zcr_policy");
const memory = @import("zcr_memory");
const workspace = @import("zcr_workspace");
const cache = @import("zcr_cache");
const t = std.testing;
const io = t.io;
const A = t.allocator;
const MiB = core.limits.MiB;
const read_policy: core.Policy = .{ .digest = @splat(9), .state = .active, .read_paths = &.{.{ .bytes = "." }}, .write_paths = &.{}, .immutable_paths = &.{.{ .bytes = ".git" }}, .operations = &.{ .read, .batch_read, .search }, .max_changed_files = 1 };
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    registry: workspace.Registry,
    content_counters: memory.accounting.Counters = .{},
    verify_counters: memory.accounting.Counters = .{},
    content_budget: memory.Budget = undefined,
    verify_budget: memory.Budget = undefined,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    store: *cache.Store = undefined,
    fn init() !*Fixture {
        const f = try A.create(Fixture);
        f.* = .{ .arena = .init(A), .tmp = t.tmpDir(.{}), .registry = try workspace.Registry.init(A, io, .{ .git_executable = "/usr/bin/git" }) };
        f.content_budget = memory.Budget.init(13, .{ .bytes = 16 * MiB, .fds = 0, .cpu = 0, .output_bytes = 0 }, &f.content_counters);
        f.verify_budget = memory.Budget.init(14, .{ .bytes = MiB, .fds = 16, .cpu = 8, .output_bytes = 0 }, &f.verify_counters);
        return f;
    }
    fn deinit(f: *Fixture) void {
        t.expectEqual(@as(u64, 0), f.content_budget.usage().bytes) catch unreachable;
        t.expectEqual(@as(u64, 0), f.verify_budget.usage().bytes) catch unreachable;
        t.expectEqual(@as(u64, 0), f.content_counters.live_bytes.load(.monotonic)) catch unreachable;
        t.expectEqual(@as(u64, 0), f.verify_counters.live_bytes.load(.monotonic)) catch unreachable;
        f.registry.deinit() catch unreachable;
        f.tmp.cleanup();
        f.arena.deinit();
        A.destroy(f);
    }
    fn git(f: *Fixture, path: []const u8, args: []const []const u8) !void {
        const a = f.arena.allocator();
        const argv = try a.alloc([]const u8, args.len + 3);
        argv[0] = "/usr/bin/git";
        argv[1] = "-C";
        argv[2] = path;
        @memcpy(argv[3..], args);
        var env: std.process.Environ.Map = .init(a);
        try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        const r = try std.process.run(a, io, .{ .argv = argv, .environ_map = &env, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
        if (r.term != .exited or r.term.exited != 0) return error.FixtureGit;
    }
    const Client = struct { session: cache.Session, cap: core.Capability, root: core.TrustedRoot };
    fn client(f: *Fixture, n: u8, domain: u64, text_: []const u8) !Client {
        const a = f.arena.allocator();
        const name = try std.fmt.allocPrint(a, "repo-{d}", .{n});
        try f.tmp.dir.createDir(io, name, .default_dir);
        const path = try f.tmp.dir.realPathFileAlloc(io, name, a);
        try f.git(path, &.{ "init", "-q", "-b", "main" });
        const root: core.TrustedRoot = .{ .dir = try f.tmp.dir.openDir(io, name, .{}), .canonical_path = path };
        defer root.dir.close(io);
        try root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = text_ });
        try f.git(path, &.{ "add", "." });
        try f.git(path, &.{ "-c", "user.name=T13", "-c", "user.email=t13@example.invalid", "commit", "-q", "-m", "base" });
        const id = try f.registry.registerWorkspace(io, root, read_policy);
        const snap = try f.registry.snapshot(id);
        const context: core.SessionContext = .{ .session_id = .{ .uuid = @splat(n) }, .security_domain = .{ .id = domain }, .policy_digest = read_policy.digest, .bound_workspace = id, .bound_task = .{ .uuid = @splat(n + 32) }, .capability_handle = @enumFromInt(@as(u64, n) + 1) };
        const task: core.TaskContext = .{ .task_id = context.bound_task, .base_commit = snap.head[0..snap.head_len], .scope_digest = read_policy.digest, .fence = 1, .expires_at_unix_ms = std.math.maxInt(i64) };
        try f.registry.bindSession(context, task, f.registry.bootNonce());
        if (n == 1) f.store = try cache.Store.create(A, io, &f.content_budget, context, .{ .verification_budget = &f.verify_budget });
        const auth = try a.create(policy_mod.Authorizer);
        auth.* = try policy_mod.Authorizer.init(a, io, snap.root, id, context.bound_task, read_policy, snap.git);
        return .{ .session = try cache.Session.init(f.store, &f.registry, auth, context, .{ .requested = &f.cancel_flag }), .cap = try auth.authorize(io, context, .read, .{ .bytes = "file.txt" }), .root = snap.root };
    }
    fn version(f: *Fixture, c: *Client, text_: []const u8) !core.FileVersion {
        const file = try c.root.dir.openFile(io, "file.txt", .{});
        defer file.close(io);
        const st = try file.stat(io);
        const id = try policy_mod.paths.statHandle(file.handle);
        return .{ .workspace_id = c.session.context.bound_workspace, .file_id = .{ .device = id.identity.device, .inode = id.identity.inode }, .generation = (try f.registry.snapshot(c.session.context.bound_workspace)).generation, .size = st.size, .mtime_ns = st.mtime.nanoseconds, .sha256 = hash(text_) };
    }
    fn admit(f: *Fixture, c: *Client, text_: []const u8) !void {
        const v = try f.version(c, text_);
        try t.expectEqual(cache.AdmissionResult.probation, try c.session.observe(c.cap, text_, v, .interactive));
        try t.expectEqual(cache.AdmissionResult.admitted, try c.session.observe(c.cap, text_, v, .interactive));
    }
};
fn hash(bytes: []const u8) core.ContentHash {
    var out: core.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

test "ME-004 four workspaces share one immutable allocation and pins prevent eviction" {
    const f = try Fixture.init();
    defer f.deinit();
    const text_ = "alpha\r\nbeta\n";
    var clients: [4]Fixture.Client = undefined;
    clients[0] = try f.client(1, 7, text_);
    defer f.store.deinit() catch unreachable;
    try f.admit(&clients[0], text_);
    const charge = f.store.stats().content_bytes;
    try t.expect(charge >= text_.len);
    var pins: [4]core.PinnedEntry = undefined;
    for (0..4) |i| {
        if (i > 0) clients[i] = try f.client(@intCast(i + 1), 7, text_);
        pins[i] = (try clients[i].session.cacheGet(hash(text_), clients[i].cap, .{ .max_pinned_bytes = 1024 })).?;
        try t.expectEqualStrings(text_, pins[i].bytes);
        try t.expectEqual(charge, f.store.stats().content_bytes);
    }
    try t.expectEqual(@as(usize, 1), f.store.stats().entries);
    try t.expectEqual(@as(usize, 4), f.store.stats().associations);
    try t.expectEqual(@as(u64, 0), f.store.evict(0));
    try t.expectError(error.Busy, f.store.deinit());
    for (&clients, pins) |*c, pin| try c.session.unpin(pin);
    try t.expectEqual(charge, f.store.evict(0));
    try t.expectEqual(@as(u64, 0), f.store.stats().content_bytes);
}

test "IS-006 domain and current session authority are rechecked before cache existence or pins" {
    const f = try Fixture.init();
    defer f.deinit();
    var a = try f.client(1, 7, "secret\n");
    defer f.store.deinit() catch unreachable;
    try f.admit(&a, "secret\n");
    var b = try f.client(2, 8, "secret\n");
    try t.expectEqual(@as(?core.PinnedEntry, null), try b.session.cacheGet(hash("secret\n"), b.cap, .{ .max_pinned_bytes = 1024 }));
    var wrong = a.cap;
    wrong.task_id = b.cap.task_id;
    try t.expectError(error.OutOfScope, a.session.cacheGet(hash("secret\n"), wrong, .{ .max_pinned_bytes = 1024 }));
    wrong = a.cap;
    wrong.policy_digest[0] ^= 1;
    try t.expectError(error.OutOfScope, a.session.cacheGet(hash("secret\n"), wrong, .{ .max_pinned_bytes = 1024 }));
    try f.registry.unbindSession(a.session.context.session_id, f.registry.bootNonce());
    try t.expectError(error.OutOfScope, a.session.cacheGet(hash("secret\n"), a.cap, .{ .max_pinned_bytes = 1024 }));
}

test "ME-004 second touch admits, bulk scan bypasses, sparse checkpoints preserve raw lines" {
    const f = try Fixture.init();
    defer f.deinit();
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(A);
    for (0..300) |i| try data.print(A, "line-{d}\r\n", .{i});
    var c = try f.client(1, 7, data.items);
    defer f.store.deinit() catch unreachable;
    const v = try f.version(&c, data.items);
    try t.expectEqual(cache.AdmissionResult.bypassed, try c.session.observe(c.cap, data.items, v, .bulk_scan));
    try t.expectEqual(@as(usize, 0), f.store.stats().probation);
    try t.expectEqual(cache.AdmissionResult.probation, try c.session.observe(c.cap, data.items, v, .interactive));
    try t.expectEqual(@as(u64, 0), f.store.stats().content_bytes);
    try t.expectEqual(cache.AdmissionResult.admitted, try c.session.observe(c.cap, data.items, v, .interactive));
    const pin = (try c.session.cacheGet(hash(data.items), c.cap, .{ .max_pinned_bytes = MiB })).?;
    defer c.session.unpin(pin) catch unreachable;
    const index = try c.session.lineIndex(pin);
    try t.expectEqual(@as(usize, 3), index.len);
    try t.expectEqual(@as(u32, 129), index[1].line);
    const selected = try cache.lines.select(pin.bytes, index, try core.LineRange.init(129, 2));
    try t.expectEqualStrings("line-128\r\nline-129\r\n", pin.bytes[@intCast(selected.span.start)..@intCast(selected.span.end)]);
}

test "IS-006 same size changed bytes, missing path, and forged whole-file digest never hit" {
    const f = try Fixture.init();
    defer f.deinit();
    var c = try f.client(1, 7, "alpha\n");
    defer f.store.deinit() catch unreachable;
    try f.admit(&c, "alpha\n");
    var v = try f.version(&c, "alpha\n");
    v.sha256 = null;
    try t.expectError(error.InvalidArgument, c.session.observe(c.cap, "alpha\n", v, .interactive));
    const original = try c.root.dir.openFile(io, "file.txt", .{});
    const original_stat = try original.stat(io);
    original.close(io);
    try c.root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "other\n" });
    const changed = try c.root.dir.openFile(io, "file.txt", .{ .mode = .read_write });
    try changed.setTimestamps(io, .{ .modify_timestamp = .{ .new = original_stat.mtime } });
    const changed_stat = try changed.stat(io);
    changed.close(io);
    try t.expectEqual(original_stat.size, changed_stat.size);
    try t.expectEqual(original_stat.mtime.nanoseconds, changed_stat.mtime.nanoseconds);
    try t.expectEqual(@as(?core.PinnedEntry, null), try c.session.cacheGet(hash("alpha\n"), c.cap, .{ .max_pinned_bytes = 100 }));
    try c.root.dir.deleteFile(io, "file.txt");
    try t.expectEqual(@as(?core.PinnedEntry, null), try c.session.cacheGet(hash("alpha\n"), c.cap, .{ .max_pinned_bytes = 100 }));
}

test "ME-004 pin budgets, token ownership, and association saturation retain live data" {
    const f = try Fixture.init();
    defer f.deinit();
    var a = try f.client(1, 1, "same\n");
    defer f.store.deinit() catch unreachable;
    f.store.options.max_associations = 2;
    f.store.options.max_pins = 2;
    try f.admit(&a, "same\n");
    var b = try f.client(2, 1, "same\n");
    var c = try f.client(3, 1, "same\n");
    const bytes = f.store.stats().content_bytes;
    const pin = (try a.session.cacheGet(hash("same\n"), a.cap, .{ .max_pinned_bytes = bytes })).?;
    try t.expectError(error.ResourceExhausted, a.session.cacheGet(hash("same\n"), a.cap, .{ .max_pinned_bytes = bytes }));
    try t.expectError(error.OutOfScope, b.session.unpin(pin));
    const other = (try b.session.cacheGet(hash("same\n"), b.cap, .{ .max_pinned_bytes = bytes })).?;
    try t.expectError(error.ResourceExhausted, c.session.cacheGet(hash("same\n"), c.cap, .{ .max_pinned_bytes = bytes }));
    f.store.invalidateWorkspace(a.session.context.bound_workspace);
    try t.expectEqualStrings("same\n", pin.bytes);
    try t.expectEqual(@as(u64, 0), f.store.evict(0));
    try a.session.unpin(pin);
    try t.expectError(error.OutOfScope, a.session.unpin(pin));
    const third = (try c.session.cacheGet(hash("same\n"), c.cap, .{ .max_pinned_bytes = bytes })).?;
    try t.expect(third.pin_id != pin.pin_id);
    try t.expectError(error.OutOfScope, a.session.lineIndex(pin));
    try b.session.unpin(other);
    try c.session.unpin(third);
}

test "ME-004 control and verification allocation, FD and CPU credits are real shared reservations" {
    const f = try Fixture.init();
    defer f.deinit();
    var c = try f.client(1, 1, "budget\n");
    defer f.store.deinit() catch unreachable;
    try t.expectEqual(@as(u64, @sizeOf(cache.Store)), f.store.stats().control_bytes);
    try t.expectEqual(f.store.stats().control_bytes, f.content_budget.usage().bytes);
    var small_counters: memory.accounting.Counters = .{};
    var small = memory.Budget.init(90, .{ .bytes = @sizeOf(cache.Store) - 1, .fds = 0, .cpu = 0, .output_bytes = 0 }, &small_counters);
    try t.expectError(error.ResourceExhausted, cache.Store.create(A, io, &small, c.session.context, .{ .verification_budget = &f.verify_budget }));
    try t.expectEqual(@as(u64, 0), small_counters.allocations.load(.monotonic));
    try f.admit(&c, "budget\n");
    const before = f.verify_counters.allocations.load(.monotonic);
    var occupied = try f.verify_budget.reserve(c.session.context, .{ .fds = f.verify_budget.caps.fds });
    try t.expectError(error.ResourceExhausted, c.session.cacheGet(hash("budget\n"), c.cap, .{ .max_pinned_bytes = MiB }));
    try t.expectEqual(before, f.verify_counters.allocations.load(.monotonic));
    try f.verify_budget.release(&occupied);
    occupied = try f.verify_budget.reserve(c.session.context, .{ .cpu_permits = f.verify_budget.caps.cpu });
    try t.expectError(error.ResourceExhausted, c.session.cacheGet(hash("budget\n"), c.cap, .{ .max_pinned_bytes = MiB }));
    try f.verify_budget.release(&occupied);
    const pin = (try c.session.cacheGet(hash("budget\n"), c.cap, .{ .max_pinned_bytes = MiB })).?;
    try c.session.unpin(pin);
}

test "ME-004 cancellation during verification drains memory and preserves later successful lookup" {
    const f = try Fixture.init();
    defer f.deinit();
    var c = try f.client(1, 1, "cancel\n");
    defer f.store.deinit() catch unreachable;
    try f.admit(&c, "cancel\n");
    const Hook = struct {
        fn chunk(p: *anyopaque) void {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(p));
            flag.store(true, .release);
        }
    };
    cache.association.test_hooks = .{ .context = &f.cancel_flag, .after_chunk = Hook.chunk };
    defer cache.association.test_hooks = null;
    try t.expectError(error.Cancelled, c.session.cacheGetChecked(hash("cancel\n"), c.cap, .{ .max_pinned_bytes = MiB }));
    try t.expectEqual(@as(u64, 0), f.verify_budget.usage().bytes);
    try t.expectEqual(@as(usize, 0), f.store.stats().pins);
    cache.association.test_hooks = null;
    f.cancel_flag.store(false, .release);
    c.session.cancel = c.session.cancel.withTimeout(io, 0);
    try t.expectError(error.DeadlineExceeded, c.session.cacheGetChecked(hash("cancel\n"), c.cap, .{ .max_pinned_bytes = MiB }));
    c.session.cancel = .{ .requested = &f.cancel_flag };
    const pin = (try c.session.cacheGet(hash("cancel\n"), c.cap, .{ .max_pinned_bytes = MiB })).?;
    f.cancel_flag.store(true, .release);
    try c.session.unpin(pin);
}

fn allocationScenario(allocator: std.mem.Allocator, f: *Fixture, client: *Fixture.Client) !void {
    const s = try cache.Store.create(allocator, io, &f.content_budget, client.session.context, .{ .verification_budget = &f.verify_budget });
    defer s.deinit() catch unreachable;
    var session = try cache.Session.init(s, &f.registry, client.session.authorizer, client.session.context, .{ .requested = &f.cancel_flag });
    const v = try f.version(client, "alloc\n");
    _ = try session.observe(client.cap, "alloc\n", v, .interactive);
    _ = try session.observe(client.cap, "alloc\n", v, .interactive);
    const pin = (try session.cacheGetChecked(hash("alloc\n"), client.cap, .{ .max_pinned_bytes = MiB })).?;
    try session.unpin(pin);
}
test "ME-004 failure at every allocation unwinds reservations and cache ownership" {
    const f = try Fixture.init();
    defer f.deinit();
    var c = try f.client(1, 1, "alloc\n");
    defer f.store.deinit() catch unreachable;
    const baseline = f.content_budget.usage().bytes;
    try t.checkAllAllocationFailures(A, allocationScenario, .{ f, &c });
    try t.expectEqual(baseline, f.content_budget.usage().bytes);
    try t.expectEqual(@as(u64, 0), f.verify_budget.usage().bytes);
}

test "IS-006 file binding never shares paths across workspace generation or security domains" {
    const f = try Fixture.init();
    defer f.deinit();
    var a = try f.client(1, 1, "one\n");
    defer f.store.deinit() catch unreachable;
    try f.admit(&a, "one\n");
    var b = try f.client(2, 1, "two\n");
    try t.expectEqual(@as(?core.PinnedEntry, null), try b.session.cacheGet(hash("one\n"), b.cap, .{ .max_pinned_bytes = MiB }));
    var c = try f.client(3, 2, "one\n");
    try f.admit(&c, "one\n");
    try t.expectEqual(@as(usize, 2), f.store.stats().entries);
    const p = (try a.session.cacheGet(hash("one\n"), a.cap, .{ .max_pinned_bytes = MiB })).?;
    try a.session.unpin(p);
    _ = try f.registry.markChanged(a.session.context.bound_workspace);
    const q = (try a.session.cacheGet(hash("one\n"), a.cap, .{ .max_pinned_bytes = MiB })).?;
    try t.expectEqual(@as(usize, 2), f.store.stats().associations);
    try a.session.unpin(q);
    var forged = c.session;
    forged.context.security_domain = a.session.context.security_domain;
    try t.expectError(error.OutOfScope, forged.cacheGet(hash("one\n"), c.cap, .{ .max_pinned_bytes = MiB }));
}

test "IS-006 cache reauthorization refuses symlinks and rooted final-open replacement" {
    const f = try Fixture.init();
    defer f.deinit();
    var c = try f.client(1, 1, "rooted\n");
    defer f.store.deinit() catch unreachable;
    try f.admit(&c, "rooted\n");
    try c.root.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "rooted\n" });
    const Hook = struct {
        root: std.Io.Dir,
        fn swap(p: *anyopaque) void {
            const h: *@This() = @ptrCast(@alignCast(p));
            h.root.deleteFile(io, "file.txt") catch unreachable;
            h.root.symLink(io, "other.txt", "file.txt", .{}) catch unreachable;
        }
    };
    var hook: Hook = .{ .root = c.root.dir };
    cache.association.test_hooks = .{ .context = &hook, .before_open = Hook.swap };
    defer cache.association.test_hooks = null;
    try t.expectError(error.PathEscape, c.session.cacheGet(hash("rooted\n"), c.cap, .{ .max_pinned_bytes = MiB }));
    cache.association.test_hooks = null;
    try t.expectError(error.PathEscape, c.session.cacheGet(hash("rooted\n"), c.cap, .{ .max_pinned_bytes = MiB }));
    try t.expectEqual(@as(u64, 0), f.verify_budget.usage().bytes);
}

test "ME-004 concurrent pins and unpins remain valid while eviction runs" {
    const f = try Fixture.init();
    defer f.deinit();
    var c = try f.client(1, 1, "concurrent\n");
    defer f.store.deinit() catch unreachable;
    try f.admit(&c, "concurrent\n");
    const anchor = (try c.session.cacheGet(hash("concurrent\n"), c.cap, .{ .max_pinned_bytes = MiB })).?;
    const Worker = struct {
        client: *Fixture.Client,
        store: *cache.Store,
        failures: std.atomic.Value(u32) = .init(0),
        fn run(w: *@This()) void {
            for (0..50) |_| {
                const maybe = w.client.session.cacheGet(hash("concurrent\n"), w.client.cap, .{ .max_pinned_bytes = MiB }) catch {
                    _ = w.failures.fetchAdd(1, .monotonic);
                    continue;
                };
                const pin = maybe orelse {
                    _ = w.failures.fetchAdd(1, .monotonic);
                    continue;
                };
                if (!std.mem.eql(u8, pin.bytes, "concurrent\n") or w.store.evict(0) != 0) _ = w.failures.fetchAdd(1, .monotonic);
                w.client.session.unpin(pin) catch {
                    _ = w.failures.fetchAdd(1, .monotonic);
                };
            }
        }
    };
    var worker: Worker = .{ .client = &c, .store = f.store };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    for (threads) |thread| thread.join();
    try t.expectEqual(@as(u32, 0), worker.failures.load(.monotonic));
    try t.expectEqual(@as(usize, 1), f.store.stats().pins);
    try c.session.unpin(anchor);
}

test "ME-004 sparse index matches linear oracle including empty and final-newline boundaries" {
    const cases = [_][]const u8{ "", "\n", "a", "a\n", "\xef\xbb\xbfx\r\ny\nlast", "\n" ** 257 };
    for (cases) |bytes| {
        const checkpoints = try A.alloc(cache.lines.Checkpoint, cache.lines.count(bytes));
        defer A.free(checkpoints);
        cache.lines.build(bytes, checkpoints);
        for ([_]u32{ 1, 2, 127, 128, 129, 256, 257, 258, std.math.maxInt(u32) }) |first| {
            const span = try cache.lines.select(bytes, checkpoints, try core.LineRange.init(first, 1));
            var cursor: usize = 0;
            var line: u32 = 1;
            while (cursor < bytes.len and line < first) : (line += 1) cursor = if (std.mem.indexOfScalarPos(u8, bytes, cursor, '\n')) |end| end + 1 else bytes.len;
            const end = if (cursor == bytes.len) cursor else if (std.mem.indexOfScalarPos(u8, bytes, cursor, '\n')) |p| p + 1 else bytes.len;
            try t.expectEqual(@as(u64, cursor), span.span.start);
            try t.expectEqual(@as(u64, end), span.span.end);
            try t.expectEqual(@as(u32, @intFromBool(cursor < bytes.len)), span.count);
        }
    }
}

test "ME-004 probation metadata is bounded and pinned pressure cannot bypass the group cap" {
    const f = try Fixture.init();
    defer f.deinit();
    var c = try f.client(1, 1, "pinned\n");
    defer f.store.deinit() catch unreachable;
    f.store.options.max_probation = 3;
    for (0..10) |i| {
        var text_buffer: [32]u8 = undefined;
        const text_ = try std.fmt.bufPrint(&text_buffer, "probation-{d}\n", .{i});
        try c.root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = text_ });
        _ = try c.session.observe(c.cap, text_, try f.version(&c, text_), .interactive);
    }
    try t.expectEqual(@as(usize, 3), f.store.stats().probation);
    try t.expectEqual(@as(u64, 0), f.store.stats().content_bytes);
    try c.root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "pinned\n" });
    try f.admit(&c, "pinned\n");
    const pin = (try c.session.cacheGet(hash("pinned\n"), c.cap, .{ .max_pinned_bytes = MiB })).?;
    // Shrinking a host-supplied cap to current usage models pressure without
    // inventing another budget. The existing reservation remains valid.
    const old_cap = f.content_budget.caps.bytes;
    f.content_budget.caps.bytes = f.content_budget.usage().bytes;
    defer f.content_budget.caps.bytes = old_cap;
    try c.root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "next\n" });
    const v = try f.version(&c, "next\n");
    _ = try c.session.observe(c.cap, "next\n", v, .interactive);
    try t.expectError(error.ResourceExhausted, c.session.observe(c.cap, "next\n", v, .interactive));
    try t.expectEqualStrings("pinned\n", pin.bytes);
    try t.expectEqual(@as(usize, 0), f.store.stats().active_calls);
    try c.session.unpin(pin);
    _ = try c.session.observe(c.cap, "next\n", v, .interactive);
    try t.expectEqual(cache.AdmissionResult.admitted, try c.session.observe(c.cap, "next\n", v, .interactive));
}

test "IS-006 retired workspace rejects new pins while old pins drain" {
    const f = try Fixture.init();
    defer f.deinit();
    var c = try f.client(1, 1, "retire\n");
    defer f.store.deinit() catch unreachable;
    try f.admit(&c, "retire\n");
    const pin = (try c.session.cacheGet(hash("retire\n"), c.cap, .{ .max_pinned_bytes = MiB })).?;
    try f.tmp.dir.rename("repo-1", f.tmp.dir, "moved-repo", io);
    try t.expectError(error.OutOfScope, c.session.cacheGet(hash("retire\n"), c.cap, .{ .max_pinned_bytes = MiB }));
    try t.expectEqualStrings("retire\n", pin.bytes);
    try c.session.unpin(pin);
}
