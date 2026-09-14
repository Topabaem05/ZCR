const std = @import("std");
const broker = @import("zcr_broker");
const t = std.testing;

test "BR-004 unit broker rejects wrong token instead of treating same uid as authority" {
    const token: broker.auth.Token = @splat(9);
    try t.expectError(error.OutOfScope, broker.auth.verify(token, @splat(8), .{ .id = 7 }, .{ .id = 7 }, 1234, 1234));
}
test "BR-004 unit broker rejects another user and another sandbox domain" {
    const token: broker.auth.Token = @splat(9);
    try t.expectError(error.OutOfScope, broker.auth.verify(token, token, .{ .id = 7 }, .{ .id = 7 }, 1234, 1235));
    try t.expectError(error.OutOfScope, broker.auth.verify(token, token, .{ .id = 7 }, .{ .id = 8 }, 1234, 1234));
}

const core = @import("zcr_core");
const memory = @import("zcr_memory");
const policy = @import("zcr_policy");
const workspace = @import("zcr_workspace");
const cache = @import("zcr_cache");
const executor = @import("zcr_executor");
const mcp = @import("zcr_mcp");
const options = @import("build_options");
const io = t.io;
const A = t.allocator;
const read_policy: core.Policy = .{ .digest = @splat(15), .state = .active, .read_paths = &.{.{ .bytes = "." }}, .write_paths = &.{}, .immutable_paths = &.{.{ .bytes = ".git" }}, .operations = &.{ .read, .enumerate, .search, .batch_read, .health, .status }, .max_changed_files = 1 };
const initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"T15\",\"version\":\"1\"}}}\n";
const initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
const read_request = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{\"path\":\"file.txt\"}}}\n";
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    registry: workspace.Registry,
    counters: memory.accounting.Counters = .{},
    budget: memory.Budget = undefined,
    executor_: executor.Executor = undefined,
    store: *cache.Store = undefined,
    snapshot_: workspace.Snapshot = undefined,
    grants: [16]broker.Grant = undefined,
    cache_sessions: [16]cache.Session = undefined,
    authorities: [16]Authority = undefined,
    count: usize,
    flag: std.atomic.Value(bool) = .init(false),
    server: ?*broker.Server = null,
    thread: ?std.Thread = null,
    socket_path: []const u8 = "",
    run_error: ?anyerror = null,
    const Authority = struct {
        registry: *workspace.Registry,
        session: core.SessionContext,
        fn validate(context: ?*anyopaque) core.AuthorizeError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.registry.validateSession(self.session, self.registry.bootNonce()) catch return error.OutOfScope;
        }
    };
    fn init(count: usize) !*Fixture {
        return initWithIo(count, 2);
    }
    fn initWithIo(count: usize, io_permits: u32) !*Fixture {
        const f = try A.create(Fixture);
        f.* = .{ .arena = .init(A), .tmp = t.tmpDir(.{}), .registry = try workspace.Registry.init(A, io, .{ .git_executable = "/usr/bin/git" }), .count = count };
        const a = f.arena.allocator();
        const private_path = try f.tmp.dir.realPathFileAlloc(io, ".", a);
        try t.expect(std.c.chmod(try a.dupeZ(u8, private_path), 0o700) == 0);
        try f.tmp.dir.createDir(io, "r", .default_dir);
        const root_path = try f.tmp.dir.realPathFileAlloc(io, "r", a);
        try f.git(root_path, &.{ "init", "-q", "-b", "main" });
        const root: core.TrustedRoot = .{ .dir = try f.tmp.dir.openDir(io, "r", .{}), .canonical_path = root_path };
        defer root.dir.close(io);
        try root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "broker shared alpha\n" });
        try f.git(root_path, &.{ "add", "." });
        try f.git(root_path, &.{ "-c", "user.name=T15", "-c", "user.email=t15@example.invalid", "commit", "-q", "-m", "base" });
        const id = try f.registry.registerWorkspace(io, root, read_policy);
        f.snapshot_ = try f.registry.snapshot(id);
        f.budget = memory.Budget.init(15, .{ .bytes = 128 * core.limits.MiB, .fds = 128, .cpu = 2, .output_bytes = 16 * core.limits.MiB }, &f.counters);
        try f.executor_.init(A, &f.budget, .{ .cpu_permits = 2, .io_permits = io_permits, .usable_physical_cpus = 4 });
        for (0..count) |i| {
            const n: u8 = @intCast(i + 1);
            const context: core.SessionContext = .{ .session_id = .{ .uuid = @splat(n) }, .security_domain = .{ .id = 7 }, .policy_digest = read_policy.digest, .bound_workspace = id, .bound_task = .{ .uuid = @splat(n + 32) }, .capability_handle = @enumFromInt(n) };
            try f.registry.bindSession(context, .{ .task_id = context.bound_task, .base_commit = f.snapshot_.head[0..f.snapshot_.head_len], .scope_digest = read_policy.digest, .fence = 1, .expires_at_unix_ms = std.math.maxInt(i64) }, f.registry.bootNonce());
            if (i == 0) f.store = try cache.Store.create(A, io, &f.budget, context, .{ .verification_budget = &f.budget });
            const authorizer = try a.create(policy.Authorizer);
            authorizer.* = try policy.Authorizer.init(a, io, f.snapshot_.root, id, context.bound_task, read_policy, f.snapshot_.git);
            f.authorities[i] = .{ .registry = &f.registry, .session = context };
            f.cache_sessions[i] = try cache.Session.init(f.store, &f.registry, authorizer, context, .{ .requested = &f.flag });
            f.grants[i] = .{ .token = try broker.auth.generate(io), .host_ceiling = read_policy, .cache_session = &f.cache_sessions[i], .config = .{ .allocator = A, .io = io, .authorizer = authorizer, .session = context, .budget = &f.budget, .generation = f.snapshot_.generation, .tools_json = options.tools_json, .authority_context = &f.authorities[i], .validate_authority = Authority.validate } };
        }
        const parent = try f.tmp.dir.realPathFileAlloc(io, ".", a);
        f.socket_path = try std.fs.path.join(a, &.{ parent, "s" });
        return f;
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
        const result = try std.process.run(a, io, .{ .argv = argv, .environ_map = &env, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
        try t.expect(result.term == .exited and result.term.exited == 0);
    }
    fn config(f: *Fixture) broker.Config {
        return .{ .allocator = A, .io = io, .socket_path = f.socket_path, .grants = f.grants[0..f.count], .budget = &f.budget, .executor = &f.executor_, .store = f.store, .registry = &f.registry };
    }
    fn run(f: *Fixture) void {
        f.server.?.serve() catch |err| {
            f.run_error = err;
        };
    }
    fn start(f: *Fixture) !void {
        f.server = try broker.Server.create(f.config());
        f.thread = try std.Thread.spawn(.{}, run, .{f});
    }
    fn connect(f: *Fixture, i: usize) !broker.bridge.Client {
        return try broker.bridge.Client.connect(A, io, f.socket_path, f.grants[i].token, f.grants[i].config.session.security_domain);
    }
    fn deinit(f: *Fixture) void {
        if (f.thread) |thread| {
            f.server.?.stop();
            thread.join();
            t.expect(f.run_error == null) catch unreachable;
        }
        if (f.server) |s| s.deinit() catch unreachable;
        f.executor_.deinit();
        f.store.deinit() catch unreachable;
        t.expectEqual(@as(u64, 0), f.budget.usage().bytes) catch unreachable;
        t.expectEqual(@as(u64, 0), f.counters.live_bytes.load(.acquire)) catch unreachable;
        f.registry.deinit() catch unreachable;
        f.tmp.cleanup();
        f.arena.deinit();
        A.destroy(f);
    }
};
fn startProtocol(c: *broker.bridge.Client) !void {
    try c.sendAll(initialize);
    var buffer: [8192]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, try c.readLine(&buffer), "2025-11-25") != null);
    try c.sendAll(initialized);
}

test "BR-001 four real UDS clients query using one executor and 128MiB group" {
    const f = try Fixture.initWithIo(4, 1);
    defer f.deinit();
    try f.start();
    var clients: [4]broker.bridge.Client = undefined;
    var connected: usize = 0;
    defer for (clients[0..connected]) |*c| c.close();
    for (&clients, 0..) |*c, i| {
        c.* = try f.connect(i);
        connected += 1;
        try startProtocol(c);
    }
    for (0..3) |round| {
        for (&clients) |*c| try c.sendAll(read_request);
        for (&clients) |*c| {
            var buffer: [8192]u8 = undefined;
            const reply = try c.readLine(&buffer);
            try t.expect(std.mem.indexOf(u8, reply, "broker shared alpha") != null);
            if (round == 2) {
                const rpc = try std.json.parseFromSlice(std.json.Value, A, reply, .{});
                defer rpc.deinit();
                const payload = rpc.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
                const result = try std.json.parseFromSlice(std.json.Value, A, payload, .{});
                defer result.deinit();
                try t.expectEqualStrings("hit", result.value.object.get("meta").?.object.get("cache").?.string);
            }
        }
    }
    // These entries must have been admitted through the real broker requests;
    // the test never calls observe to populate the shared Store.
    try t.expectEqual(@as(usize, 1), f.store.stats().entries);
    var hash: core.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash("broker shared alpha\n", &hash, .{});
    var pins: [4]core.PinnedEntry = undefined;
    var held: usize = 0;
    defer for (pins[0..held], 0..) |pin, i| f.cache_sessions[i].unpin(pin) catch unreachable;
    for (f.cache_sessions[0..4], 0..) |*session, i| {
        const cap = try session.authorizer.authorize(io, session.context, .read, .{ .bytes = "file.txt" });
        pins[i] = (try session.cacheGetChecked(hash, cap, .{ .max_pinned_bytes = 4096 })).?;
        held += 1;
    }
    try t.expectEqual(@as(usize, 4), f.store.stats().pins);
    try t.expectEqual(@as(u32, 4), f.server.?.snapshot().authenticated);
    try t.expect(f.budget.peakBytes() <= 128 * core.limits.MiB);
    try t.expect(f.executor_.snapshot().peak_cpu <= 2);
    try t.expectEqual(@as(u32, 1), f.executor_.snapshot().peak_io);
}

test "BR-002 seventeenth UDS connection refuses while sixteen clients retain progress" {
    const f = try Fixture.init(16);
    defer f.deinit();
    try f.start();
    var clients: [16]broker.bridge.Client = undefined;
    var connected: usize = 0;
    defer for (clients[0..connected]) |*c| c.close();
    for (&clients, 0..) |*c, i| {
        c.* = try f.connect(i);
        connected += 1;
    }
    try expectRefused(f.connect(0));
    try clients[0].sendAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}\n");
    var buffer: [8192]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, try clients[0].readLine(&buffer), "\"result\"") != null);
    try t.expectEqual(@as(u32, 16), f.server.?.snapshot().authenticated);
    try t.expect(f.server.?.snapshot().refused >= 1);
}

test "BR-004 unit policy intersection refuses broader scope operations and missing denies" {
    try broker.auth.withinCeiling(read_policy, read_policy);
    var narrow = read_policy;
    narrow.read_paths = &.{.{ .bytes = "src" }};
    try broker.auth.withinCeiling(narrow, read_policy);
    try t.expectError(error.OutOfScope, broker.auth.withinCeiling(read_policy, narrow));
    var wider = read_policy;
    wider.operations = &.{ .read, .patch };
    try t.expectError(error.OutOfScope, broker.auth.withinCeiling(wider, read_policy));
    wider = read_policy;
    wider.immutable_paths = &.{};
    try t.expectError(error.OutOfScope, broker.auth.withinCeiling(wider, read_policy));
    wider = read_policy;
    wider.state = .planned;
    try t.expectError(error.OutOfScope, broker.auth.withinCeiling(wider, read_policy));
}

test "BR-001 unit four compatible cache facades share content and hold charged pins" {
    const f = try Fixture.init(4);
    defer f.deinit();
    const bytes = "broker shared alpha\n";
    var hash: core.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const file = try f.snapshot_.root.dir.openFile(io, "file.txt", .{});
    defer file.close(io);
    const st = try file.stat(io);
    const identity = try policy.paths.statHandle(file.handle);
    const version: core.FileVersion = .{ .workspace_id = f.snapshot_.workspace_id, .file_id = .{ .device = identity.identity.device, .inode = identity.identity.inode }, .generation = f.snapshot_.generation, .size = st.size, .mtime_ns = st.mtime.nanoseconds, .sha256 = hash };
    var pins: [4]core.PinnedEntry = undefined;
    var held: usize = 0;
    defer for (pins[0..held], 0..) |pin, i| f.cache_sessions[i].unpin(pin) catch unreachable;
    for (&f.cache_sessions[0..4].*, 0..) |*session, i| {
        const cap = try session.authorizer.authorize(io, session.context, .read, .{ .bytes = "file.txt" });
        _ = try session.observe(cap, bytes, version, .interactive);
        _ = try session.observe(cap, bytes, version, .interactive);
        pins[i] = (try session.cacheGetChecked(hash, cap, .{ .max_pinned_bytes = 4096 })).?;
        held += 1;
        try t.expectEqualStrings(bytes, pins[i].bytes);
    }
    try t.expectEqual(@as(usize, 1), f.store.stats().entries);
    try t.expectEqual(@as(usize, 4), f.store.stats().pins);
    try t.expect(f.budget.usage().bytes <= 128 * core.limits.MiB);
    try t.expectEqual(@as(u8, 0), f.budget.usage().cpu);
}

test "BR-001 unit broker refuses independent budgets inflated CPU and mismatched cache binding" {
    const f = try Fixture.init(1);
    defer f.deinit();
    var bad = f.config();
    var other = memory.Budget.init(16, f.budget.caps, &f.counters);
    bad.budget = &other;
    try expectCreateError(error.InvalidArgument, bad);
    f.budget.caps.cpu = 255;
    try expectCreateError(error.InvalidArgument, f.config());
    f.budget.caps.cpu = 2;
    f.cache_sessions[0].context.security_domain.id = 99;
    try expectCreateError(error.OutOfScope, f.config());
    f.cache_sessions[0].context.security_domain.id = 7;
    f.grants[0].host_ceiling.read_paths = &.{.{ .bytes = "elsewhere" }};
    try expectCreateError(error.OutOfScope, f.config());
}

test "BR-003 unit bridge and output credit share global group refusal and release" {
    const f = try Fixture.init(1);
    defer f.deinit();
    const before = f.budget.usage();
    var bridge_credit = try f.budget.reserve(f.grants[0].config.session, .{ .scratch_bytes = 16 * broker.bridge.charged_bytes, .input_bytes = 16 * (65536 + 1), .fds = 48 });
    try t.expectEqual(before.bytes + 16 * broker.bridge.charged_bytes + 16 * (65536 + 1), f.budget.usage().bytes);
    var outputs: [8]core.Reservation = undefined;
    for (&outputs) |*credit| credit.* = try f.budget.reserve(f.grants[0].config.session, .{ .output_bytes = 2 * core.limits.MiB });
    try t.expectError(error.ResourceExhausted, f.budget.reserve(f.grants[0].config.session, .{ .output_bytes = 1 }));
    try f.budget.release(&outputs[0]);
    var fast = try f.budget.reserve(f.grants[0].config.session, .{ .output_bytes = 1024 });
    try f.budget.release(&fast);
    for (outputs[1..]) |*credit| try f.budget.release(credit);
    try f.budget.release(&bridge_credit);
    try t.expectEqual(before.bytes, f.budget.usage().bytes);
}

const LookupFixture = struct {
    lookups: usize = 0,
    response: core.JournalResult = .absent,
    fn lookup(ctx: *anyopaque, key: core.JournalKey) core.JournalError!core.JournalResult {
        const f: *@This() = @ptrCast(@alignCast(ctx));
        f.lookups += 1;
        if (!std.mem.eql(u8, key.idempotency_key, "write-1") or key.security_domain.id != 7) return error.InvalidArgument;
        return f.response;
    }
    fn prepare(_: *anyopaque, _: core.PreparedRecord) core.JournalError!core.JournalResult {
        return error.Unsupported;
    }
    fn record(_: *anyopaque, _: core.Receipt) core.JournalError!core.JournalResult {
        return error.Unsupported;
    }
    fn store(f: *@This()) core.JournalStore {
        return .{ .context = f, .vtable = &.{ .prepare = prepare, .record = record, .lookup = lookup } };
    }
};
test "BR-005 unit reconnect never resends uncertain write and queries receipt only" {
    var reconnect: broker.bridge.Reconnect = .{};
    var fixture: LookupFixture = .{};
    const key: core.JournalKey = .{ .security_domain = .{ .id = 7 }, .workspace_incarnation = @splat(2), .task_id = .{ .uuid = @splat(3) }, .idempotency_key = "write-1" };
    try reconnect.beginWrite(key, @splat(4));
    reconnect.disconnected();
    try t.expect((try reconnect.lookup(fixture.store())) == null);
    try t.expectError(error.Busy, reconnect.beginWrite(key, @splat(4)));
    fixture.response = .{ .found = .{ .id = .{ .uuid = @splat(5) }, .idempotency_key = "write-1", .op_digest = @splat(4), .applied = true, .durable = true, .cancellation_observed = false, .old_hash = @splat(6), .new_hash = @splat(7), .generation = 2, .error_code = null } };
    try t.expect((try reconnect.lookup(fixture.store())).?.applied);
    try t.expectEqual(@as(usize, 2), fixture.lookups);
    try t.expectError(error.InvalidArgument, reconnect.lookup(fixture.store()));
}

test "BR-004 unit token randomness and private parent check preserve host files" {
    const one = try broker.auth.generate(io);
    const two = try broker.auth.generate(io);
    try t.expect(!std.mem.eql(u8, &one, &two));
    const f = try Fixture.init(1);
    defer f.deinit();
    const parent = try broker.auth.privateParent(A, io, f.socket_path);
    parent.close(io);
    const dirname = std.fs.path.dirname(f.socket_path).?;
    try t.expect(std.c.chmod(try f.arena.allocator().dupeZ(u8, dirname), 0o755) == 0);
    try t.expectError(error.OutOfScope, broker.auth.privateParent(A, io, f.socket_path));
    try t.expectError(error.InvalidArgument, broker.auth.address("relative.sock"));
}

test "BR-003 slow UDS client holds output while fast client keeps making progress" {
    const f = try Fixture.init(2);
    defer f.deinit();
    const large = try f.arena.allocator().alloc(u8, 128 * 1024);
    @memset(large, 'a');
    large[large.len - 1] = '\n';
    try f.snapshot_.root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = large });
    try f.start();
    var slow = try f.connect(0);
    defer slow.close();
    var fast = try f.connect(1);
    defer fast.close();
    try startProtocol(&slow);
    try slow.sendAll(read_request);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    while (f.server.?.snapshot().backlog_bytes < 8192 and start.untilNow(io).raw.toMilliseconds() < 5000) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try t.expect(f.server.?.snapshot().backlog_bytes > 8192);
    for (0..4) |_| {
        try fast.sendAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}\n");
        var buf: [1024]u8 = undefined;
        try t.expect(std.mem.indexOf(u8, try fast.readLine(&buf), "\"result\"") != null);
    }
    try t.expect(f.server.?.snapshot().backlog_bytes > 8192);
    try t.expect(f.server.?.snapshot().peak_backlog_bytes <= 16 * core.limits.MiB);
    try t.expect(f.budget.usage().output_bytes <= 16 * core.limits.MiB);
    try t.expect(f.budget.peakBytes() <= 128 * core.limits.MiB);
}

fn expectRefused(result: anyerror!broker.bridge.Client) !void {
    if (result) |value| {
        var client = value;
        client.close();
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.OutOfScope, error.Disconnected, error.IoFailure => {},
        else => return err,
    }
}
test "BR-004 real UDS token and domain refusal cannot disconnect a valid grant" {
    const f = try Fixture.init(1);
    defer f.deinit();
    try f.start();
    try expectRefused(broker.bridge.Client.connect(A, io, f.socket_path, @splat(1), .{ .id = 7 }));
    try expectRefused(broker.bridge.Client.connect(A, io, f.socket_path, f.grants[0].token, .{ .id = 99 }));
    var client = try f.connect(0);
    defer client.close();
    try t.expectEqual(std.c.geteuid(), try broker.auth.peerUid(client.fd));
    try startProtocol(&client);
    try client.sendAll("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{\"path\":\"../secret\"}}}\n");
    var buffer: [8192]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, try client.readLine(&buffer), "\"isError\":true") != null);
    try client.sendAll("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_patch\",\"arguments\":{}}}\n");
    try t.expect(std.mem.indexOf(u8, try client.readLine(&buffer), "E_UNSUPPORTED") != null);
}

test "BR-002 idle unauthenticated UDS peer expires and releases its connection credit" {
    const f = try Fixture.init(1);
    defer f.deinit();
    var cfg = f.config();
    cfg.handshake_ms = 25;
    f.server = try broker.Server.create(cfg);
    f.thread = try std.Thread.spawn(.{}, Fixture.run, .{f});
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    try t.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var address = try broker.auth.address(f.socket_path);
    try t.expect(std.c.connect(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) == 0);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    while (f.server.?.snapshot().connected == 0 and start.untilNow(io).raw.toMilliseconds() < 1000) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try t.expectEqual(@as(u32, 1), f.server.?.snapshot().connected);
    while (f.server.?.snapshot().connected != 0 and start.untilNow(io).raw.toMilliseconds() < 1000) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try t.expectEqual(@as(u32, 0), f.server.?.snapshot().connected);
    var client = try f.connect(0);
    defer client.close();
}

test "BR-005 unit bridge cancellation cannot open a socket or replay a request" {
    var client: broker.bridge.Client = .{ .fd = -1 };
    var cancelled: std.atomic.Value(bool) = .init(true);
    try t.expectError(error.Cancelled, client.forward(.{ .handle = -1, .flags = .{ .nonblocking = false } }, .{ .handle = -1, .flags = .{ .nonblocking = false } }, .{ .requested = &cancelled }));
}

test "BR-001 unit constructor allocation refusal leaves group reservations and handles intact" {
    const f = try Fixture.init(1);
    defer f.deinit();
    const before = f.budget.usage();
    var failure = std.testing.FailingAllocator.init(A, .{ .fail_index = 0 });
    var cfg = f.config();
    cfg.allocator = failure.allocator();
    f.executor_.allocator = cfg.allocator;
    defer f.executor_.allocator = A;
    try expectCreateError(error.OutOfMemory, cfg);
    try t.expect(failure.has_induced_failure);
    try t.expectEqual(before.bytes, f.budget.usage().bytes);
    try t.expectEqual(before.fds, f.budget.usage().fds);
    try t.expectEqual(before.output_bytes, f.budget.usage().output_bytes);
    try f.registry.validateSession(f.grants[0].config.session, f.registry.bootNonce());
}

test "BR-005 unit reconnect mismatched receipt stays uncertain without new write" {
    var reconnect: broker.bridge.Reconnect = .{};
    var fixture: LookupFixture = .{ .response = .{ .conflict = @splat(1) } };
    const key: core.JournalKey = .{ .security_domain = .{ .id = 7 }, .workspace_incarnation = @splat(2), .task_id = .{ .uuid = @splat(3) }, .idempotency_key = "write-1" };
    try reconnect.beginWrite(key, @splat(4));
    reconnect.disconnected();
    try t.expectError(error.OutOfScope, reconnect.lookup(fixture.store()));
    try t.expectError(error.Busy, reconnect.beginWrite(key, @splat(4)));
}

const Pipes = struct {
    extern "c" fn pipe(*[2]std.c.fd_t) c_int;
};
test "BR-003 unit review EOF preserves final readable stdin frame" {
    var pipe: [2]std.c.fd_t = undefined;
    try t.expect(Pipes.pipe(&pipe) == 0);
    defer _ = std.c.close(pipe[0]);
    const frame = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n";
    try t.expectEqual(@as(isize, frame.len), std.c.write(pipe[1], frame.ptr, frame.len));
    _ = std.c.close(pipe[1]);
    var fds = [_]std.c.pollfd{.{ .fd = pipe[0], .events = std.c.POLL.IN, .revents = 0 }};
    try t.expect(std.c.poll(&fds, 1, 1000) == 1);
    var buffer: [256]u8 = undefined;
    const n = try broker.bridge.readReady(pipe[0], &buffer, fds[0].revents);
    try t.expectEqualStrings(frame, buffer[0..n]);
}
test "BR-004 unit review active ID cancellation is scoped and recognizes escaped string IDs" {
    const cancellation = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"same\\u002did\"}}";
    try t.expect(broker.cancelMatches(cancellation, "\"same-id\""));
    try t.expect(!broker.cancelMatches(cancellation, "\"other-id\""));
    try t.expect(!broker.cancelMatches("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"same-id\"}}", "\"same-id\""));
}
test "BR-003 unit review health uses retained control credit under global saturation" {
    const f = try Fixture.init(1);
    defer f.deinit();
    var control_credit = try f.budget.reserve(f.grants[0].config.session, .{ .scratch_bytes = broker.control_bytes, .output_bytes = broker.control_output_bytes });
    defer f.budget.release(&control_credit) catch unreachable;
    const backing = try A.alloc(u8, broker.control_bytes);
    defer A.free(backing);
    var full = try f.budget.reserve(f.grants[0].config.session, .{ .scratch_bytes = f.budget.caps.bytes - f.budget.usage().bytes });
    defer f.budget.release(&full) catch unreachable;
    var protocol = try @import("zcr_mcp").Server.init(f.grants[0].config);
    protocol.phase.store(2, .release);
    const response = try broker.respondControl(&protocol, backing, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_health\",\"arguments\":{}}}", .{ .requested = &f.flag });
    try t.expect(std.mem.indexOf(u8, response, "tracked_limit_bytes") != null);
}
test "BR-001 unit review executor frame claims an IO permit" {
    try t.expect(broker.frameJobCost().fds != 0);
    try t.expectEqual(@as(u8, 0), broker.frameJobCost().cpu_permits);
}
test "BR-004 unit review grant authorizer root must match registered root without cache facade" {
    const f = try Fixture.init(1);
    defer f.deinit();
    f.grants[0].cache_session = null;
    const original = f.grants[0].config.authorizer.root;
    defer f.grants[0].config.authorizer.root = original;
    f.grants[0].config.authorizer.root = .{ .dir = f.tmp.dir, .canonical_path = std.fs.path.dirname(f.socket_path).? };
    try expectCreateError(error.OutOfScope, f.config());
}

test "BR-003 finite bridge stdin drains complete requests and all broker responses before EOF" {
    const f = try Fixture.init(1);
    defer f.deinit();
    try f.start();
    var client = try f.connect(0);
    defer client.close();
    var input: [2]std.c.fd_t = undefined;
    var output: [2]std.c.fd_t = undefined;
    try t.expect(Pipes.pipe(&input) == 0);
    try t.expect(Pipes.pipe(&output) == 0);
    defer _ = std.c.close(input[0]);
    defer _ = std.c.close(output[0]);
    const Run = struct {
        client: *broker.bridge.Client,
        input: std.c.fd_t,
        output: std.c.fd_t,
        flag: *std.atomic.Value(bool),
        failure: ?anyerror = null,
        fn run(r: *@This()) void {
            defer _ = std.c.close(r.output);
            r.client.forward(.{ .handle = r.input, .flags = .{ .nonblocking = false } }, .{ .handle = r.output, .flags = .{ .nonblocking = false } }, .{ .requested = r.flag }) catch |err| {
                r.failure = err;
            };
        }
    };
    var run: Run = .{ .client = &client, .input = input[0], .output = output[1], .flag = &f.flag };
    const thread = try std.Thread.spawn(.{}, Run.run, .{&run});
    const stream = initialize ++ initialized ++ read_request;
    try t.expectEqual(@as(isize, stream.len), std.c.write(input[1], stream.ptr, stream.len));
    _ = std.c.close(input[1]);
    var result: [16384]u8 = undefined;
    var used: usize = 0;
    while (used < result.len) {
        var fds = [_]std.c.pollfd{.{ .fd = output[0], .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 5000) <= 0) {
            f.flag.store(true, .release);
            break;
        }
        const n = std.c.read(output[0], result[used..].ptr, result.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    thread.join();
    try t.expect(run.failure == null);
    try t.expect(std.mem.indexOf(u8, result[0..used], "2025-11-25") != null);
    try t.expect(std.mem.indexOf(u8, result[0..used], "broker shared alpha") != null);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, result[0..used], "\n"));
}

test "BR-004 active UDS request cancellation remains scoped across client sessions" {
    const f = try Fixture.init(2);
    defer f.deinit();
    const Gate = struct {
        authority: *Fixture.Authority,
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        fn validate(ctx: ?*anyopaque) core.AuthorizeError!void {
            const g: *@This() = @ptrCast(@alignCast(ctx.?));
            try Fixture.Authority.validate(g.authority);
            g.entered.store(true, .release);
            while (!g.released.load(.acquire)) std.Io.sleep(io, .fromMilliseconds(1), .awake) catch return error.IoFailure;
        }
    };
    var gate: Gate = .{ .authority = &f.authorities[0] };
    defer gate.released.store(true, .release);
    f.grants[0].config.authority_context = &gate;
    f.grants[0].config.validate_authority = Gate.validate;
    try f.start();
    var own = try f.connect(0);
    defer own.close();
    var other = try f.connect(1);
    defer other.close();
    try startProtocol(&own);
    try own.sendAll(read_request);
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (!gate.entered.load(.acquire) and started.untilNow(io).raw.toMilliseconds() < 5000) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try t.expect(gate.entered.load(.acquire));
    const cancel = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}\n";
    try other.sendAll(cancel ++ "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n");
    var buffer: [8192]u8 = undefined;
    _ = try other.readLine(&buffer);
    try t.expect(!f.server.?.sessions[0].cancel.load(.acquire));
    try own.sendAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{\"path\":\"file.txt\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":3}}\n");
    try own.sendAll(cancel);
    while (!f.server.?.sessions[0].cancel.load(.acquire) and started.untilNow(io).raw.toMilliseconds() < 5000) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try t.expect(f.server.?.sessions[0].cancel.load(.acquire));
    gate.released.store(true, .release);
    try t.expect(std.mem.indexOf(u8, try own.readLine(&buffer), "E_CANCELLED") != null);
    const queued = try own.readLine(&buffer);
    try t.expect(std.mem.indexOf(u8, queued, "E_CANCELLED") != null);
    try t.expect(std.mem.indexOf(u8, queued, "\"id\":3") != null);
}

test "BR-003 real broker health stays available when ordinary group bytes are exhausted" {
    const f = try Fixture.init(1);
    defer f.deinit();
    try f.start();
    var client = try f.connect(0);
    defer client.close();
    try startProtocol(&client);
    var full = try f.budget.reserve(f.grants[0].config.session, .{ .scratch_bytes = f.budget.caps.bytes - f.budget.usage().bytes });
    defer f.budget.release(&full) catch unreachable;
    try client.sendAll("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_health\",\"arguments\":{}}}\n");
    var buffer: [8192]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, try client.readLine(&buffer), "tracked_limit_bytes") != null);
}

// std.testing.expectError's unexpected-success formatter recursively formats
// *Server and reserves about 16MiB of stack in ReleaseSafe. Compare only errors
// and clean up an unexpected successful constructor without formatting its heap.
fn expectCreateError(expected: anyerror, config: broker.Config) !void {
    if (broker.Server.create(config)) |server| {
        try server.deinit();
        return error.TestUnexpectedResult;
    } else |actual| try t.expectEqual(expected, actual);
}

test "BR-004 unit wave2 cancellation binds preceding buffered IDs and survives compaction" {
    const cancel = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}";
    const first = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\"}\n";
    var pending: broker.BufferedCancellations = .{};
    try pending.observe(first ++ read_request, cancel);
    try t.expect(!pending.contains(0));
    try t.expect(pending.contains(first.len));
    pending.remove(0, first.len);
    try t.expect(pending.contains(0));
    pending.remove(0, read_request.len);
    try t.expect(!pending.contains(0));
    try pending.observe("", cancel);
    try t.expect(!pending.contains(0));
}

test "BR-004 unit saved cancellation crosses production submit and completion boundary" {
    const f = try Fixture.init(1);
    defer f.deinit();
    var protocol_config = f.grants[0].config;
    protocol_config.backend = .broker;
    protocol_config.max_batch_concurrency = 1;
    protocol_config.cache_session = f.grants[0].cache_session;
    var protocol = try mcp.Server.init(protocol_config);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_ran = std.atomic.Value(bool).init(false);
    const Callback = struct {
        fn run(job: *core.JobEnvelope) void {
            const ran: *std.atomic.Value(bool) = @ptrCast(@alignCast(job.userdata.?));
            ran.store(true, .release);
        }
    };
    const a = f.arena.allocator();
    _ = try protocol.respond(a, initialize[0 .. initialize.len - 1], .{ .requested = &f.flag });
    _ = try protocol.respond(a, initialized[0 .. initialized.len - 1], .{ .requested = &f.flag });
    try f.snapshot_.root.dir.deleteFile(io, "file.txt");
    const raw = read_request[0 .. read_request.len - 1];
    const output_limit = f.grants[0].config.output_bytes + 2048;
    const baseline = f.budget.usage().bytes;
    var frame_credit = try f.budget.reserve(f.grants[0].config.session, .{ .input_bytes = raw.len, .parser_bytes = 65536 + raw.len * 6, .scratch_bytes = 4 * core.limits.MiB, .output_bytes = output_limit });
    var allocation = memory.ReservedAllocator.init(A, &frame_credit, &f.counters, null);
    var frame_arena = std.heap.ArenaAllocator.init(allocation.allocator());
    var has_frame = true;
    defer if (has_frame) broker.finishPreparedFrame(&f.budget, &frame_arena, &frame_credit, &has_frame) catch unreachable;
    var pending: broker.BufferedCancellations = .{};
    try pending.observe(read_request, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}");
    try t.expect(pending.contains(0));
    var state = std.atomic.Value(u8).init(0);
    var output: []const u8 = "";
    var next_request: u64 = 1;
    try broker.submitPreparedFrame(.{ .executor = &f.executor_, .budget = &f.budget, .session = f.grants[0].config.session, .saved_cancelled = pending.contains(0), .cancel = &cancelled, .next_request = &next_request, .callback = Callback.run, .userdata = &callback_ran, .protocol = &protocol, .allocator = frame_arena.allocator(), .raw = raw, .frame_limit = 64 * 1024, .output_limit = output_limit, .job_state = &state, .output = &output });
    try t.expect(!callback_ran.load(.acquire));
    try t.expectEqual(@as(u8, 2), state.load(.acquire));
    try t.expect(!frame_credit.released);
    const response = output;
    try t.expect(std.mem.indexOf(u8, response, "\"id\":2") != null);
    try t.expect(std.mem.indexOf(u8, response, "E_CANCELLED") != null);
    try t.expect(std.mem.indexOf(u8, response, "Resource exhausted") == null);
    try broker.finishPreparedFrame(&f.budget, &frame_arena, &frame_credit, &has_frame);
    try t.expect(!has_frame and frame_credit.released);
    try t.expectEqual(baseline, f.budget.usage().bytes);
}

test "BR-003 unit wave2 failed outbound send drains retained inbound before disconnect" {
    var input_pipe: [2]std.c.fd_t = undefined;
    var output_pipe: [2]std.c.fd_t = undefined;
    var send_pipe: [2]std.c.fd_t = undefined;
    try t.expect(Pipes.pipe(&input_pipe) == 0);
    defer for (input_pipe) |fd| {
        _ = std.c.close(fd);
    };
    try t.expect(Pipes.pipe(&output_pipe) == 0);
    defer _ = std.c.close(output_pipe[0]);
    try t.expect(Pipes.pipe(&send_pipe) == 0);
    defer for (send_pipe) |fd| {
        _ = std.c.close(fd);
    };
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    try t.expect(std.c.fcntl(output_pipe[1], std.c.F.SETFL, nonblock) == 0);
    const filler: [4096]u8 = @splat('x');
    var filled: usize = 0;
    while (true) {
        const n = std.c.write(output_pipe[1], &filler, filler.len);
        if (n < 0) break;
        filled += @intCast(n);
    }
    try t.expect(filled != 0);
    try t.expect(std.c.write(input_pipe[1], "next\n", 5) == 5);
    const Run = struct {
        client: broker.bridge.Client,
        input: std.c.fd_t,
        output: std.c.fd_t,
        done: std.atomic.Value(bool) = .init(false),
        cancel: std.atomic.Value(bool) = .init(false),
        result: ?anyerror = null,
        fn execute(self: *@This()) void {
            self.client.forward(.{ .handle = self.input, .flags = .{ .nonblocking = false } }, .{ .handle = self.output, .flags = .{ .nonblocking = true } }, .{ .requested = &self.cancel }) catch |err| {
                self.result = err;
            };
            _ = std.c.close(self.output);
            self.done.store(true, .release);
        }
    };
    var run: Run = .{ .client = .{ .fd = send_pipe[1] }, .input = input_pipe[0], .output = output_pipe[1] };
    const response = "final-response\n";
    @memcpy(run.client.received[0..response.len], response);
    run.client.received_end = response.len;
    const thread = try std.Thread.spawn(.{}, Run.execute, .{&run});
    defer {
        run.cancel.store(true, .release);
        thread.join();
    }
    // Retain backpressure until the bridge has had bounded progress through its
    // fatal send (send on the writable pipe is ENOTSOCK, requiring no UDS).
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (!run.done.load(.acquire) and started.untilNow(io).raw.toMilliseconds() < 100) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    var bytes: [8192]u8 = undefined;
    var remaining = filled;
    while (remaining != 0) {
        const n = std.c.read(output_pipe[0], &bytes, @min(remaining, bytes.len));
        try t.expect(n > 0);
        remaining -= @intCast(n);
    }
    const n = std.c.read(output_pipe[0], &bytes, bytes.len);
    try t.expect(n > 0);
    try t.expectEqualStrings(response, bytes[0..@intCast(n)]);
    while (!run.done.load(.acquire) and started.untilNow(io).raw.toMilliseconds() < 5000) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try t.expect(run.done.load(.acquire));
    try t.expectEqual(error.Disconnected, run.result.?);
}

test "BR-004 coalesced UDS request and cancellation cancel the preceding idle request" {
    const f = try Fixture.init(1);
    defer f.deinit();
    try f.start();
    var client = try f.connect(0);
    defer client.close();
    try startProtocol(&client);
    try client.sendAll(read_request ++ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}\n");
    var buffer: [8192]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, try client.readLine(&buffer), "E_CANCELLED") != null);
}

/// A running broker refuses this grant during authentication: the peer closes the connection after
/// the hello and the server counts one more refusal. A missing listener (IoFailure) does not qualify.
/// The counter is read before connecting, because the server counts the refusal before the client
/// observes the closed connection.
fn expectAuthRefused(f: *Fixture, grant: usize) !void {
    const before = f.server.?.snapshot().refused;
    if (f.connect(grant)) |value| {
        var client = value;
        client.close();
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.OutOfScope, error.Disconnected => {},
        else => return err,
    }
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (f.server.?.snapshot().refused == before and started.untilNow(io).raw.toMilliseconds() < 5000) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try t.expectEqual(before + 1, f.server.?.snapshot().refused);
}

test "BR-005 real UDS stale grant is refused and a broker restart needs a host rebind at a new fence and the bridge does not reconnect or resend" {
    const f = try Fixture.init(2);
    defer f.deinit();
    const session = f.grants[0].config.session;
    const bridge_session = f.grants[1].config.session;
    const old_task: core.TaskContext = .{ .task_id = session.bound_task, .base_commit = f.snapshot_.head[0..f.snapshot_.head_len], .scope_digest = read_policy.digest, .fence = 1, .expires_at_unix_ms = std.math.maxInt(i64) };
    var new_task = old_task;
    new_task.fence = 2;
    var bridge_task = new_task;
    bridge_task.task_id = bridge_session.bound_task;
    var buffer: [8192]u8 = undefined;
    try f.start();
    // Grant 1's bridge client stays open across the broker restart.
    var stale = try f.connect(1);
    defer stale.close();
    try startProtocol(&stale);

    // Grant 0 reads and disconnects. Closing the session ends its host binding, so the running,
    // listening broker refuses the same grant at authentication.
    {
        var client = try f.connect(0);
        defer client.close();
        try startProtocol(&client);
        try client.sendAll(read_request);
        try t.expect(std.mem.indexOf(u8, try client.readLine(&buffer), "\"id\":2") != null);
    }
    const drained = std.Io.Clock.Timestamp.now(io, .awake);
    while (f.server.?.snapshot().connected != 1 and drained.untilNow(io).raw.toMilliseconds() < 5000) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try t.expectEqual(@as(u32, 1), f.server.?.snapshot().connected);
    try expectAuthRefused(f, 0);

    // Broker restart: the old instance closes every session, which ends every host binding.
    // A broker cannot even be created for unbound grants.
    f.server.?.stop();
    f.thread.?.join();
    f.thread = null;
    try t.expect(f.run_error == null);
    try f.server.?.deinit();
    f.server = null;
    // Through Fixture.start, like every other test: Server.create keeps its large per-session
    // temporaries in that frame. Inlined into this test, they overflowed the ReleaseSafe stack.
    try t.expectError(error.OutOfScope, f.start());
    try t.expect(f.server == null and f.thread == null);

    // Only the host can bind the sessions again, at a new fence. The old fence stays invalid.
    try f.registry.bindSession(session, new_task, f.registry.bootNonce());
    try f.registry.bindSession(bridge_session, bridge_task, f.registry.bootNonce());
    try t.expectError(error.FenceMismatch, f.registry.acquireWriter(old_task, session.bound_workspace));
    try f.start();

    // The old bridge gets a request its broker never answers. Its forward path must end with
    // Disconnected, write no response, and neither reconnect to the restarted broker nor resend.
    var input: [2]std.c.fd_t = undefined;
    var output: [2]std.c.fd_t = undefined;
    try t.expect(Pipes.pipe(&input) == 0);
    try t.expect(Pipes.pipe(&output) == 0);
    defer _ = std.c.close(output[0]);
    const Run = struct {
        client: *broker.bridge.Client,
        input: std.c.fd_t,
        output: std.c.fd_t,
        flag: *std.atomic.Value(bool),
        result: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(r: *@This()) void {
            defer r.done.store(true, .release);
            defer _ = std.c.close(r.output);
            defer _ = std.c.close(r.input);
            r.client.forward(.{ .handle = r.input, .flags = .{ .nonblocking = false } }, .{ .handle = r.output, .flags = .{ .nonblocking = false } }, .{ .requested = r.flag }) catch |err| {
                r.result = err;
            };
        }
    };
    const unanswered = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{\"path\":\"file.txt\"}}}\n";
    try t.expectEqual(@as(isize, unanswered.len), std.c.write(input[1], unanswered.ptr, unanswered.len));
    _ = std.c.close(input[1]);
    var run: Run = .{ .client = &stale, .input = input[0], .output = output[1], .flag = &f.flag };
    const thread = try std.Thread.spawn(.{}, Run.run, .{&run});
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (!run.done.load(.acquire) and started.untilNow(io).raw.toMilliseconds() < 5000) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    if (!run.done.load(.acquire)) f.flag.store(true, .release);
    thread.join();
    try t.expectEqual(error.Disconnected, run.result.?);
    try t.expectEqual(@as(isize, 0), std.c.read(output[0], &buffer, buffer.len));
    const after = f.server.?.snapshot();
    try t.expectEqual(@as(u32, 0), after.authenticated);
    try t.expectEqual(@as(u64, 0), after.completed);
    try t.expectEqual(@as(u64, 0), after.refused);

    // The rebound grant connects to the restarted broker and is served normally.
    var client = try f.connect(0);
    defer client.close();
    try startProtocol(&client);
    try client.sendAll("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n");
    try t.expect(std.mem.indexOf(u8, try client.readLine(&buffer), "\"id\":9") != null);
}
