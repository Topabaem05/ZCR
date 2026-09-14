//! Native Git worktree and writer lifecycle tests (T10).
const std = @import("std");
const core = @import("zcr_core");
const workspace = @import("zcr_workspace");
const t = std.testing;
const io = t.io;
const A = t.allocator;
const policy: core.Policy = .{ .digest = @splat(9), .state = .active, .read_paths = &.{.{ .bytes = "." }}, .write_paths = &.{.{ .bytes = "file.txt" }}, .immutable_paths = &.{.{ .bytes = ".git" }}, .operations = &.{ .read, .patch, .create }, .max_changed_files = 1 };
const Fixture = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    fn init() !Fixture {
        var f: Fixture = .{ .tmp = t.tmpDir(.{}), .arena = .init(A) };
        errdefer f.deinit();
        try f.tmp.dir.createDir(io, "repo", .default_dir);
        _ = try f.git("repo", &.{ "init", "-q", "-b", "main" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/file.txt", .data = "base\n" });
        _ = try f.git("repo", &.{ "add", "." });
        _ = try f.git("repo", &.{ "-c", "user.name=T10", "-c", "user.email=t10@example.invalid", "commit", "-q", "-m", "base" });
        return f;
    }
    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }
    fn path(f: *Fixture, name: []const u8) ![]const u8 {
        return f.tmp.dir.realPathFileAlloc(io, name, f.arena.allocator());
    }
    fn git(f: *Fixture, name: []const u8, args: []const []const u8) ![]const u8 {
        const a = f.arena.allocator();
        const argv = try a.alloc([]const u8, args.len + 3);
        argv[0] = "/usr/bin/git";
        argv[1] = "-C";
        argv[2] = try f.path(name);
        @memcpy(argv[3..], args);
        var env: std.process.Environ.Map = .init(a);
        try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        const result = try std.process.run(a, io, .{ .argv = argv, .environ_map = &env, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        std.debug.print("Git fixture failed: {s}\n", .{result.stderr});
        return error.GitFixtureFailure;
    }
    fn root(f: *Fixture, name: []const u8) !core.TrustedRoot {
        return .{ .dir = try f.tmp.dir.openDir(io, name, .{}), .canonical_path = try f.path(name) };
    }
};
fn task() core.TaskContext {
    return .{ .task_id = .{ .uuid = @splat(4) }, .base_commit = "0123456789012345678901234567890123456789", .scope_digest = policy.digest, .fence = 1, .expires_at_unix_ms = std.math.maxInt(i64) };
}
fn session(id: core.WorkspaceId) core.SessionContext {
    return .{ .session_id = .{ .uuid = @splat(7) }, .security_domain = .{ .id = 1 }, .policy_digest = policy.digest, .bound_workspace = id, .bound_task = task().task_id, .capability_handle = @enumFromInt(1) };
}
fn registry() !workspace.Registry {
    return workspace.Registry.init(A, io, .{ .git_executable = "/usr/bin/git" });
}

test "IS-001 real linked worktrees retain separate dirty bytes and common repo identity" {
    var f = try Fixture.init();
    defer f.deinit();
    const parent = try f.path(".");
    const linked = try std.fs.path.join(f.arena.allocator(), &.{ parent, "linked" });
    _ = try f.git("repo", &.{ "worktree", "add", "-q", "-b", "other", linked });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/file.txt", .data = "dirty-main\n" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "linked/file.txt", .data = "dirty-linked\n" });
    var r = try registry();
    defer r.deinit() catch unreachable;
    const a = try f.root("repo");
    defer a.dir.close(io);
    const b = try f.root("linked");
    defer b.dir.close(io);
    const wa = try r.registerWorkspace(io, a, policy);
    const wb = try r.registerWorkspace(io, b, policy);
    try t.expect(!wa.eql(wb));
    const sa = try r.snapshot(wa);
    const sb = try r.snapshot(wb);
    try t.expectEqual(sa.repo_id.common_dir, sb.repo_id.common_dir);
    try t.expect(!std.meta.eql(sa.git_dir_id, sb.git_dir_id));
    try t.expectEqualStrings("dirty-main\n", try a.dir.readFileAlloc(io, "file.txt", f.arena.allocator(), .limited(100)));
    try t.expectEqualStrings("dirty-linked\n", try b.dir.readFileAlloc(io, "file.txt", f.arena.allocator(), .limited(100)));
    try t.expect(wa.eql(try r.registerWorkspace(io, a, policy)));
    try t.expectEqual(@as(u64, 1), (try r.snapshot(wa)).generation);
}

test "IS-002 root deletion recreation rejects old capability and old incarnation" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const old = try f.root("repo");
    defer old.dir.close(io);
    const id = try r.registerWorkspace(io, old, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const lease = try r.acquireWriter(task(), id);
    try f.tmp.dir.deleteTree(io, "repo");
    try f.tmp.dir.createDir(io, "repo", .default_dir);
    _ = try f.git("repo", &.{ "init", "-q", "-b", "main" });
    try t.expectError(error.FenceMismatch, r.validateLease(lease));
    const replacement = try f.root("repo");
    defer replacement.dir.close(io);
    const fresh = try r.registerWorkspace(io, replacement, policy);
    try t.expect(!id.eql(fresh));
    try t.expectError(error.FenceMismatch, r.acquireWriter(task(), id));
    try t.expectError(error.FenceMismatch, r.validateWorkspace(id));
}

test "IS-005 callbacks drain before new writer and stale fence cannot commit" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const first = try r.acquireWriter(task(), id);
    const callback = try r.beginCallback(first);
    try t.expectError(error.Busy, r.acquireWriter(task(), id));
    try r.revokeWriter(id);
    try t.expectError(error.FenceMismatch, r.validateCallback(callback));
    try t.expectError(error.Busy, r.acquireWriter(task(), id));
    try r.endCallback(callback);
    try t.expectError(error.FenceMismatch, r.endCallback(callback));
    const next = try r.acquireWriter(task(), id);
    try t.expect(next.fence > first.fence);
    try t.expectError(error.FenceMismatch, r.validateLease(first));
}

test "IS-008 shared editor and invalid bound scopes cannot acquire writer" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try t.expectError(error.FenceMismatch, r.acquireWriter(task(), id));
    try t.expectError(error.OutOfScope, r.bindSession(session(id), task(), @splat(0)));
    try r.bindSession(session(id), task(), r.bootNonce());
    try t.expectError(error.LeaseExpired, r.acquireWriter(task(), id));
    try r.setManagedWrite(id, true);
    var wrong = task();
    wrong.scope_digest[0] ^= 1;
    try t.expectError(error.FenceMismatch, r.acquireWriter(wrong, id));
    wrong = task();
    wrong.task_id.uuid[0] ^= 1;
    try t.expectError(error.FenceMismatch, r.acquireWriter(wrong, id));
    wrong = task();
    wrong.fence += 1;
    try t.expectError(error.FenceMismatch, r.acquireWriter(wrong, id));
    wrong = task();
    wrong.expires_at_unix_ms = 1;
    try t.expectError(error.FenceMismatch, r.acquireWriter(wrong, id));
    var bad_session = session(id);
    bad_session.policy_digest[0] ^= 1;
    try t.expectError(error.OutOfScope, r.bindSession(bad_session, task(), r.bootNonce()));
    var planned = policy;
    planned.state = .planned;
    try t.expectError(error.ManifestUnbound, r.registerWorkspace(io, root, planned));
    var escaped = policy;
    escaped.write_paths = &.{.{ .bytes = "../escape" }};
    try t.expectError(error.PathEscape, r.registerWorkspace(io, root, escaped));
}

test "IS-005 TTL renewal expiry and callback limits use monotonic time" {
    var state: workspace.lease.State = .{};
    const id: core.WorkspaceId = .{ .registry_uuid = @splat(1), .incarnation = @splat(2) };
    const initial = try state.acquire(id, task().task_id, 100);
    try t.expectEqual(@as(u64, 30 * std.time.ns_per_s + 100), initial.expires_at_monotonic_ns);
    try t.expectError(error.Busy, state.renew(initial, 10 * std.time.ns_per_s));
    const renewed = try state.renew(initial, 10 * std.time.ns_per_s + 100);
    try t.expectEqual(@as(u64, 40 * std.time.ns_per_s + 100), renewed.expires_at_monotonic_ns);
    var tickets: [workspace.lease.max_callbacks]workspace.lease.CallbackTicket = undefined;
    for (&tickets) |*ticket| ticket.* = try state.beginCallback(renewed, 11 * std.time.ns_per_s);
    try t.expectError(error.Busy, state.beginCallback(renewed, 11 * std.time.ns_per_s));
    try t.expectError(error.LeaseExpired, state.validate(renewed, renewed.expires_at_monotonic_ns));
    try t.expectError(error.FenceMismatch, state.validateCallback(tickets[0], renewed.expires_at_monotonic_ns));
    try t.expectError(error.Busy, state.acquire(id, task().task_id, renewed.expires_at_monotonic_ns));
    for (tickets) |ticket| try state.endCallback(ticket);
    const next = try state.acquire(id, task().task_id, renewed.expires_at_monotonic_ns);
    try t.expect(next.fence > renewed.fence);
    state.revoke();
    state.fence = std.math.maxInt(u64);
    try t.expectError(error.ResourceExhausted, state.acquire(id, task().task_id, 0));
}

test "IS-005 concurrent acquisition admits exactly one writer and drains after retirement" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const Race = struct {
        r: *workspace.Registry,
        id: core.WorkspaceId,
        successes: std.atomic.Value(u32) = .init(0),
        busy: std.atomic.Value(u32) = .init(0),
        unexpected: std.atomic.Value(u32) = .init(0),
        fn run(self: *@This()) void {
            _ = self.r.acquireWriter(task(), self.id) catch |err| {
                if (err == error.Busy) {
                    _ = self.busy.fetchAdd(1, .monotonic);
                } else {
                    _ = self.unexpected.fetchAdd(1, .monotonic);
                }
                return;
            };
            _ = self.successes.fetchAdd(1, .monotonic);
        }
    };
    var race: Race = .{ .r = &r, .id = id };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Race.run, .{&race});
    for (threads) |thread| thread.join();
    try t.expectEqual(@as(u32, 1), race.successes.load(.monotonic));
    try t.expectEqual(@as(u32, 7), race.busy.load(.monotonic));
    try t.expectEqual(@as(u32, 0), race.unexpected.load(.monotonic));
    try r.revokeWriter(id);
    const first = try r.acquireWriter(task(), id);
    const ticket = try r.beginCallback(first);
    try t.expectError(error.Busy, r.deinit());
    try f.tmp.dir.deleteTree(io, "repo");
    try f.tmp.dir.createDir(io, "repo", .default_dir);
    _ = try f.git("repo", &.{ "init", "-q", "-b", "main" });
    const replacement = try f.root("repo");
    defer replacement.dir.close(io);
    const fresh = try r.registerWorkspace(io, replacement, policy);
    try r.bindSession(session(fresh), task(), r.bootNonce());
    try r.setManagedWrite(fresh, true);
    try t.expectError(error.Busy, r.acquireWriter(task(), fresh));
    try t.expectError(error.FenceMismatch, r.validateCallback(ticket));
    try r.endCallback(ticket);
    _ = try r.acquireWriter(task(), fresh);
}

test "IS-002 moved root and rewritten linked Git marker revoke identity" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try f.tmp.dir.rename("repo", f.tmp.dir, "moved", io);
    try t.expectError(error.FenceMismatch, r.validateWorkspace(id));
    const moved = try f.root("moved");
    defer moved.dir.close(io);
    const fresh = try r.registerWorkspace(io, moved, policy);
    try t.expect(!fresh.eql(id));
    const parent = try f.path(".");
    const linked = try std.fs.path.join(f.arena.allocator(), &.{ parent, "linked" });
    _ = try f.git("moved", &.{ "worktree", "add", "-q", "-b", "other", linked });
    const linked_root = try f.root("linked");
    defer linked_root.dir.close(io);
    const linked_id = try r.registerWorkspace(io, linked_root, policy);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "linked/.git", .data = "gitdir: /untrusted/other\n" });
    try t.expectError(error.FenceMismatch, r.validateWorkspace(linked_id));
}

test "IS-008 bounded registry session release wrong roots and discovery failure" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try workspace.Registry.init(A, io, .{ .git_executable = "/usr/bin/git", .capacity = 1 });
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    var bad_root = root;
    bad_root.canonical_path = try f.path(".");
    try t.expectError(error.PathEscape, r.registerWorkspace(io, bad_root, policy));
    try f.tmp.dir.createDirPath(io, "repo/subdir");
    const sub = try f.root("repo/subdir");
    defer sub.dir.close(io);
    try t.expectError(error.NotFound, r.registerWorkspace(io, sub, policy));
    var changed = policy;
    changed.max_changed_files += 1;
    try t.expectError(error.OutOfScope, r.registerWorkspace(io, root, changed));
    for (0..workspace.max_sessions) |i| {
        var task_i = task();
        task_i.task_id.uuid[0] = @intCast(i + 20);
        var session_i = session(id);
        session_i.session_id.uuid[0] = @intCast(i + 20);
        session_i.bound_task = task_i.task_id;
        try r.bindSession(session_i, task_i, r.bootNonce());
    }
    try t.expectError(error.ResourceExhausted, r.bindSession(session(id), task(), r.bootNonce()));
    var old_session = session(id);
    old_session.session_id.uuid[0] = 20;
    try r.unbindSession(old_session.session_id, r.bootNonce());
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.validateSession(session(id), r.bootNonce());
    var forged = session(id);
    forged.security_domain.id += 1;
    try t.expectError(error.OutOfScope, r.validateSession(forged, r.bootNonce()));
    const parent = try f.path(".");
    const linked = try std.fs.path.join(f.arena.allocator(), &.{ parent, "linked" });
    _ = try f.git("repo", &.{ "worktree", "add", "-q", "-b", "other", linked });
    const linked_root = try f.root("linked");
    defer linked_root.dir.close(io);
    try t.expectError(error.ResourceExhausted, r.registerWorkspace(io, linked_root, policy));
    var broken = try workspace.Registry.init(A, io, .{ .git_executable = "/no/such/git" });
    defer broken.deinit() catch unreachable;
    try t.expectError(error.IoFailure, broken.registerWorkspace(io, root, policy));
    var oom = std.testing.FailingAllocator.init(A, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, workspace.Registry.init(oom.allocator(), io, .{ .git_executable = "/usr/bin/git" }));
}

test "IS-001 checkout changes workspace generation and restart rejects previous boot" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try t.expectEqual(@as(u64, 2), try r.markChanged(id));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/file.txt", .data = "new commit\n" });
    _ = try f.git("repo", &.{ "add", "." });
    _ = try f.git("repo", &.{ "-c", "user.name=T10", "-c", "user.email=t10@example.invalid", "commit", "-q", "-m", "changed" });
    try t.expect(id.eql(try r.registerWorkspace(io, root, policy)));
    try t.expectEqual(@as(u64, 3), (try r.snapshot(id)).generation);
    var restarted = try registry();
    defer restarted.deinit() catch unreachable;
    const new_id = try restarted.registerWorkspace(io, root, policy);
    try t.expect(!new_id.eql(id));
    try t.expectError(error.FenceMismatch, restarted.validateWorkspace(id));
    try t.expectError(error.OutOfScope, restarted.bindSession(session(new_id), task(), r.bootNonce()));
}

test "IS-005 session expiration revokes outstanding callbacks and allocation failure unwinds" {
    var f = try Fixture.init();
    defer f.deinit();
    var failure = std.testing.FailingAllocator.init(A, .{});
    var r = try workspace.Registry.init(failure.allocator(), io, .{ .git_executable = "/usr/bin/git" });
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    failure.fail_index = failure.alloc_index;
    try t.expectError(error.OutOfMemory, r.registerWorkspace(io, root, policy));
    try t.expectEqual(@as(usize, 0), r.pending);
    failure.fail_index = std.math.maxInt(usize);
    const id = try r.registerWorkspace(io, root, policy);
    var short = task();
    short.expires_at_unix_ms = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms) + 200);
    try r.bindSession(session(id), short, r.bootNonce());
    try r.setManagedWrite(id, true);
    const l = try r.acquireWriter(short, id);
    const ticket = try r.beginCallback(l);
    try std.Io.sleep(io, .fromMilliseconds(250), .awake);
    try t.expectError(error.LeaseExpired, r.validateCallback(ticket));
    try t.expectError(error.OutOfScope, r.validateSession(session(id), r.bootNonce()));
    try t.expectError(error.LeaseExpired, r.acquireWriter(short, id));
    try r.endCallback(ticket);
}

// Registry time is injected through the standard Io clock interface. All other
// operations retain testing.io's implementation and userdata. Tests run serially.
const TestClock = struct {
    var active: ?*TestClock = null;
    vtable: std.Io.VTable = undefined,
    awake_ns: std.atomic.Value(u64) = .init(0),
    wall_ms: std.atomic.Value(i64) = .init(1000),
    fn start(self: *TestClock) void {
        std.debug.assert(active == null);
        active = self;
        self.vtable = io.vtable.*;
        self.vtable.now = now;
    }
    fn stop(self: *TestClock) void {
        std.debug.assert(active == self);
        active = null;
    }
    fn set(self: *TestClock, awake_ns: u64, wall_ms: i64) void {
        self.awake_ns.store(awake_ns, .release);
        self.wall_ms.store(wall_ms, .release);
    }
    fn interface(self: *TestClock) std.Io {
        return .{ .userdata = io.userdata, .vtable = &self.vtable };
    }
    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        const self = active.?;
        return switch (clock) {
            .awake => .{ .nanoseconds = self.awake_ns.load(.acquire) },
            .real => .{ .nanoseconds = @as(i96, self.wall_ms.load(.acquire)) * std.time.ns_per_ms },
            else => io.vtable.now(userdata, clock),
        };
    }
};
const DelayedAuthority = struct {
    const Operation = enum { acquire, renew, validate_lease, begin_callback, validate_callback, bind, validate_session };
    registry: *workspace.Registry,
    workspace_id: core.WorkspaceId,
    task_context: core.TaskContext,
    lease_snapshot: ?core.WriterLease,
    callback: ?workspace.CallbackTicket,
    operation: Operation,
    lock_count: usize = 0,
    reached: std.Io.Event = .unset,
    proceed: std.Io.Event = .unset,
    result: ?anyerror = null,
    issued_callback: ?workspace.CallbackTicket = null,
    fn beforeLock(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.lock_count += 1;
        // validateWorkspace checks its identity in two brief critical sections.
        // The third lock protects the actual session/lease authority decision.
        if (self.lock_count == 3) {
            self.reached.set(io);
            self.proceed.waitUncancelable(io);
        }
    }
    fn run(self: *@This()) void {
        defer self.reached.set(io);
        self.call() catch |err| {
            self.result = err;
        };
    }
    fn call(self: *@This()) !void {
        switch (self.operation) {
            .acquire => _ = try self.registry.acquireWriter(self.task_context, self.workspace_id),
            .renew => _ = try self.registry.renewWriter(self.lease_snapshot.?),
            .validate_lease => try self.registry.validateLease(self.lease_snapshot.?),
            .begin_callback => self.issued_callback = try self.registry.beginCallback(self.lease_snapshot.?),
            .validate_callback => try self.registry.validateCallback(self.callback.?),
            .bind => try self.registry.bindSession(session(self.workspace_id), self.task_context, self.registry.bootNonce()),
            .validate_session => try self.registry.validateSession(session(self.workspace_id), self.registry.bootNonce()),
        }
    }
};
fn blockedAuthorityExpiry(operation: DelayedAuthority.Operation) !void {
    var f = try Fixture.init();
    defer f.deinit();
    var clock: TestClock = .{};
    clock.start();
    defer clock.stop();
    var r = try workspace.Registry.init(A, clock.interface(), .{ .git_executable = "/usr/bin/git" });
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    var bound = task();
    const task_expiry = operation == .bind or operation == .validate_session or operation == .acquire;
    bound.expires_at_unix_ms = if (task_expiry) 2000 else 5000;
    if (operation != .bind) try r.bindSession(session(id), bound, r.bootNonce());
    try r.setManagedWrite(id, true);
    const l = if (!task_expiry) try r.acquireWriter(bound, id) else null;
    const ticket = if (operation == .validate_callback) try r.beginCallback(l.?) else null;
    defer if (ticket) |value| r.endCallback(value) catch unreachable;
    clock.set(20 * std.time.ns_per_s, 1000);
    var delayed: DelayedAuthority = .{ .registry = &r, .workspace_id = id, .task_context = bound, .lease_snapshot = l, .callback = ticket, .operation = operation };
    r.test_before_lock = .{ .context = &delayed, .enter = DelayedAuthority.beforeLock };
    const thread = try std.Thread.spawn(.{}, DelayedAuthority.run, .{&delayed});
    delayed.reached.waitUncancelable(io);
    if (delayed.lock_count != 3) {
        thread.join();
        r.test_before_lock = null;
        return error.DidNotReachAuthorityLock;
    }
    // The operation entered before expiry; hold its real mutex until it blocks,
    // advance both clocks across expiry, then let the authority check continue.
    r.mutex.lockUncancelable(io);
    clock.set(31 * std.time.ns_per_s, 3000);
    delayed.proceed.set(io);
    while (r.mutex.state.load(.acquire) != .contended) std.atomic.spinLoopHint();
    r.mutex.unlock(io);
    thread.join();
    r.test_before_lock = null;
    defer if (delayed.issued_callback) |value| r.endCallback(value) catch unreachable;
    const expected: anyerror = switch (operation) {
        .bind, .validate_session => error.OutOfScope,
        .validate_callback => error.FenceMismatch,
        else => error.LeaseExpired,
    };
    try t.expectEqual(@as(?anyerror, expected), delayed.result);
}

test "IS-005 blocked mutex acquisition samples task expiry at authority check" {
    try blockedAuthorityExpiry(.acquire);
}
test "IS-005 blocked mutex renewal cannot revive an expired writer" {
    try blockedAuthorityExpiry(.renew);
}
test "IS-005 blocked mutex lease validation rejects expiry" {
    try blockedAuthorityExpiry(.validate_lease);
}
test "IS-005 blocked mutex callback start rejects expiry" {
    try blockedAuthorityExpiry(.begin_callback);
}
test "IS-005 blocked mutex callback commit check rejects expiry" {
    try blockedAuthorityExpiry(.validate_callback);
}
test "IS-005 blocked mutex session bind rejects expiry" {
    try blockedAuthorityExpiry(.bind);
}
test "IS-005 blocked mutex session validation rejects expiry" {
    try blockedAuthorityExpiry(.validate_session);
}

test "IS-005 disconnecting a different task preserves the active writer and callback" {
    var f = try Fixture.init();
    defer f.deinit();
    var clock: TestClock = .{};
    clock.start();
    defer clock.stop();
    clock.set(10 * std.time.ns_per_s, 1000);
    var r = try workspace.Registry.init(A, clock.interface(), .{ .git_executable = "/usr/bin/git" });
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    var task_a = task();
    task_a.expires_at_unix_ms = 9000;
    var task_b = task_a;
    task_b.task_id.uuid = @splat(5);
    const session_a = session(id);
    var session_b = session_a;
    session_b.session_id.uuid = @splat(8);
    session_b.bound_task = task_b.task_id;
    try r.bindSession(session_a, task_a, r.bootNonce());
    try r.bindSession(session_b, task_b, r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer_b = try r.acquireWriter(task_b, id);
    const callback_b = try r.beginCallback(writer_b);
    var callback_live = true;
    defer if (callback_live) r.endCallback(callback_b) catch unreachable;

    try r.unbindSession(session_a.session_id, r.bootNonce());
    try r.validateLease(writer_b);
    try r.validateCallback(callback_b);
    try r.validateSession(session_b, r.bootNonce());

    try r.unbindSession(session_b.session_id, r.bootNonce());
    try t.expectError(error.FenceMismatch, r.validateLease(writer_b));
    try t.expectError(error.FenceMismatch, r.validateCallback(callback_b));
    try r.bindSession(session_a, task_a, r.bootNonce());
    try t.expectError(error.Busy, r.acquireWriter(task_a, id));
    try r.endCallback(callback_b);
    callback_live = false;
    const writer_a = try r.acquireWriter(task_a, id);
    try t.expect(writer_a.fence > writer_b.fence);
    try r.validateLease(writer_a);
}

test "IS-005 expired task and its stale lease cannot revoke a different writer" {
    var f = try Fixture.init();
    defer f.deinit();
    var clock: TestClock = .{};
    clock.start();
    defer clock.stop();
    clock.set(10 * std.time.ns_per_s, 1000);
    var r = try workspace.Registry.init(A, clock.interface(), .{ .git_executable = "/usr/bin/git" });
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    var task_a = task();
    task_a.expires_at_unix_ms = 2000;
    var task_b = task_a;
    task_b.task_id.uuid = @splat(5);
    task_b.expires_at_unix_ms = 9000;
    const session_a = session(id);
    var session_b = session_a;
    session_b.session_id.uuid = @splat(8);
    session_b.bound_task = task_b.task_id;
    try r.bindSession(session_a, task_a, r.bootNonce());
    try r.bindSession(session_b, task_b, r.bootNonce());
    try r.setManagedWrite(id, true);
    const stale_a = try r.acquireWriter(task_a, id);
    try r.revokeWriter(id);
    const writer_b = try r.acquireWriter(task_b, id);
    const callback_b = try r.beginCallback(writer_b);
    defer r.endCallback(callback_b) catch unreachable;

    // A's task has expired; B's task and both thirty-second lease snapshots
    // remain unexpired. Each rejected A operation must preserve B's authority.
    clock.set(11 * std.time.ns_per_s, 2000);
    try t.expectError(error.LeaseExpired, r.acquireWriter(task_a, id));
    try r.validateLease(writer_b);
    try r.validateCallback(callback_b);

    try t.expectError(error.LeaseExpired, r.validateLease(stale_a));
    try r.validateLease(writer_b);
    try r.validateCallback(callback_b);

    try t.expectError(error.LeaseExpired, r.renewWriter(stale_a));
    try r.validateLease(writer_b);
    try r.validateCallback(callback_b);

    try t.expectError(error.LeaseExpired, r.beginCallback(stale_a));
    try r.validateLease(writer_b);
    try r.validateCallback(callback_b);
}

test "IS-005 expiry revokes its own writer and waits for its callback to drain" {
    var f = try Fixture.init();
    defer f.deinit();
    var clock: TestClock = .{};
    clock.start();
    defer clock.stop();
    clock.set(10 * std.time.ns_per_s, 1000);
    var r = try workspace.Registry.init(A, clock.interface(), .{ .git_executable = "/usr/bin/git" });
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    var task_a = task();
    task_a.expires_at_unix_ms = 9000;
    var task_b = task_a;
    task_b.task_id.uuid = @splat(5);
    task_b.expires_at_unix_ms = 2000;
    const session_a = session(id);
    var session_b = session_a;
    session_b.session_id.uuid = @splat(8);
    session_b.bound_task = task_b.task_id;
    try r.bindSession(session_a, task_a, r.bootNonce());
    try r.bindSession(session_b, task_b, r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer_b = try r.acquireWriter(task_b, id);
    const callback_b = try r.beginCallback(writer_b);
    var callback_live = true;
    defer if (callback_live) r.endCallback(callback_b) catch unreachable;

    clock.set(11 * std.time.ns_per_s, 2000);
    try t.expectError(error.LeaseExpired, r.validateCallback(callback_b));
    try t.expectError(error.LeaseExpired, r.validateLease(writer_b));
    try t.expectError(error.Busy, r.acquireWriter(task_a, id));
    try r.endCallback(callback_b);
    callback_live = false;
    const writer_a = try r.acquireWriter(task_a, id);
    try t.expect(writer_a.fence > writer_b.fence);
    try r.validateLease(writer_a);
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
const MarkerRace = struct {
    const Mode = enum { fifo, timestamp, size, replaced_entry };
    mode: Mode,
    root: std.Io.Dir,
    marker_path: [:0]const u8,
    original_bytes: []const u8,
    registry: *workspace.Registry,
    id: core.WorkspaceId,
    mutated: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    mutation_error: ?anyerror = null,
    validation_error: ?anyerror = null,
    fn mutate(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        defer self.mutated.set(io);
        self.change() catch |err| {
            self.mutation_error = err;
        };
    }
    fn change(self: *@This()) !void {
        switch (self.mode) {
            .fifo => {
                try self.root.rename(".git", self.root, ".git.saved", io);
                if (mkfifo(self.marker_path, 0o600) != 0) return error.FifoCreationFailed;
            },
            .timestamp => {
                const file = try self.root.openFile(io, ".git", .{ .follow_symlinks = false });
                defer file.close(io);
                try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = std.time.ns_per_s } } });
            },
            .size => try self.root.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: /replacement/metadata/with/a/different/length\n" }),
            .replaced_entry => {
                try self.root.rename(".git", self.root, ".git.saved", io);
                try self.root.writeFile(io, .{ .sub_path = ".git", .data = self.original_bytes });
            },
        }
    }
    fn validate(self: *@This()) void {
        defer self.done.set(io);
        self.registry.validateWorkspace(self.id) catch |err| {
            self.validation_error = err;
        };
    }
};
fn runMarkerRace(mode: MarkerRace.Mode) !void {
    var f = try Fixture.init();
    defer f.deinit();
    const linked_path = try std.fs.path.join(f.arena.allocator(), &.{ try f.path("."), "linked" });
    _ = try f.git("repo", &.{ "worktree", "add", "-q", "-b", "linked", linked_path });
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("linked");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    const original = try root.dir.readFileAlloc(io, ".git", f.arena.allocator(), .limited(4096));
    const marker_path = try f.arena.allocator().dupeZ(u8, try std.fs.path.join(f.arena.allocator(), &.{ linked_path, ".git" }));
    var race: MarkerRace = .{ .mode = mode, .root = root.dir, .marker_path = marker_path, .original_bytes = original, .registry = &r, .id = id };
    workspace.identity.marker_test_hook = .{ .context = &race, .before_open = if (mode == .fifo) MarkerRace.mutate else null, .after_read = if (mode != .fifo) MarkerRace.mutate else null };
    defer workspace.identity.marker_test_hook = null;
    if (mode == .fifo) {
        const thread = try std.Thread.spawn(.{}, MarkerRace.validate, .{&race});
        race.mutated.waitUncancelable(io);
        // The mutation itself is deterministically placed after lstat and before
        // open. The deadline is only a hang detector; a fallback writer unblocks
        // the old blocking implementation so RED reports an assertion failure.
        const completed = if (race.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } })) true else |_| false;
        if (!completed) {
            const fd = try std.posix.openatZ(root.dir.handle, ".git", .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
            const unblock: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
            unblock.close(io);
        }
        thread.join();
        try t.expectEqual(@as(?anyerror, null), race.mutation_error);
        try t.expect(completed);
    } else {
        race.validate();
        try t.expectEqual(@as(?anyerror, null), race.mutation_error);
    }
    try t.expectEqual(@as(?anyerror, error.FenceMismatch), race.validation_error);
}

test "IS-002 Git marker FIFO replacement between stat and open cannot block" {
    try runMarkerRace(.fifo);
}
test "IS-002 Git marker timestamp change after read invalidates discovery" {
    try runMarkerRace(.timestamp);
}
test "IS-002 Git marker size change after read invalidates discovery" {
    try runMarkerRace(.size);
}
test "IS-002 Git marker directory entry replacement after read invalidates discovery" {
    try runMarkerRace(.replaced_entry);
}

test "IS-001 snapshot exposes HEAD copied from retained discovery" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const expected_before = std.mem.trim(u8, try f.git("repo", &.{ "rev-parse", "HEAD" }), "\n");
    const id = try r.registerWorkspace(io, root, policy);
    const before = try r.snapshot(id);
    try t.expectEqualStrings(expected_before, before.head[0..before.head_len]);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/file.txt", .data = "new HEAD\n" });
    _ = try f.git("repo", &.{ "add", "." });
    _ = try f.git("repo", &.{ "-c", "user.name=T10", "-c", "user.email=t10@example.invalid", "commit", "-q", "-m", "new head" });
    const expected_after = std.mem.trim(u8, try f.git("repo", &.{ "rev-parse", "HEAD" }), "\n");
    const retained = try r.snapshot(id);
    try t.expectEqualStrings(expected_before, retained.head[0..retained.head_len]);
    _ = try r.registerWorkspace(io, root, policy);
    const after = try r.snapshot(id);
    try t.expectEqualStrings(expected_after, after.head[0..after.head_len]);
    try t.expectEqualStrings(expected_before, before.head[0..before.head_len]);
}

const CommitMutation = struct {
    const Mode = enum { revoke, unbind, disable, mark_changed, validate_lease, renew, begin_callback, validate_callback, acquire_writer, register_same, register_replacement, invalid_root };
    registry: *workspace.Registry,
    id: core.WorkspaceId,
    writer: core.WriterLease,
    ticket: workspace.CallbackTicket,
    mode: Mode,
    root: core.TrustedRoot,
    done: std.Io.Event = .unset,
    result: ?anyerror = null,
    generation: ?u64 = null,
    registered: ?core.WorkspaceId = null,
    extra_callback: ?workspace.CallbackTicket = null,
    fn run(self: *@This()) void {
        defer self.done.set(io);
        self.apply() catch |err| {
            self.result = err;
        };
    }
    fn apply(self: *@This()) !void {
        switch (self.mode) {
            .revoke => try self.registry.revokeWriter(self.id),
            .unbind => try self.registry.unbindSession(session(self.id).session_id, self.registry.bootNonce()),
            .disable => try self.registry.setManagedWrite(self.id, false),
            .mark_changed => self.generation = try self.registry.markChanged(self.id),
            .validate_lease => try self.registry.validateLease(self.writer),
            .renew => _ = try self.registry.renewWriter(self.writer),
            .begin_callback => self.extra_callback = try self.registry.beginCallback(self.writer),
            .validate_callback => try self.registry.validateCallback(self.ticket),
            .acquire_writer => _ = try self.registry.acquireWriter(task(), self.id),
            .register_same, .register_replacement => self.registered = try self.registry.registerWorkspace(io, self.root, policy),
            .invalid_root => try self.registry.validateWorkspace(self.id),
        }
    }
};
fn commitMutationWaits(mode: CommitMutation.Mode) !void {
    var f = try Fixture.init();
    defer f.deinit();
    var clock: TestClock = .{};
    clock.start();
    defer clock.stop();
    var r = try workspace.Registry.init(A, clock.interface(), .{ .git_executable = "/usr/bin/git" });
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer = try r.acquireWriter(task(), id);
    const ticket = try r.beginCallback(writer);
    defer r.endCallback(ticket) catch unreachable;
    const guard = try r.acquireCommit(ticket);
    defer guard.release();
    try t.expectEqual(@as(u64, 2), guard.next_generation);
    try t.expect(r.mutex.tryLock());
    r.mutex.unlock(io);
    var target_root = root;
    var replacement_owned = false;
    defer if (replacement_owned) target_root.dir.close(io);
    switch (mode) {
        .validate_lease, .renew, .begin_callback, .validate_callback, .acquire_writer => clock.set(31 * std.time.ns_per_s, 1000),
        .register_same => _ = try f.git("repo", &.{ "-c", "user.name=T10", "-c", "user.email=t10@example.invalid", "commit", "--allow-empty", "-q", "-m", "head during guard" }),
        .register_replacement => {
            try f.tmp.dir.deleteTree(io, "repo");
            try f.tmp.dir.createDir(io, "repo", .default_dir);
            _ = try f.git("repo", &.{ "init", "-q", "-b", "replacement" });
            target_root = try f.root("repo");
            replacement_owned = true;
        },
        .invalid_root => try f.tmp.dir.deleteTree(io, "repo"),
        else => {},
    }
    var mutation: CommitMutation = .{ .registry = &r, .id = id, .writer = writer, .ticket = ticket, .mode = mode, .root = target_root };
    const thread = try std.Thread.spawn(.{}, CommitMutation.run, .{&mutation});
    // Observe either the condition waiter or completion. No scheduling sleeps:
    // a broken coordinator returns while this guard is still holding publication.
    var blocked = false;
    while (true) {
        r.mutex.lockUncancelable(io);
        blocked = r.entries[0].?.publication_waiters != 0;
        r.mutex.unlock(io);
        if (blocked or mutation.done.isSet()) break;
        std.atomic.spinLoopHint();
    }
    if (mode == .revoke or mode == .unbind or mode == .disable) {
        // Actual handle-relative filesystem work occurs while the guard is held
        // and the conflicting operation is waiting with the global mutex free.
        root.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "published under guard\n" }) catch unreachable;
    }
    guard.markApplied();
    guard.release();
    thread.join();
    defer if (mutation.extra_callback) |extra| r.endCallback(extra) catch unreachable;
    try t.expect(blocked);
    const expected: ?anyerror = switch (mode) {
        .validate_lease, .renew, .begin_callback => error.LeaseExpired,
        .validate_callback, .invalid_root => error.FenceMismatch,
        .acquire_writer => error.Busy,
        else => null,
    };
    try t.expectEqual(expected, mutation.result);
    switch (mode) {
        .mark_changed => try t.expectEqual(@as(?u64, 3), mutation.generation),
        .register_same => {
            try t.expect(mutation.registered.?.eql(id));
            try t.expectEqual(@as(u64, 3), (try r.snapshot(id)).generation);
        },
        .register_replacement => {
            try t.expect(!mutation.registered.?.eql(id));
            try t.expectError(error.FenceMismatch, r.validateWorkspace(id));
        },
        .invalid_root => try t.expectError(error.FenceMismatch, r.validateWorkspace(id)),
        .disable => try t.expectError(error.FenceMismatch, r.validateCallback(ticket)),
        else => if (mode != .mark_changed) try t.expectError(error.FenceMismatch, r.validateCallback(ticket)),
    }
}

test "IS-005 commit guard holds revocation until filesystem publication finishes" {
    try commitMutationWaits(.revoke);
}
test "IS-005 commit guard holds session unbind until publication finishes" {
    try commitMutationWaits(.unbind);
}
test "IS-005 commit guard serializes managed write disable" {
    try commitMutationWaits(.disable);
}
test "IS-005 commit guard serializes dirty generation changes" {
    try commitMutationWaits(.mark_changed);
}
test "IS-005 commit guard serializes validation expiry" {
    try commitMutationWaits(.validate_lease);
}
test "IS-005 commit guard serializes renewal expiry" {
    try commitMutationWaits(.renew);
}
test "IS-005 commit guard serializes callback admission expiry" {
    try commitMutationWaits(.begin_callback);
}
test "IS-005 commit guard serializes callback validation expiry" {
    try commitMutationWaits(.validate_callback);
}
test "IS-005 commit guard serializes writer acquisition expiry" {
    try commitMutationWaits(.acquire_writer);
}
test "IS-002 commit guard serializes rediscovered HEAD generation" {
    try commitMutationWaits(.register_same);
}
test "IS-002 commit guard serializes replacement incarnation retirement" {
    try commitMutationWaits(.register_replacement);
}
test "IS-002 commit guard serializes invalid root retirement" {
    try commitMutationWaits(.invalid_root);
}

// Inspect internal state without invoking an authority API while the test owns
// a publication guard. Consumers use their retained snapshot until release.
fn observedGeneration(r: *workspace.Registry, id: core.WorkspaceId) u64 {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    for (r.entries[0..r.used]) |entry| {
        if (entry.?.id.eql(id)) return entry.?.generation;
    }
    unreachable;
}

test "IS-005 commit generation reservation abort apply and stale guards are bounded" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer = try r.acquireWriter(task(), id);
    const ticket = try r.beginCallback(writer);
    var live = true;
    defer if (live) r.endCallback(ticket) catch unreachable;
    const aborted = try r.acquireCommit(ticket);
    try t.expectEqual(@as(u64, 2), aborted.next_generation);
    try t.expectEqual(@as(u64, 1), observedGeneration(&r, id));
    aborted.release();
    try t.expectEqual(@as(u64, 1), (try r.snapshot(id)).generation);
    const applied = try r.acquireCommit(ticket);
    defer applied.release();
    applied.markApplied();
    applied.markApplied();
    try t.expectEqual(@as(u64, 2), observedGeneration(&r, id));
    applied.release();
    const next = try r.acquireCommit(ticket);
    defer next.release();
    aborted.release();
    applied.release();
    applied.markApplied();
    try t.expectEqual(@as(u64, 2), observedGeneration(&r, id));
    const ended = if (r.endCallback(ticket)) blk: {
        live = false;
        break :blk true;
    } else |err| blk: {
        try t.expectEqual(error.Busy, err);
        break :blk false;
    };
    next.release();
    try t.expect(!ended);
    try t.expectError(error.Busy, r.deinit());
    r.entries[0].?.generation = std.math.maxInt(u64);
    try t.expectError(error.ResourceExhausted, r.acquireCommit(ticket));
    try t.expect(r.entries[0].?.publishing == null);
    r.entries[0].?.generation = 2;
    r.last_commit_id = std.math.maxInt(u64);
    try t.expectError(error.ResourceExhausted, r.acquireCommit(ticket));
    try t.expect(r.entries[0].?.publishing == null);
}

test "IS-005 held commit guard permits independent worktree progress" {
    var f = try Fixture.init();
    defer f.deinit();
    const linked = try std.fs.path.join(f.arena.allocator(), &.{ try f.path("."), "linked" });
    _ = try f.git("repo", &.{ "worktree", "add", "-q", "-b", "linked", linked });
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const other = try f.root("linked");
    defer other.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    const other_id = try r.registerWorkspace(io, other, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer = try r.acquireWriter(task(), id);
    const ticket = try r.beginCallback(writer);
    defer r.endCallback(ticket) catch unreachable;
    const guard = try r.acquireCommit(ticket);
    defer guard.release();
    try t.expectEqual(@as(u64, 2), try r.markChanged(other_id));
    try t.expect(other_id.eql(try r.registerWorkspace(io, other, policy)));
    try t.expectEqual(@as(u64, 2), (try r.snapshot(other_id)).generation);
    try t.expectEqual(@as(u64, 1), observedGeneration(&r, id));
}

test "IS-002 waiting commit rechecks root identity after another publication releases" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer = try r.acquireWriter(task(), id);
    const first = try r.beginCallback(writer);
    defer r.endCallback(first) catch unreachable;
    const second = try r.beginCallback(writer);
    defer r.endCallback(second) catch unreachable;
    const guard = try r.acquireCommit(first);
    defer guard.release();
    const Pending = struct {
        registry: *workspace.Registry,
        ticket: workspace.CallbackTicket,
        done: std.Io.Event = .unset,
        result: ?anyerror = null,
        fn run(self: *@This()) void {
            defer self.done.set(io);
            const next = self.registry.acquireCommit(self.ticket) catch |err| {
                self.result = err;
                return;
            };
            next.release();
        }
    };
    var pending: Pending = .{ .registry = &r, .ticket = second };
    const thread = try std.Thread.spawn(.{}, Pending.run, .{&pending});
    var waiting = false;
    while (true) {
        r.mutex.lockUncancelable(io);
        waiting = r.entries[0].?.publication_waiters != 0;
        r.mutex.unlock(io);
        if (waiting or pending.done.isSet()) break;
        std.atomic.spinLoopHint();
    }
    try f.tmp.dir.deleteTree(io, "repo");
    guard.release();
    thread.join();
    try t.expect(waiting);
    try t.expectEqual(@as(?anyerror, error.FenceMismatch), pending.result);
}

test "IS-005 concurrent unbind waiters relookup session after guard release" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer = try r.acquireWriter(task(), id);
    const ticket = try r.beginCallback(writer);
    defer r.endCallback(ticket) catch unreachable;
    const guard = try r.acquireCommit(ticket);
    defer guard.release();
    var one: CommitMutation = .{ .registry = &r, .id = id, .writer = writer, .ticket = ticket, .mode = .unbind, .root = root };
    var two = one;
    const a = try std.Thread.spawn(.{}, CommitMutation.run, .{&one});
    const b = try std.Thread.spawn(.{}, CommitMutation.run, .{&two});
    var waiters: usize = 0;
    while (true) {
        r.mutex.lockUncancelable(io);
        waiters = r.entries[0].?.publication_waiters;
        r.mutex.unlock(io);
        if (waiters == 2 or one.done.isSet() or two.done.isSet()) break;
        std.atomic.spinLoopHint();
    }
    guard.release();
    a.join();
    b.join();
    try t.expectEqual(@as(usize, 2), waiters);
    if (one.result == null) {
        try t.expectEqual(@as(?anyerror, error.OutOfScope), two.result);
    } else {
        try t.expectEqual(@as(?anyerror, error.OutOfScope), one.result);
        try t.expectEqual(@as(?anyerror, null), two.result);
    }
    var other_task = task();
    other_task.task_id.uuid = @splat(13);
    var other_session = session(id);
    other_session.session_id.uuid = @splat(14);
    other_session.bound_task = other_task.task_id;
    try r.bindSession(other_session, other_task, r.bootNonce());
    try r.validateSession(other_session, r.bootNonce());
}

test "IS-005 publication waiter bound refuses pressure without changing current guard" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer = try r.acquireWriter(task(), id);
    const ticket = try r.beginCallback(writer);
    defer r.endCallback(ticket) catch unreachable;
    const guard = try r.acquireCommit(ticket);
    defer guard.release();
    r.entries[0].?.publication_waiters = workspace.max_commit_waiters;
    const result = r.revokeWriter(id);
    r.entries[0].?.publication_waiters = 0;
    try t.expectError(error.ResourceExhausted, result);
    try t.expectError(error.Busy, r.endCallback(ticket));
    try t.expectError(error.Busy, r.acquireCommit(ticket));
    try t.expectError(error.Busy, r.deinit());
    guard.markApplied();
    guard.release();
    try r.validateCallback(ticket);
    try t.expectEqual(@as(u64, 2), (try r.snapshot(id)).generation);
}

test "WR-008 recovery failure disables writes before a waiting publisher wakes" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer = try r.acquireWriter(task(), id);
    const first = try r.beginCallback(writer);
    defer r.endCallback(first) catch unreachable;
    const second = try r.beginCallback(writer);
    defer r.endCallback(second) catch unreachable;
    const stale = try r.acquireCommit(first);
    stale.release();
    const guard = try r.acquireCommit(first);
    defer guard.release();
    stale.failRecovery(); // A stale copy cannot disable the current publication.
    try t.expect(r.entries[0].?.managed_write);
    guard.markApplied();
    const Pending = struct {
        registry: *workspace.Registry,
        ticket: workspace.CallbackTicket,
        done: std.Io.Event = .unset,
        result: ?anyerror = null,
        fn run(self: *@This()) void {
            defer self.done.set(io);
            const next = self.registry.acquireCommit(self.ticket) catch |err| {
                self.result = err;
                return;
            };
            next.release();
        }
    };
    var pending: Pending = .{ .registry = &r, .ticket = second };
    const thread = try std.Thread.spawn(.{}, Pending.run, .{&pending});
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var waiting = false;
    while (started.untilNow(io).raw.toMilliseconds() < 5000) {
        r.mutex.lockUncancelable(io);
        waiting = r.entries[0].?.publication_waiters != 0;
        r.mutex.unlock(io);
        if (waiting or pending.done.isSet()) break;
        std.atomic.spinLoopHint();
    }
    guard.failRecovery();
    thread.join();
    try t.expect(waiting);
    try t.expectEqual(@as(?anyerror, error.FenceMismatch), pending.result);
    try t.expect(!r.entries[0].?.managed_write);
    try t.expectEqual(@as(u64, 2), (try r.snapshot(id)).generation);
    try t.expectError(error.LeaseExpired, r.acquireWriter(task(), id));
    guard.failRecovery();
    guard.release();
}

test "WR-008 precommit recovery quarantine drains a different publication without a fallible gate" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try registry();
    defer r.deinit() catch unreachable;
    const root = try f.root("repo");
    defer root.dir.close(io);
    const id = try r.registerWorkspace(io, root, policy);
    try r.bindSession(session(id), task(), r.bootNonce());
    try r.setManagedWrite(id, true);
    const writer = try r.acquireWriter(task(), id);
    const first = try r.beginCallback(writer);
    defer r.endCallback(first) catch unreachable;
    const second = try r.beginCallback(writer);
    defer r.endCallback(second) catch unreachable;
    const guard = try r.acquireCommit(first);
    defer guard.release();
    const Pending = struct {
        registry: *workspace.Registry,
        id: core.WorkspaceId,
        done: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            self.registry.failRecovery(self.id);
            self.done.set(io);
        }
    };
    var pending: Pending = .{ .registry = &r, .id = id };
    const thread = try std.Thread.spawn(.{}, Pending.run, .{&pending});
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var disabled = false;
    while (started.untilNow(io).raw.toMilliseconds() < 5000) {
        r.mutex.lockUncancelable(io);
        disabled = !r.entries[0].?.managed_write;
        r.mutex.unlock(io);
        if (disabled or pending.done.isSet()) break;
        std.atomic.spinLoopHint();
    }
    const returned_early = pending.done.isSet();
    // The publication already admitted before quarantine finishes atomically.
    guard.markApplied();
    guard.release();
    thread.join();
    try t.expect(disabled and !returned_early);
    try t.expectError(error.FenceMismatch, r.acquireCommit(second));
    try t.expectError(error.LeaseExpired, r.acquireWriter(task(), id));
    r.failRecovery(id); // Already quarantined is idempotent.
}

test "IS-008 discovery git timeout is retryable Busy while a failing git stays IoFailure" {
    var f = try Fixture.init();
    defer f.deinit();
    const root = try f.root("repo");
    defer root.dir.close(io);
    // Stand-ins for git: one never answers within the discovery budget, one fails at once.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "slow-git", .data = "#!/bin/sh\nexec /bin/sleep 30\n" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "failing-git", .data = "#!/bin/sh\nexit 1\n" });
    const slow = try f.path("slow-git");
    const failing = try f.path("failing-git");
    for ([_][]const u8{ slow, failing }) |exe| {
        const chmod = try std.process.run(f.arena.allocator(), io, .{ .argv = &.{ "/bin/chmod", "755", exe } });
        try t.expect(chmod.term == .exited and chmod.term.exited == 0);
    }
    try t.expectError(error.InvalidArgument, workspace.Registry.init(A, io, .{ .git_executable = "/usr/bin/git", .git_timeout_ms = 0 }));
    try t.expectError(error.InvalidArgument, workspace.Registry.init(A, io, .{ .git_executable = "/usr/bin/git", .git_timeout_ms = 60_001 }));
    var timed = try workspace.Registry.init(A, io, .{ .git_executable = slow, .git_timeout_ms = 200 });
    defer timed.deinit() catch unreachable;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    // Identity is not established, so registration is still refused, but as a
    // retryable Busy rather than a non-retryable I/O failure.
    try t.expectError(error.Busy, timed.registerWorkspace(io, root, policy));
    // The timeout kills the stand-in instead of waiting for its 30 s sleep.
    try t.expect(started.untilNow(io).raw.toMilliseconds() < 10_000);
    // The default budget keeps a slow start of the failing stand-in from turning into Busy.
    var failed = try workspace.Registry.init(A, io, .{ .git_executable = failing });
    defer failed.deinit() catch unreachable;
    try t.expectError(error.IoFailure, failed.registerWorkspace(io, root, policy));
    var defaults = try registry();
    defer defaults.deinit() catch unreachable;
    try t.expectEqual(@as(u32, 5000), defaults.git_timeout_ms);
}
