const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const watch = @import("zcr_watch");
const t = std.testing;
const io = t.io;
var cancel_flag: std.atomic.Value(bool) = .init(false);
const id: core.WorkspaceId = .{ .registry_uuid = @splat(1), .incarnation = @splat(2) };
test "WA-001 native Linux starts watching before a file created during initial scan" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const absolute = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(absolute);
    var index = try watch.Index.init(io, id, 4);
    const Receiver = struct {
        fn push(context: *anyopaque, event: core.WatchEvent) void {
            const i: *watch.Index = @ptrCast(@alignCast(context));
            _ = i.invalidate(id, event) catch unreachable;
        }
    };
    var backend: watch.linux.Backend = .{};
    try backend.start(io, .{ .dir = tmp.dir, .canonical_path = absolute }, .{ .context = &index, .push = Receiver.push }, 8);
    defer backend.stop(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "during-scan.txt", .data = "new file" });
    try t.expect(try backend.poll(io, .{ .requested = &cancel_flag }) > 0);
    try t.expect(index.snapshot().full_dirty);
}
test "WA-003 dropped events mark the workspace uncertain before latest requests" {
    var index = try watch.Index.init(io, id, 4);
    try t.expectEqual(core.IndexState.uncertain, try index.invalidate(id, .{ .kind = .dropped, .path = null, .cursor = 1 }));
    try t.expect(index.snapshot().full_dirty);
}
test "WA-005 event storm promotes the bounded queue to whole workspace dirty" {
    var index = try watch.Index.init(io, id, 2);
    index.state = .live;
    index.full_dirty = false;
    for ([_][]const u8{ "a/file", "b/file" }, 0..) |path, n| {
        _ = try index.invalidate(id, .{ .kind = .modified, .path = .{ .bytes = path }, .cursor = n + 1 });
    }
    try t.expectEqual(@as(usize, 2), index.snapshot().dirty_count);
    try t.expect(!index.snapshot().full_dirty);
    _ = try index.invalidate(id, .{ .kind = .modified, .path = .{ .bytes = "c/file" }, .cursor = 3 });
    try t.expect(index.snapshot().full_dirty);
    try t.expectEqual(core.IndexState.uncertain, index.snapshot().state);
    try t.expect(index.snapshot().dirty_count <= 2);
}

const memory = @import("zcr_memory");
const workspace = @import("zcr_workspace");
const policy_mod = @import("zcr_policy");
const read_policy: core.Policy = .{ .digest = @splat(14), .state = .active, .read_paths = &.{.{ .bytes = "." }}, .write_paths = &.{}, .immutable_paths = &.{.{ .bytes = ".git" }}, .operations = &.{ .read, .enumerate, .search }, .max_changed_files = 1 };
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    registry: workspace.Registry,
    authorizer: policy_mod.Authorizer = undefined,
    root: core.TrustedRoot = undefined,
    context: core.SessionContext = undefined,
    counters: memory.accounting.Counters = .{},
    work_counters: memory.accounting.Counters = .{},
    budget: memory.Budget = undefined,
    work_budget: memory.Budget = undefined,
    flag: std.atomic.Value(bool) = .init(false),
    runtime: *watch.Runtime = undefined,
    fn init(limit: usize) !*Fixture {
        const f = try t.allocator.create(Fixture);
        f.* = .{ .arena = .init(t.allocator), .tmp = t.tmpDir(.{}), .registry = try workspace.Registry.init(t.allocator, io, .{ .git_executable = "/usr/bin/git" }) };
        const a = f.arena.allocator();
        try f.tmp.dir.createDir(io, "repo", .default_dir);
        const path = try f.tmp.dir.realPathFileAlloc(io, "repo", a);
        const root_dir = try f.tmp.dir.openDir(io, "repo", .{});
        defer root_dir.close(io);
        try f.git(path, &.{ "init", "-q", "-b", "main" });
        try root_dir.writeFile(io, .{ .sub_path = "initial.txt", .data = "initial\n" });
        try f.git(path, &.{ "add", "." });
        try f.git(path, &.{ "-c", "user.name=T14", "-c", "user.email=t14@example.invalid", "commit", "-q", "-m", "fixture" });
        const workspace_id = try f.registry.registerWorkspace(io, .{ .dir = root_dir, .canonical_path = path }, read_policy);
        const snap = try f.registry.snapshot(workspace_id);
        f.root = snap.root;
        f.context = .{ .session_id = .{ .uuid = @splat(1) }, .security_domain = .{ .id = 14 }, .policy_digest = read_policy.digest, .bound_workspace = workspace_id, .bound_task = .{ .uuid = @splat(2) }, .capability_handle = @enumFromInt(1) };
        try f.registry.bindSession(f.context, .{ .task_id = f.context.bound_task, .base_commit = snap.head[0..snap.head_len], .scope_digest = read_policy.digest, .fence = 1, .expires_at_unix_ms = std.math.maxInt(i64) }, f.registry.bootNonce());
        f.authorizer = try policy_mod.Authorizer.init(a, io, f.root, workspace_id, f.context.bound_task, read_policy, snap.git);
        f.budget = memory.Budget.init(14, .{ .bytes = 8 * core.limits.MiB, .fds = 8, .cpu = 0, .output_bytes = 0 }, &f.counters);
        f.work_budget = memory.Budget.init(15, .{ .bytes = 8 * core.limits.MiB, .fds = 160, .cpu = 8, .output_bytes = 0 }, &f.work_counters);
        f.runtime = try watch.Runtime.create(t.allocator, io, &f.budget, &f.registry, &f.authorizer, f.context, .{ .work_budget = &f.work_budget, .watch_limit = limit });
        return f;
    }
    fn cancel(f: *Fixture) core.Cancel {
        return .{ .requested = &f.flag };
    }
    fn cap(f: *Fixture, op: core.Operation) !core.Capability {
        return f.authorizer.authorize(io, f.context, op, .{ .bytes = "." });
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
        if (result.term != .exited or result.term.exited != 0) return error.FixtureGit;
    }
    fn deinit(f: *Fixture) void {
        f.runtime.deinit() catch unreachable;
        t.expectEqual(@as(u64, 0), f.budget.usage().bytes) catch unreachable;
        t.expectEqual(@as(u16, 0), f.budget.usage().fds) catch unreachable;
        t.expectEqual(@as(u64, 0), f.work_budget.usage().bytes) catch unreachable;
        t.expectEqual(@as(u16, 0), f.work_budget.usage().fds) catch unreachable;
        t.expectEqual(@as(u8, 0), f.work_budget.usage().cpu) catch unreachable;
        t.expectEqual(@as(u64, 0), f.counters.live_bytes.load(.monotonic)) catch unreachable;
        t.expectEqual(@as(u64, 0), f.work_counters.live_bytes.load(.monotonic)) catch unreachable;
        f.registry.deinit() catch unreachable;
        f.arena.deinit();
        f.tmp.cleanup();
        t.allocator.destroy(f);
    }
};
const Collector = struct {
    count: usize = 0,
    saw_late: bool = false,
    fn push(context: *anyopaque, path: core.RelativePath) core.SinkError!void {
        const c: *Collector = @ptrCast(@alignCast(context));
        c.count += 1;
        if (std.mem.eql(u8, path.bytes, "late.txt") or std.mem.eql(u8, path.bytes, "new/deep/file.txt")) c.saw_late = true;
    }
    fn sink(c: *Collector) core.Sink(core.RelativePath) {
        return .{ .context = c, .push_fn = push };
    }
};
test "WA-001 scan-time native events require reconciliation before generation publish" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(16);
    defer f.deinit();
    try f.runtime.start(f.cancel());
    const Hook = struct {
        fixture: *Fixture,
        fired: bool = false,
        generation_during_scan: u64 = 999,
        fn run(context: *anyopaque) void {
            const h: *@This() = @ptrCast(@alignCast(context));
            if (h.fired) return;
            h.fired = true;
            h.generation_during_scan = h.fixture.runtime.index.snapshot().generation;
            h.fixture.root.dir.writeFile(io, .{ .sub_path = "late.txt", .data = "created during scan\n" }) catch unreachable;
        }
    };
    var hook = Hook{ .fixture = f };
    f.runtime.test_hook = .{ .context = &hook, .after_first_path = Hook.run };
    const before = (try f.registry.snapshot(f.context.bound_workspace)).generation;
    const result = try f.runtime.reconcile(f.cancel());
    try t.expect(result.complete);
    try t.expect(result.passes >= 2);
    try t.expectEqual(@as(u64, 2), result.files_seen);
    try t.expectEqual(@as(u64, 0), hook.generation_during_scan);
    try t.expectEqual(before + 1, result.snapshot.generation);
}
test "WA-002 coalesced subtree dirties trigger a covering rescan with bounded path ownership" {
    var index = try watch.Index.init(io, id, 4);
    index.state = .live;
    index.full_dirty = false;
    for ([_][]const u8{ "src/a", "src/deep/b", "src-other/c" }, 0..) |path, n| _ = try index.invalidate(id, .{ .kind = .modified, .path = .{ .bytes = path }, .cursor = n + 1 });
    try t.expectEqual(@as(usize, 2), index.snapshot().dirty_count);
    var out: [4]watch.Dirty = undefined;
    try t.expectEqual(@as(usize, 2), index.copyDirty(&out));
    try t.expectEqualStrings("src", out[0].path());
    try t.expectEqualStrings("src-other", out[1].path());
    _ = try index.invalidate(id, .{ .kind = .modified, .path = .{ .bytes = "root.txt" }, .cursor = 4 });
    try t.expectEqual(@as(usize, 1), index.copyDirty(&out));
    try t.expectEqualStrings(".", out[0].path());
}
test "WA-003 uncertain watcher state retains latest live file coverage and recovers only after scan" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(16);
    defer f.deinit();
    try f.runtime.start(f.cancel());
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
    const generation = f.runtime.index.snapshot().generation;
    _ = try f.runtime.index.invalidate(f.context.bound_workspace, .{ .kind = .dropped, .path = null, .cursor = 50 });
    try t.expectEqual(generation, f.runtime.index.snapshot().generation);
    var c: Collector = .{};
    const live = try f.runtime.enumerateLive(try f.cap(.enumerate), .{}, c.sink(), f.cancel());
    try t.expect(live.report.complete);
    try t.expectEqual(core.IndexState.uncertain, live.coverage.index_state);
    try t.expectEqual(@as(usize, 1), c.count);
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
}
test "WA-004 moved root rejects the old incarnation and event cursor wrap remains uncertain" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(16);
    defer f.deinit();
    try f.runtime.start(f.cancel());
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
    _ = try f.runtime.index.invalidate(f.context.bound_workspace, .{ .kind = .cursor_wrapped, .path = null, .cursor = 0 });
    try t.expectEqual(core.IndexState.uncertain, f.runtime.index.snapshot().state);
    try f.tmp.dir.rename("repo", f.tmp.dir, "moved", io);
    try t.expectError(error.OutOfScope, f.runtime.poll(f.cancel()));
    var c: Collector = .{};
    try t.expectError(error.OutOfScope, f.runtime.enumerateLive(.{ .handle = @enumFromInt(1), .workspace_id = f.context.bound_workspace, .task_id = f.context.bound_task, .policy_digest = read_policy.digest, .operation = .enumerate, .path = .{ .bytes = "." } }, .{}, c.sink(), f.cancel()));
}
test "WA-005 native recursive watch saturation stays uncertain while live traversal finds nested files" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(1);
    defer f.deinit();
    try f.root.dir.createDirPath(io, "new/deep");
    try f.root.dir.writeFile(io, .{ .sub_path = "new/deep/file.txt", .data = "nested" });
    try f.runtime.start(f.cancel());
    const result = try f.runtime.reconcile(f.cancel());
    try t.expect(!result.complete);
    try t.expectEqual(core.IndexState.uncertain, result.snapshot.state);
    try t.expectEqual(@as(usize, 1), f.runtime.backend.watchedCount());
    var c: Collector = .{};
    const live = try f.runtime.enumerateLive(try f.cap(.enumerate), .{}, c.sink(), f.cancel());
    try t.expect(live.report.complete);
    try t.expect(c.saw_late);
}
test "WA-006 checked live files and search see late files without polling apparently clean hints" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(16);
    defer f.deinit();
    try f.runtime.start(f.cancel());
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
    try f.root.dir.writeFile(io, .{ .sub_path = "late.txt", .data = "new content" });
    try t.expectEqual(core.IndexState.live, f.runtime.index.snapshot().state);
    var files: Collector = .{};
    var search: Collector = .{};
    const result = try f.runtime.enumerateLive(try f.cap(.enumerate), .{}, files.sink(), f.cancel());
    const candidates = try f.runtime.searchCandidatesLive(try f.cap(.search), .{}, search.sink(), f.cancel());
    try t.expect(result.report.complete and candidates.report.complete);
    try t.expect(files.saw_late and search.saw_late);
    try t.expectEqual(@as(usize, 2), files.count);
    const scope_cap = try f.cap(.enumerate);
    var forged = scope_cap;
    forged.workspace_id = id;
    try t.expectError(error.OutOfScope, f.runtime.enumerateLive(forged, .{}, files.sink(), f.cancel()));
    try f.registry.unbindSession(f.context.session_id, f.registry.bootNonce());
    try t.expectError(error.OutOfScope, f.runtime.enumerateLive(scope_cap, .{}, files.sink(), f.cancel()));
}

test "WA-001 new directories after recursive refresh lose sync until watches cover the subtree" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(16);
    defer f.deinit();
    try f.runtime.start(f.cancel());
    _ = try f.runtime.backend.poll(io, f.cancel());
    try t.expect(f.runtime.backend.synchronized());
    try f.root.dir.createDirPath(io, "new/deep");
    try f.root.dir.writeFile(io, .{ .sub_path = "new/deep/file.txt", .data = "first" });
    _ = try f.runtime.backend.poll(io, f.cancel());
    try t.expect(!f.runtime.backend.synchronized());
    f.runtime.backend.test_force_unknown = true;
    try t.expect(try f.runtime.backend.refresh(io, f.root, f.cancel()));
    _ = try f.runtime.backend.poll(io, f.cancel());
    try t.expect(f.runtime.backend.synchronized());
    try t.expectEqual(@as(usize, 3), f.runtime.backend.watchedCount());
    try f.root.dir.writeFile(io, .{ .sub_path = "new/deep/file.txt", .data = "later" });
    try t.expect(try f.runtime.backend.poll(io, f.cancel()) > 0);
}
test "WA-004 native watch slots recover from directory churn and an ignored root" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(2);
    defer f.deinit();
    try f.runtime.start(f.cancel());
    for (0..4) |n| {
        var name: [16]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "dir-{d}", .{n});
        try f.root.dir.createDir(io, path, .default_dir);
        _ = try f.runtime.reconcile(f.cancel());
        try t.expect((try f.runtime.reconcile(f.cancel())).complete);
        try t.expectEqual(@as(usize, 2), f.runtime.backend.watchedCount());
        try f.root.dir.deleteTree(io, path);
        _ = try f.runtime.poll(f.cancel());
    }
    const root_wd = f.runtime.backend.watches[0].wd;
    const rc = std.os.linux.inotify_rm_watch(f.runtime.backend.fd.?, root_wd);
    try t.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
    _ = try f.runtime.backend.poll(io, f.cancel());
    try t.expectEqual(@as(usize, 0), f.runtime.backend.watchedCount());
    _ = try f.runtime.reconcile(f.cancel());
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
    try t.expectEqual(@as(usize, 1), f.runtime.backend.watchedCount());
}
test "WA-003 malformed and kernel-overflow records fail closed and cursor wrap cannot overflow" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(4);
    defer f.deinit();
    try f.runtime.start(f.cancel());
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
    var event: [16]u8 = @splat(0);
    std.mem.writeInt(i32, event[0..4], -1, builtin.cpu.arch.endian());
    std.mem.writeInt(u32, event[4..8], std.os.linux.IN.Q_OVERFLOW, builtin.cpu.arch.endian());
    f.runtime.backend.cursor = std.math.maxInt(u64);
    try t.expectEqual(@as(usize, 1), f.runtime.backend.decode(&event));
    try t.expectEqual(@as(u64, 1), f.runtime.backend.cursor);
    try t.expectEqual(core.IndexState.uncertain, f.runtime.index.snapshot().state);
    try t.expect(!f.runtime.backend.synchronized());
    _ = try f.runtime.reconcile(f.cancel());
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
    std.mem.writeInt(u32, event[12..16], std.math.maxInt(u32), builtin.cpu.arch.endian());
    _ = f.runtime.backend.decode(&event);
    try t.expectEqual(core.IndexState.uncertain, f.runtime.index.snapshot().state);
    try t.expectError(error.InvariantViolation, f.runtime.index.invalidate(id, .{ .kind = .modified, .path = .{ .bytes = "a" }, .cursor = 4 }));
}
test "WA-005 control and native scan credits refuse before allocation and release exactly" {
    const f = try Fixture.init(4);
    defer f.deinit();
    try t.expectEqual(@as(u64, @sizeOf(watch.Runtime)), f.budget.usage().bytes);
    const allocations = f.counters.allocations.load(.monotonic);
    f.budget.caps.bytes = f.budget.usage().bytes;
    try t.expectError(error.ResourceExhausted, watch.Runtime.create(t.allocator, io, &f.budget, &f.registry, &f.authorizer, f.context, .{ .work_budget = &f.work_budget }));
    try t.expectEqual(allocations, f.counters.allocations.load(.monotonic));
    f.work_budget.caps.cpu = 0;
    try t.expectError(error.ResourceExhausted, f.runtime.start(f.cancel()));
    try t.expect(!f.runtime.started);
    f.work_budget.caps.cpu = 1;
    f.work_budget.caps.fds = 0;
    var c: Collector = .{};
    try t.expectError(error.ResourceExhausted, f.runtime.enumerateLive(try f.cap(.enumerate), .{}, c.sink(), f.cancel()));
    f.work_budget.caps.fds = 160;
    const live = try f.runtime.enumerateLive(try f.cap(.enumerate), .{}, c.sink(), f.cancel());
    try t.expect(live.report.complete);
    try t.expectEqualStrings(".", live.coverage.scope);
    try t.expectEqual(@as(u64, 0), f.work_budget.usage().bytes);
    try t.expectEqual(@as(u8, 0), f.work_budget.usage().cpu);
}
test "WA-003 cancellation and deadline refuse publication and drain every scan resource" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(8);
    defer f.deinit();
    try t.expectError(error.DeadlineExceeded, f.runtime.start(f.cancel().withTimeout(io, 0)));
    try t.expect(!f.runtime.started);
    try f.runtime.start(f.cancel());
    const Hook = struct {
        fn run(context: *anyopaque) void {
            const fixture: *Fixture = @ptrCast(@alignCast(context));
            fixture.flag.store(true, .release);
        }
    };
    f.runtime.test_hook = .{ .context = f, .after_first_path = Hook.run };
    try t.expectError(error.Cancelled, f.runtime.reconcile(f.cancel()));
    try t.expectEqual(@as(u64, 0), f.runtime.index.snapshot().generation);
    try t.expectEqual(core.IndexState.uncertain, f.runtime.index.snapshot().state);
    try t.expectEqual(@as(u64, 0), f.work_budget.usage().bytes);
    try t.expectEqual(@as(u16, 0), f.work_budget.usage().fds);
    try t.expectEqual(@as(u8, 0), f.work_budget.usage().cpu);
    f.flag.store(false, .release);
    f.runtime.test_hook = null;
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
}
test "WA-005 all control and traversal allocation failures unwind without losing caller state" {
    const f = try Fixture.init(4);
    defer f.deinit();
    const Scenario = struct {
        fn run(a: std.mem.Allocator, fixture: *Fixture) !void {
            const runtime = try watch.Runtime.create(a, io, &fixture.budget, &fixture.registry, &fixture.authorizer, fixture.context, .{ .work_budget = &fixture.work_budget });
            defer runtime.deinit() catch unreachable;
            var c: Collector = .{};
            const result = try runtime.enumerateLive(try fixture.cap(.enumerate), .{}, c.sink(), fixture.cancel());
            try t.expect(result.report.complete);
            try t.expectEqual(@as(usize, 1), c.count);
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Scenario.run, .{f});
    try t.expectEqual(@as(u64, @sizeOf(watch.Runtime)), f.budget.usage().bytes);
    try t.expectEqual(@as(u64, 0), f.work_budget.usage().bytes);
}
test "WA-005 concurrent callback ingestion remains bounded and actor reentry is refused" {
    const f = try Fixture.init(4);
    defer f.deinit();
    f.runtime.index.state = .live;
    f.runtime.index.full_dirty = false;
    const Job = struct {
        index: *watch.Index,
        key: core.WorkspaceId,
        fn run(job: *@This()) void {
            for (0..300) |n| {
                _ = job.index.invalidate(job.key, .{ .kind = .modified, .path = .{ .bytes = "dir/file" }, .cursor = n + 1 }) catch unreachable;
                _ = job.index.snapshot();
            }
        }
    };
    var job = Job{ .index = &f.runtime.index, .key = f.context.bound_workspace };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Job.run, .{&job});
    for (threads) |thread| thread.join();
    try t.expectEqual(@as(u64, 1201), f.runtime.index.snapshot().epoch);
    try t.expect(f.runtime.index.snapshot().dirty_count <= 32);
    const Sink = struct {
        f: *Fixture,
        called: bool = false,
        fn push(raw: *anyopaque, _: core.RelativePath) core.SinkError!void {
            const s: *@This() = @ptrCast(@alignCast(raw));
            s.called = true;
            if (s.f.runtime.poll(s.f.cancel())) |_| unreachable else |err| {
                if (err != error.Busy) unreachable;
            }
            if (s.f.runtime.deinit()) |_| unreachable else |err| {
                if (err != error.Busy) unreachable;
            }
        }
    };
    var sink = Sink{ .f = f };
    _ = try f.runtime.enumerateLive(try f.cap(.enumerate), .{}, .{ .context = &sink, .push_fn = Sink.push }, f.cancel());
    try t.expect(sink.called);
}
test "WA-006 live traversal reports actual truncation and ignore coverage after watcher loss" {
    const f = try Fixture.init(4);
    defer f.deinit();
    try f.root.dir.writeFile(io, .{ .sub_path = "late.txt", .data = "second" });
    _ = try f.runtime.index.invalidate(f.context.bound_workspace, .{ .kind = .dropped, .path = null, .cursor = 1 });
    var c: Collector = .{};
    const result = try f.runtime.enumerateLive(try f.cap(.enumerate), .{ .limit = 1 }, c.sink(), f.cancel());
    try t.expect(!result.report.complete);
    try t.expect(result.report.truncated);
    try t.expectEqual(core.IndexState.uncertain, result.coverage.index_state);
    try t.expectEqualStrings(".", result.coverage.scope);
    var oversized: [core.limits.values.max_ignore_file_bytes + 1]u8 = @splat('x');
    try f.root.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = &oversized });
    var ignored: Collector = .{};
    const partial = try f.runtime.enumerateLive(try f.cap(.enumerate), .{}, ignored.sink(), f.cancel());
    try t.expect(!partial.report.complete);
    try t.expect(partial.coverage.skipped > 0);
    try t.expect(partial.coverage.reasons.len > 0);
}

test "WA-002 watcher invalidation detaches mutable cache associations while pins retain bytes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const cache = @import("zcr_cache");
    const f = try Fixture.init(4);
    defer f.deinit();
    const store = try cache.Store.create(t.allocator, io, &f.budget, f.context, .{ .verification_budget = &f.work_budget });
    defer store.deinit() catch unreachable;
    f.runtime.options.content_cache = store;
    var session = try cache.Session.init(store, &f.registry, &f.authorizer, f.context, f.cancel());
    const cap = try f.authorizer.authorize(io, f.context, .read, .{ .bytes = "initial.txt" });
    const file = try f.root.dir.openFile(io, "initial.txt", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const identity = try policy_mod.paths.statHandle(file.handle);
    var digest: core.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash("initial\n", &digest, .{});
    const version: core.FileVersion = .{ .workspace_id = f.context.bound_workspace, .file_id = .{ .device = identity.identity.device, .inode = identity.identity.inode }, .generation = (try f.registry.snapshot(f.context.bound_workspace)).generation, .size = stat.size, .mtime_ns = stat.mtime.nanoseconds, .sha256 = digest };
    _ = try session.observe(cap, "initial\n", version, .interactive);
    _ = try session.observe(cap, "initial\n", version, .interactive);
    const pin = (try session.cacheGetChecked(digest, cap, .{ .max_pinned_bytes = 1024 })).?;
    try f.runtime.start(f.cancel());
    _ = try f.runtime.index.invalidate(f.context.bound_workspace, .{ .kind = .modified, .path = .{ .bytes = "initial.txt" }, .cursor = 20 });
    _ = try f.runtime.poll(f.cancel());
    try t.expectEqualStrings("initial\n", pin.bytes);
    try t.expectEqual(@as(usize, 1), store.stats().associations);
    try session.unpin(pin);
    try t.expectEqual(@as(usize, 0), store.stats().associations);
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
    const refreshed = (try session.cacheGetChecked(digest, cap, .{ .max_pinned_bytes = 1024 })).?;
    try session.unpin(refreshed);
}
test "WA-006 no-follow native registration and live traversal never enter an outside symlink" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const f = try Fixture.init(8);
    defer f.deinit();
    try f.tmp.dir.createDir(io, "outside", .default_dir);
    const absolute = try f.tmp.dir.realPathFileAlloc(io, "outside", f.arena.allocator());
    const outside = try f.tmp.dir.openDir(io, "outside", .{});
    defer outside.close(io);
    try outside.writeFile(io, .{ .sub_path = "secret.txt", .data = "outside" });
    try f.root.dir.symLink(io, absolute, "escape", .{ .is_directory = true });
    try f.runtime.start(f.cancel());
    try t.expect((try f.runtime.reconcile(f.cancel())).complete);
    try t.expectEqual(@as(usize, 1), f.runtime.backend.watchedCount());
    try outside.writeFile(io, .{ .sub_path = "later.txt", .data = "outside changes" });
    try t.expectEqual(@as(usize, 0), try f.runtime.backend.poll(io, f.cancel()));
    var c: Collector = .{};
    const result = try f.runtime.enumerateLive(try f.cap(.enumerate), .{}, c.sink(), f.cancel());
    try t.expectEqual(@as(usize, 1), c.count);
    try t.expectEqual(@as(u64, 1), result.report.symlinks_not_followed);
    const Sink = struct {
        fn push(_: *anyopaque, _: core.RelativePath) core.SinkError!void {
            return error.OutputBudgetExceeded;
        }
    };
    try t.expectError(error.OutputBudgetExceeded, f.runtime.enumerateLive(try f.cap(.enumerate), .{}, .{ .context = &c, .push_fn = Sink.push }, f.cancel()));
    try t.expectEqual(@as(u64, 0), f.work_budget.usage().bytes);
    try t.expectEqual(@as(u16, 0), f.work_budget.usage().fds);
}
