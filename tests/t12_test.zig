const std = @import("std");
const f = @import("t12_fixtures.zig");
const t = std.testing;
const storage = f.storage;
const core = f.core;
const child_exe = @import("t12_options").child_exe;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
const Repo = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: core.TrustedRoot,
    state: []const u8,
    state_witness: std.Io.Dir,
    witness: f.workspace.identity.Identity,
    children: u32 = 0,
    publication: ?PublicationWitness = null,
    fn init(create: bool) !Repo {
        var tmp = t.tmpDir(.{});
        var arena = std.heap.ArenaAllocator.init(f.A);
        const a = arena.allocator();
        try tmp.dir.createDir(f.io, "repo", .default_dir);
        try tmp.dir.createDir(f.io, "state", .fromMode(0o700));
        const path = try tmp.dir.realPathFileAlloc(f.io, "repo", a);
        const state = try tmp.dir.realPathFileAlloc(f.io, "state", a);
        try f.git(a, path, &.{ "init", "-q", "-b", "main" });
        const root: core.TrustedRoot = .{ .dir = try std.Io.Dir.openDirAbsolute(f.io, path, .{}), .canonical_path = path };
        try root.dir.writeFile(f.io, .{ .sub_path = "sentinel", .data = "untouched sentinel\n" });
        if (!create) try root.dir.writeFile(f.io, .{ .sub_path = "file.txt", .data = try f.content(a, false) });
        try f.git(a, path, &.{ "add", "." });
        try f.git(a, path, &.{ "-c", "user.name=T12", "-c", "user.email=t12@example.invalid", "commit", "-q", "-m", "fixture" });
        return .{ .tmp = tmp, .arena = arena, .root = root, .state = state, .state_witness = try std.Io.Dir.openDirAbsolute(f.io, state, .{ .iterate = true, .follow_symlinks = false }), .witness = try f.workspace.identity.discover(f.A, f.io, "/usr/bin/git", root) };
    }
    fn deinit(self: *Repo) void {
        if (self.publication) |*pubw| pubw.deinit();
        self.witness.deinit(f.io);
        self.state_witness.close(f.io);
        self.root.dir.close(f.io);
        if (f.transcript) |file| {
            file.close(f.io);
            f.transcript = null;
        }
        // Crash fixtures and pipe transcripts are retained for independent evidence inspection.
        self.arena.deinit();
    }
    fn targetMetadata(self: *Repo) !?storage.Metadata {
        if ((try f.policy.paths.statAt(self.root.dir.handle, "file.txt")) == null) return null;
        const file = try self.root.dir.openFile(f.io, "file.txt", .{});
        defer file.close(f.io);
        return try storage.metadata(file.handle, false);
    }
    fn bytes(self: *Repo, create: bool, applied: bool) !void {
        const a = self.arena.allocator();
        if (create and !applied) {
            try t.expect((try f.policy.paths.statAt(self.root.dir.handle, "file.txt")) == null);
        } else {
            const actual = try self.root.dir.readFileAlloc(f.io, "file.txt", a, .limited(f.size + 1));
            try t.expectEqualSlices(u8, try f.content(a, applied), actual);
        }
        try t.expectEqualStrings("untouched sentinel\n", try self.root.dir.readFileAlloc(f.io, "sentinel", a, .limited(100)));
    }
    fn verify(self: *Repo, hello: f.Hello) !void {
        try t.expectEqual((try storage.metadata(self.state_witness.handle, true)).id, hello.store_root_id);
        try self.witness.validate(f.io);
        try t.expect(storage.recovery.identityMatches(&self.witness, hello.namespace));
        try t.expectEqual(f.approved.digest, hello.namespace.policy_digest);
    }
};
const PublicationWitness = struct {
    parent: std.Io.Dir,
    temp: std.Io.File,
    original: ?std.Io.File,
    parent_id: core.FileId,
    temp_id: core.FileId,
    old_id: ?core.FileId,
    digest: core.Sha256,
    fn open(dir: std.Io.Dir, name: []const u8, expected: core.FileId) !std.Io.File {
        var buf: [4097]u8 = undefined;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const fd = try std.posix.openatZ(dir.handle, buf[0..name.len :0], .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(f.io);
        try t.expectEqual(expected, (try storage.metadata(fd, false)).id);
        return file;
    }
    fn acquire(repo: *Repo, p: core.PreparedRecord) !PublicationWitness {
        const pubid = p.publication.?;
        // This supervisor fixture authorizes exactly its generated file operation.
        try f.policy.paths.validate(p.path.bytes);
        try t.expectEqual(f.task.task_id, p.key.task_id);
        try t.expectEqual(repo.witness.root_id, pubid.root_id);
        const resolved = try f.edit.publish.Parent.open(f.io, repo.root.dir, p.path.bytes);
        const parent = resolved.dir;
        errdefer parent.close(f.io);
        try t.expectEqual(pubid.parent_id, (try storage.metadata(parent.handle, true)).id);
        const temp = try open(parent, pubid.temp_name, pubid.temp_id);
        errdefer temp.close(f.io);
        const original = if (pubid.old_file_id) |id| try open(parent, resolved.name(), id) else null;
        if (original == null) try t.expect((try f.policy.paths.statAt(parent.handle, resolved.name())) == null);
        return .{ .parent = parent, .temp = temp, .original = original, .parent_id = pubid.parent_id, .temp_id = pubid.temp_id, .old_id = pubid.old_file_id, .digest = try storage.recovery.publicationDigest(p) };
    }
    fn retained(fd: std.posix.fd_t, id: core.FileId) !void {
        // The same identity mapping the authorizer and journal use, on every platform.
        const entry = try f.policy.paths.statHandle(fd);
        try t.expectEqual(id, core.FileId{ .device = entry.identity.device, .inode = entry.identity.inode });
    }
    fn validate(self: *PublicationWitness) !core.Sha256 {
        try retained(self.parent.handle, self.parent_id);
        try retained(self.temp.handle, self.temp_id);
        if (self.original) |file| try retained(file.handle, self.old_id.?);
        return self.digest;
    }
    fn deinit(self: *PublicationWitness) void {
        if (self.original) |file| file.close(f.io);
        self.temp.close(f.io);
        self.parent.close(f.io);
    }
};
fn writerAck(repo: *Repo, child: *std.process.Child) !std.json.Parsed(f.Ack) {
    var ack = try f.receive(child.stdout.?.handle, f.Ack, repo.arena.allocator());
    if (ack.value.point == 12) {
        const p = ack.value.prepared orelse return error.MissingPreparedWitness;
        repo.publication = try PublicationWitness.acquire(repo, p);
        try f.send(child.stdin.?.handle, bool, true);
        ack = try f.receive(child.stdout.?.handle, f.Ack, repo.arena.allocator());
    }
    return ack;
}
fn spawn(repo: *Repo) !std.process.Child {
    var env: std.process.Environ.Map = .init(f.A);
    defer env.deinit();
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    if (f.transcript) |file| file.close(f.io);
    repo.children += 1;
    const a = repo.arena.allocator();
    const trace_name = try std.fmt.allocPrint(a, "child-{d}.stdout", .{repo.children});
    f.transcript = try repo.tmp.dir.createFile(f.io, trace_name, .{});
    const err_name = try std.fmt.allocPrint(a, "child-{d}.stderr", .{repo.children});
    const stderr = try repo.tmp.dir.createFile(f.io, err_name, .{});
    defer stderr.close(f.io);
    return std.process.spawn(f.io, .{ .argv = &.{child_exe}, .environ_map = &env, .cwd = .{ .path = repo.state }, .stdin = .pipe, .stdout = .pipe, .stderr = .{ .file = stderr } });
}
fn kill(child: *std.process.Child) !void {
    try std.posix.kill(child.id.?, .KILL);
    try t.expectEqual(std.process.Child.Term{ .signal = .KILL }, try child.wait(f.io));
}
fn recovery(repo: *Repo, m: f.Manifest, ns: storage.Namespace, old_boot: core.Uuid) !f.Result {
    const a = repo.arena.allocator();
    var child = try spawn(repo);
    defer child.kill(f.io);
    var manifest = m;
    manifest.role = .recovery;
    manifest.namespace = ns;
    try f.send(child.stdin.?.handle, f.Manifest, manifest);
    const hello = try f.receive(child.stdout.?.handle, f.Hello, a);
    try repo.verify(hello.value);
    try t.expect(!hello.value.current.eql(ns.workspace_id));
    try t.expect(!std.meta.eql(hello.value.boot, old_boot));
    const grant: storage.recovery.GrantData = .{ .store_id = ns.store_id, .store_root_id = (try storage.metadata(repo.state_witness.handle, true)).id, .original_workspace = ns.workspace_id, .current_workspace = hello.value.current, .current_boot = hello.value.boot, .namespace_digest = try ns.digest(), .security_domain = ns.security_domain, .policy_digest = ns.policy_digest, .approved_tasks = &.{f.task.task_id}, .exclusive_recovery = true, .publication_digests = if (repo.publication) |*w| &.{try w.validate()} else &.{} };
    try f.send(child.stdin.?.handle, storage.recovery.GrantData, grant);
    if (m.kill_recovery) {
        const ack = try f.receive(child.stdout.?.handle, f.Ack, a);
        try t.expectEqual(@as(u8, 11), ack.value.point);
        try kill(&child);
        std.debug.print("T12 recovery append SIGKILL verified\n", .{});
        var again = m;
        again.kill_recovery = false;
        return recovery(repo, again, ns, old_boot);
    }
    const result = try f.receive(child.stdout.?.handle, f.Result, a);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(f.io));
    return result.value;
}
test "WR-005 ten real SIGKILL writer points each patch create and fresh recovery twice" {
    for ([_]bool{ false, true }) |create| for (1..11) |point| {
        var repo = try Repo.init(create);
        defer repo.deinit();
        const a = repo.arena.allocator();
        const before = try repo.targetMetadata();
        var child = try spawn(&repo);
        defer child.kill(f.io);
        const manifest: f.Manifest = .{ .role = .writer, .point = @intCast(point), .create = create, .root = repo.root.canonical_path, .state = repo.state };
        try f.send(child.stdin.?.handle, f.Manifest, manifest);
        const hello = try f.receive(child.stdout.?.handle, f.Hello, a);
        try repo.verify(hello.value);
        try f.send(child.stdin.?.handle, bool, true);
        const ack = try writerAck(&repo, &child);
        try t.expectEqual(@as(u8, @intCast(point)), ack.value.point);
        try t.expectEqual(hello.value.namespace.store_id, ack.value.store);
        const pid = child.id.?;
        try kill(&child);
        try repo.bytes(create, point >= 7);
        const after_kill = try repo.targetMetadata();
        const result = try recovery(&repo, manifest, hello.value.namespace, hello.value.boot);
        if (point < 4) {
            try t.expect(result.receipt == null and result.uncertain == 0);
        } else if (point == 4) {
            try t.expect(result.receipt == null and result.uncertain == 1);
        } else {
            const receipt = result.receipt orelse return error.MissingReceipt;
            try t.expectEqual(point >= 7, receipt.applied);
            try t.expectEqual(ack.value.receipt_id.?, receipt.id);
            try t.expectEqual(ack.value.digest, receipt.op_digest);
            if (point == 7) try t.expectEqual(storage.receipts.Origin.recovered, result.origin.?);
        }
        const again = try recovery(&repo, manifest, hello.value.namespace, hello.value.boot);
        const Case = struct { point: usize, create: bool, pid: std.posix.pid_t, signal: []const u8, binary: []const u8, mode: []const u8, manifest: f.Manifest, hello: f.Hello, ack: f.Ack, first: f.Result, second: f.Result, target_hash: ?core.Sha256, target_length: u64, before: ?storage.Metadata, after_kill: ?storage.Metadata, after_recovery: ?storage.Metadata };
        var case_buffer: [64 * 1024]u8 = undefined;
        var case_writer = std.Io.Writer.fixed(&case_buffer);
        try std.json.Stringify.value(Case{ .point = point, .create = create, .pid = pid, .signal = "SIGKILL", .binary = child_exe, .mode = @tagName(@import("builtin").mode), .manifest = manifest, .hello = hello.value, .ack = ack.value, .first = result, .second = again, .target_hash = if (create and point < 7) null else storage.receipts.hash(try f.content(a, point >= 7)), .target_length = if (create and point < 7) 0 else f.size, .before = before, .after_kill = after_kill, .after_recovery = try repo.targetMetadata() }, .{ .whitespace = .indent_2 }, &case_writer);
        try repo.tmp.dir.writeFile(f.io, .{ .sub_path = "case.json", .data = case_writer.buffered() });
        try t.expectEqual(result.sequence, again.sequence);
        if (result.receipt) |r| try t.expect(storage.receiptEqual(r, again.receipt.?));
        try repo.bytes(create, point >= 7);
        std.debug.print("T12 C{d:0>2} {s} pid={d} SIGKILL fresh=2 sequence={d} committed={d} aborted={d} uncertain={d}\n", .{ point, if (create) "create" else "patch", pid, result.sequence, result.committed, result.aborted, result.uncertain });
    };
}
test "WR-005 authenticated persistent frame survives serialization and corrupt checksum refuses" {
    var buffer: [storage.receipts.max_frame_bytes]u8 = undefined;
    const encoded = try storage.receipts.encode(struct { durable: bool }, .{ .durable = true }, &buffer);
    const decoded = try storage.receipts.decode(struct { durable: bool }, f.A, encoded);
    defer decoded.deinit();
    try t.expect(decoded.value.durable);
    buffer[20] ^= 1;
    try t.expectError(error.RecoveryRequired, storage.receipts.decode(struct { durable: bool }, f.A, encoded));
}
const temp_name = ".zcr-tmp-0123456789abcdef0123456789abcdef";
fn prepared(fixture: *f.Fixture) !core.PreparedRecord {
    try fixture.root.dir.writeFile(f.io, .{ .sub_path = temp_name, .data = fixture.new });
    const temp = (try f.policy.paths.statAt(fixture.root.dir.handle, temp_name)).?.identity;
    const old = try f.policy.paths.statAt(fixture.root.dir.handle, "file.txt");
    return .{ .key = fixture.adapter.key, .op_digest = fixture.digest(), .path = .{ .bytes = "file.txt" }, .old_hash = if (old != null) storage.receipts.hash(fixture.old) else null, .new_hash = storage.receipts.hash(fixture.new), .generation = 917, .publication = .{ .workspace_id = fixture.session.bound_workspace, .root_id = fixture.identity.root_id, .parent_id = fixture.identity.root_id, .temp_id = .{ .device = temp.device, .inode = temp.inode }, .temp_name = temp_name, .old_file_id = if (old) |o| .{ .device = o.identity.device, .inode = o.identity.inode } else null, .fence = 1, .durability = .durable, .receipt_id = .{ .uuid = @splat(37) } } };
}
fn receiptFor(p: core.PreparedRecord, applied: bool) core.Receipt {
    return .{ .id = p.publication.?.receipt_id, .idempotency_key = p.key.idempotency_key, .op_digest = p.op_digest, .applied = applied, .durable = false, .cancellation_observed = false, .old_hash = p.old_hash, .new_hash = p.new_hash, .generation = 1001, .error_code = if (applied) null else .E_IO };
}
const LocalWitness = struct {
    repo: *Repo,
    used: bool = false,
    fn publication(ctx: ?*anyopaque, _: storage.recovery.GrantData, p: core.PreparedRecord) core.RecoverError!void {
        const self: *LocalWitness = @ptrCast(@alignCast(ctx.?));
        if (!self.used) return error.RecoveryRequired;
        if (self.repo.publication) |*w| {
            const digest = w.validate() catch return error.RecoveryRequired;
            if (std.meta.eql(digest, try storage.recovery.publicationDigest(p))) return;
        }
        return error.RecoveryRequired;
    }
    fn validate(ctx: ?*anyopaque, data: storage.recovery.GrantData, ns: storage.Namespace) core.RecoverError!void {
        const self: *LocalWitness = @ptrCast(@alignCast(ctx.?));
        if (self.used) return error.RecoveryRequired;
        if (!std.meta.eql(data.store_root_id, (storage.metadata(self.repo.state_witness.handle, true) catch return error.RecoveryRequired).id)) return error.RecoveryRequired;
        self.repo.witness.validate(f.io) catch return error.RecoveryRequired;
        if (!storage.recovery.identityMatches(&self.repo.witness, ns)) return error.RecoveryRequired;
        self.used = true;
    }
};
fn grantFor(fixture: *f.Fixture, ns: storage.Namespace) !storage.recovery.GrantData {
    return .{ .store_id = ns.store_id, .store_root_id = fixture.store.root_id, .original_workspace = ns.workspace_id, .current_workspace = fixture.session.bound_workspace, .current_boot = fixture.registry.bootNonce(), .namespace_digest = try ns.digest(), .security_domain = ns.security_domain, .policy_digest = ns.policy_digest, .approved_tasks = &.{f.task.task_id}, .exclusive_recovery = true, .publication_digests = &.{} };
}
test "WR-006 persistent binding receipt lifetime Busy cap refusal and transition validation" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
    defer fixture.deinit();
    const p = try prepared(fixture);
    try t.expectEqual(core.JournalResult.stored, try fixture.adapter.interface().prepare(p));
    const initial = fixture.store.disk_bytes;
    try t.expectError(error.Busy, fixture.adapter.interface().prepare(p));
    try t.expectError(error.Busy, fixture.adapter.interface().lookup(p.key));
    var wrong = p;
    wrong.key.security_domain.id += 1;
    try t.expectError(error.InvalidArgument, fixture.adapter.interface().prepare(wrong));
    var other = try storage.Adapter.init(&fixture.store, f.task.task_id, "other", fixture.digest());
    wrong = p;
    wrong.key = other.key;
    try t.expectError(error.Busy, other.interface().prepare(wrong));
    try t.expectEqual(initial, fixture.store.disk_bytes);
    var r = receiptFor(p, true);
    try t.expectEqual(core.JournalResult.stored, try fixture.adapter.interface().transition(.{ .applied = r }));
    const seq = fixture.store.head.?.sequence;
    try t.expectEqual(core.JournalResult.stored, try fixture.adapter.interface().transition(.{ .applied = r }));
    try t.expectEqual(seq, fixture.store.head.?.sequence);
    var bad = r;
    bad.generation += 1;
    try t.expectError(error.InvalidArgument, fixture.adapter.interface().record(bad));
    try t.expectError(error.InvalidArgument, fixture.adapter.interface().record(r));
    r.durable = true;
    try t.expectEqual(core.JournalResult.stored, try fixture.adapter.interface().record(r));
    const borrowed = (try fixture.adapter.interface().lookup(p.key)).found;
    fixture.store.options.caps.entries = fixture.store.count;
    wrong.path.bytes = "other.txt";
    try t.expectError(error.ResourceExhausted, other.interface().prepare(wrong));
    try t.expect(storage.receiptEqual(r, borrowed));
    try t.expectEqual(@as(u32, 1), fixture.store.count);
    var other_task = try storage.Adapter.init(&fixture.store, .{ .uuid = @splat(77) }, f.key, fixture.digest());
    try t.expectEqual(core.JournalResult.absent, try other_task.interface().lookup(other_task.key));
}
test "WR-008 cold start and wrong grants fail closed without source mutation" {
    for (0..9) |variant| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const old = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer old.deinit();
        _ = try old.adapter.interface().prepare(try prepared(old));
        const fresh = try f.Fixture.init(repo.root.canonical_path, repo.state, false, old.store.options.namespace);
        defer fresh.deinit();
        try t.expectError(error.OutOfScope, fresh.registry.validateSession(old.session, old.registry.bootNonce()));
        try old.registry.setManagedWrite(old.session.bound_workspace, true);
        const stale_lease = try old.registry.acquireWriter(f.task, old.session.bound_workspace);
        try t.expectError(error.FenceMismatch, fresh.registry.validateLease(stale_lease));
        var data = try grantFor(fresh, old.store.options.namespace);
        switch (variant) {
            0 => {},
            1 => data.store_id[0] ^= 1,
            2 => data.current_boot[0] ^= 1,
            3 => data.security_domain.id += 1,
            4 => data.policy_digest[0] ^= 1,
            5 => data.approved_tasks = &.{.{ .uuid = @splat(55) }},
            6 => data.exclusive_recovery = false,
            7 => data.original_workspace.incarnation[0] ^= 1,
            8 => data.namespace_digest[0] ^= 1,
            else => unreachable,
        }
        var witness: LocalWitness = .{ .repo = &repo };
        var recoverer = storage.recovery.Recoverer.init(fresh.root, &fresh.registry, &fresh.store, if (variant == 0) null else .{ .data = data, .context = &witness, .validate = LocalWitness.validate, .validate_publication = LocalWitness.publication }, f.approved);
        try t.expectError(error.RecoveryRequired, recoverer.recover(f.io, fresh.reserved.allocator(), fresh.session.bound_workspace, fresh.adapter.interface()));
        try t.expectEqual(@as(u32, 1), fresh.store.head.?.sequence);
        try repo.bytes(false, false);
    }
}
test "WR-008 target mismatch temp replacement noop identity and generation reconciliation" {
    for (0..5) |variant| {
        var repo = try Repo.init(variant == 2);
        defer repo.deinit();
        const old = try f.Fixture.init(repo.root.canonical_path, repo.state, variant == 2, null);
        defer old.deinit();
        var p = try prepared(old);
        if (variant == 3) {
            @memcpy(old.new, old.old);
            try old.root.dir.writeFile(f.io, .{ .sub_path = temp_name, .data = old.old });
            p.new_hash = p.old_hash.?;
        }
        _ = try old.adapter.interface().prepare(p);
        repo.publication = try PublicationWitness.acquire(&repo, p);
        switch (variant) {
            0 => try old.root.dir.writeFile(f.io, .{ .sub_path = "file.txt", .data = "external mutation" }),
            1 => {
                try old.root.dir.deleteFile(f.io, temp_name);
                try old.root.dir.symLink(f.io, "sentinel", temp_name, .{});
            },
            2 => try old.root.dir.writeFile(f.io, .{ .sub_path = "file.txt", .data = old.new }),
            3, 4 => try old.root.dir.rename(temp_name, old.root.dir, "file.txt", f.io),
            else => unreachable,
        }
        const fresh = try f.Fixture.init(repo.root.canonical_path, repo.state, variant == 2, old.store.options.namespace);
        defer fresh.deinit();
        // Noop case has a deliberately custom digest; request adapter still binds the persisted digest.
        fresh.adapter.expected_digest = p.op_digest;
        var witness: LocalWitness = .{ .repo = &repo };
        var recoverer = storage.recovery.Recoverer.init(fresh.root, &fresh.registry, &fresh.store, .{ .data = try grantFor(fresh, old.store.options.namespace), .context = &witness, .validate = LocalWitness.validate, .validate_publication = LocalWitness.publication }, f.approved);
        var result = try recoverer.recover(f.io, fresh.reserved.allocator(), fresh.session.bound_workspace, fresh.adapter.interface());
        defer result.deinit();
        if (variant < 3) {
            try t.expectEqual(@as(u64, 1), result.value.uncertain);
            try t.expectError(error.RecoveryRequired, fresh.adapter.interface().lookup(fresh.adapter.key));
        } else {
            const receipt = (try fresh.adapter.interface().lookup(fresh.adapter.key)).found;
            try t.expect(receipt.applied and receipt.durable);
            try t.expectEqual(@as(u64, 2), receipt.generation);
            try t.expectEqual(storage.receipts.Origin.recovered, fresh.store.head.?.origin);
        }
        try t.expectEqualStrings("untouched sentinel\n", try repo.root.dir.readFileAlloc(f.io, "sentinel", repo.arena.allocator(), .limited(100)));
    }
}
test "WR-007 actual T11 persistent append failures preserve applied and quarantine" {
    for ([_]core.JournalState{ .prepared, .applied, .committed }) |state| for ([_]bool{ false, true }) |sync_failure| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer fixture.deinit();
        var fault: storage.Fault = .{ .short_writes = true, .fail_write_state = if (sync_failure) null else state, .fail_sync_state = if (sync_failure) state else null };
        fixture.store.fault = &fault;
        if (state == .prepared) {
            try t.expectError(error.RecoveryRequired, fixture.run(null));
            try repo.bytes(false, false);
        } else {
            const receipt = try fixture.run(null);
            try t.expect(receipt.applied and !receipt.durable);
            try t.expectEqual(@as(?core.errors.WireCode, .E_RECOVERY_REQUIRED), receipt.error_code);
            try repo.bytes(false, true);
        }
        try t.expectError(error.LeaseExpired, fixture.registry.acquireWriter(f.task, fixture.session.bound_workspace));
    };
}
test "WR-008 malformed complete journals never decode as absent or success" {
    for (0..6) |variant| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer fixture.deinit();
        _ = try fixture.adapter.interface().prepare(try prepared(fixture));
        const name = &fixture.store.head.?.name;
        const bytes = try fixture.state.dir.readFileAlloc(f.io, name, repo.arena.allocator(), .limited(storage.receipts.max_frame_bytes));
        switch (variant) {
            0 => bytes[25] ^= 1,
            1 => bytes[12] = 99,
            2 => std.mem.writeInt(u32, bytes[8..12], std.math.maxInt(u32), .little),
            3 => {
                const parsed = try storage.receipts.decode(storage.receipts.Frame, f.A, bytes);
                defer parsed.deinit();
                var frame = parsed.value;
                frame.sequence = 2;
                var buf: [storage.receipts.max_frame_bytes]u8 = undefined;
                const forged = try storage.receipts.encode(storage.receipts.Frame, frame, &buf);
                try fixture.state.dir.writeFile(f.io, .{ .sub_path = name, .data = forged });
            },
            4 => {
                const doubled = try std.mem.concat(repo.arena.allocator(), u8, &.{ bytes, bytes });
                try fixture.state.dir.writeFile(f.io, .{ .sub_path = name, .data = doubled });
            },
            5 => {
                const parsed = try storage.receipts.decode(storage.receipts.Frame, f.A, bytes);
                defer parsed.deinit();
                var frame = parsed.value;
                frame.prepared.path.bytes = "../sentinel";
                var buf: [storage.receipts.max_frame_bytes]u8 = undefined;
                const forged = try storage.receipts.encode(storage.receipts.Frame, frame, &buf);
                try fixture.state.dir.writeFile(f.io, .{ .sub_path = name, .data = forged });
            },
            else => unreachable,
        }
        if (variant < 3) try fixture.state.dir.writeFile(f.io, .{ .sub_path = name, .data = bytes });
        var opts = fixture.store.options;
        opts.create = false;
        try t.expectError(error.RecoveryRequired, storage.Store.init(opts));
        try repo.bytes(false, false);
    }
}
test "WR-008 malicious paths and private state modes are side effect free refusals" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
    defer fixture.deinit();
    const p = try prepared(fixture);
    for ([_][]const u8{ "/file.txt", "../file.txt", ".git/config", ".zcr-tmp-malicious", "file.txt/../sentinel" }) |path| {
        var bad = p;
        bad.path.bytes = path;
        try t.expectError(error.InvalidArgument, fixture.adapter.interface().prepare(bad));
    }
    for ([_][]const u8{ "/tmp/file", "../file", ".zcr-tmp-0123456789ABCDEF0123456789ABCDEF" }) |name| {
        var bad = p;
        bad.publication.?.temp_name = name;
        try t.expectError(error.InvalidArgument, fixture.adapter.interface().prepare(bad));
    }
    try t.expectEqual(@as(u32, 0), fixture.store.count);
    var options = fixture.store.options;
    options.create = false;
    options.caps.entries = storage.max_entries + 1;
    try t.expectError(error.InvalidArgument, storage.Store.init(options));
    options = fixture.store.options;
    options.create = false;
    try t.expectEqual(@as(c_int, 0), std.c.fchmod(fixture.state.dir.handle, 0o755));
    try t.expectError(error.RecoveryRequired, storage.Store.init(options));
    try t.expectEqual(@as(c_int, 0), std.c.fchmod(fixture.state.dir.handle, 0o700));
    try repo.bytes(false, false);
}
const DarwinAcl = struct {
    extern "c" fn acl_init(count: c_int) ?*anyopaque;
    extern "c" fn acl_free(acl: *anyopaque) c_int;
    extern "c" fn acl_create_entry(acl: *?*anyopaque, entry: *?*anyopaque) c_int;
    extern "c" fn acl_set_tag_type(entry: *anyopaque, tag: c_int) c_int;
    extern "c" fn acl_set_qualifier(entry: *anyopaque, qualifier: *const anyopaque) c_int;
    extern "c" fn acl_get_permset(entry: *anyopaque, perms: *?*anyopaque) c_int;
    extern "c" fn acl_add_perm(perms: *anyopaque, perm: c_int) c_int;
    extern "c" fn acl_set_fd_np(fd: c_int, acl: *anyopaque, kind: c_int) c_int;
    /// One ACL_EXTENDED_ALLOW read entry for a synthetic principal, as in t11_test.zig.
    fn grantRead(fd: c_int) !void {
        var acl: ?*anyopaque = acl_init(1) orelse return error.AclFixtureFailed;
        defer _ = acl_free(acl.?);
        var entry: ?*anyopaque = null;
        try t.expectEqual(@as(c_int, 0), acl_create_entry(&acl, &entry));
        try t.expectEqual(@as(c_int, 0), acl_set_tag_type(entry.?, 1)); // ACL_EXTENDED_ALLOW
        const principal: [16]u8 = .{ 0x98, 0x21, 0x34, 0x56, 0x78, 0x9a, 0x4b, 0xcd, 0x8e, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc };
        try t.expectEqual(@as(c_int, 0), acl_set_qualifier(entry.?, &principal));
        var perms: ?*anyopaque = null;
        try t.expectEqual(@as(c_int, 0), acl_get_permset(entry.?, &perms));
        try t.expectEqual(@as(c_int, 0), acl_add_perm(perms.?, 1 << 1)); // ACL_READ_DATA
        try t.expectEqual(@as(c_int, 0), acl_set_fd_np(fd, acl.?, 0x100)); // ACL_TYPE_EXTENDED
    }
    /// An empty extended ACL removes every entry.
    fn clear(fd: c_int) !void {
        const acl = acl_init(0) orelse return error.AclFixtureFailed;
        defer _ = acl_free(acl);
        try t.expectEqual(@as(c_int, 0), acl_set_fd_np(fd, acl, 0x100));
    }
};
test "WR-008 extended ACLs on private Darwin store state are refusals" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var repo = try Repo.init(false);
    defer repo.deinit();
    const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
    defer fixture.deinit();
    var options = fixture.store.options;
    options.create = false;

    // Mode 0700 and the right owner do not make a root with an extended ACL private.
    try DarwinAcl.grantRead(fixture.state.dir.handle);
    try t.expectError(error.RecoveryRequired, storage.Store.init(options));
    try t.expectError(error.RecoveryRequired, fixture.store.validateRoot());
    try DarwinAcl.clear(fixture.state.dir.handle);
    try fixture.store.validateRoot();

    // The same holds for a store file the store opens.
    const header = try fixture.state.dir.openFile(f.io, "namespace", .{ .mode = .read_write });
    defer header.close(f.io);
    try DarwinAcl.grantRead(header.handle);
    try t.expectError(error.RecoveryRequired, storage.Store.init(options));
    try DarwinAcl.clear(header.handle);
    try repo.bytes(false, false);
}
test "WR-005 killed recovery terminal append resumes in another fresh process" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    var child = try spawn(&repo);
    defer child.kill(f.io);
    var manifest: f.Manifest = .{ .role = .writer, .point = 7, .create = false, .root = repo.root.canonical_path, .state = repo.state };
    try f.send(child.stdin.?.handle, f.Manifest, manifest);
    const hello = try f.receive(child.stdout.?.handle, f.Hello, repo.arena.allocator());
    try repo.verify(hello.value);
    try f.send(child.stdin.?.handle, bool, true);
    const ack = try writerAck(&repo, &child);
    try t.expectEqual(@as(u8, 7), ack.value.point);
    try kill(&child);
    manifest.kill_recovery = true;
    const result = try recovery(&repo, manifest, hello.value.namespace, hello.value.boot);
    try t.expect(result.receipt.?.applied);
    try t.expectEqual(ack.value.receipt_id.?, result.receipt.?.id);
    manifest.kill_recovery = false;
    const again = try recovery(&repo, manifest, hello.value.namespace, hello.value.boot);
    try t.expect(storage.receiptEqual(result.receipt.?, again.receipt.?));
    try t.expectEqual(result.sequence, again.sequence);
    try repo.bytes(false, true);
}
test "WR-007 durable success short writes and parent sync failure retain truth" {
    for ([_]bool{ false, true }) |fail_sync| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer fixture.deinit();
        var fault: storage.Fault = .{ .short_writes = true };
        fixture.store.fault = &fault;
        var edit_fault: f.edit.Fault = .{ .failure = .sync };
        const receipt = try fixture.run(if (fail_sync) &edit_fault else null);
        try t.expect(receipt.applied and receipt.durable == !fail_sync);
        if (fail_sync) {
            try t.expectEqual(@as(?core.errors.WireCode, .E_DURABILITY), receipt.error_code);
            try t.expectError(error.LeaseExpired, fixture.registry.acquireWriter(f.task, fixture.session.bound_workspace));
            try t.expectError(error.Busy, fixture.adapter.interface().lookup(fixture.adapter.key));
        } else try t.expect(storage.receiptEqual(receipt, (try fixture.adapter.interface().lookup(fixture.adapter.key)).found));
        try repo.bytes(false, true);
    }
}
test "WR-008 temp FIFO hardlink replacement and unrecorded decoys remain untouched" {
    for (0..3) |variant| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const old = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer old.deinit();
        const p = try prepared(old);
        _ = try old.adapter.interface().prepare(p);
        repo.publication = try PublicationWitness.acquire(&repo, p);
        const decoy = ".zcr-tmp-ffffffffffffffffffffffffffffffff";
        try old.root.dir.writeFile(f.io, .{ .sub_path = decoy, .data = "unrecorded decoy" });
        try old.root.dir.deleteFile(f.io, temp_name);
        if (variant == 0) {
            // mkfifo takes a path on every POSIX system; mknodat/mkfifoat need macOS 13.
            const fifo = try std.fmt.allocPrintSentinel(repo.arena.allocator(), "{s}/{s}", .{ old.root.canonical_path, temp_name }, 0);
            try t.expectEqual(@as(c_int, 0), mkfifo(fifo.ptr, 0o600));
        } else if (variant == 1) {
            try t.expectEqual(@as(c_int, 0), std.c.linkat(old.root.dir.handle, "sentinel", old.root.dir.handle, temp_name, 0));
        } else try old.root.dir.writeFile(f.io, .{ .sub_path = temp_name, .data = old.new });
        const fresh = try f.Fixture.init(repo.root.canonical_path, repo.state, false, old.store.options.namespace);
        defer fresh.deinit();
        var witness: LocalWitness = .{ .repo = &repo };
        var recoverer = storage.recovery.Recoverer.init(fresh.root, &fresh.registry, &fresh.store, .{ .data = try grantFor(fresh, old.store.options.namespace), .context = &witness, .validate = LocalWitness.validate, .validate_publication = LocalWitness.publication }, f.approved);
        var report = try recoverer.recover(f.io, fresh.reserved.allocator(), fresh.session.bound_workspace, fresh.adapter.interface());
        defer report.deinit();
        try t.expectEqual(@as(u64, 1), report.value.uncertain);
        try t.expect((try f.policy.paths.statAt(fresh.root.dir.handle, temp_name)) != null);
        try t.expectEqualStrings("unrecorded decoy", try old.root.dir.readFileAlloc(f.io, decoy, repo.arena.allocator(), .limited(100)));
        try repo.bytes(false, false);
    }
}
test "WR-008 changed Git marker and missing parent witness reject reconciliation" {
    for ([_]bool{ false, true }) |change_marker| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const old = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer old.deinit();
        var p = try prepared(old);
        if (!change_marker) p.publication.?.parent_id.inode += 1;
        _ = try old.adapter.interface().prepare(p);
        const fresh = try f.Fixture.init(repo.root.canonical_path, repo.state, false, old.store.options.namespace);
        defer fresh.deinit();
        if (change_marker) {
            try old.root.dir.rename(".git", old.root.dir, "git-original", f.io);
            try old.root.dir.writeFile(f.io, .{ .sub_path = ".git", .data = "gitdir: git-original\n" });
        }
        var witness: LocalWitness = .{ .repo = &repo };
        var recoverer = storage.recovery.Recoverer.init(fresh.root, &fresh.registry, &fresh.store, .{ .data = try grantFor(fresh, old.store.options.namespace), .context = &witness, .validate = LocalWitness.validate, .validate_publication = LocalWitness.publication }, f.approved);
        if (change_marker) try t.expectError(error.RecoveryRequired, recoverer.recover(f.io, fresh.reserved.allocator(), fresh.session.bound_workspace, fresh.adapter.interface())) else {
            var report = try recoverer.recover(f.io, fresh.reserved.allocator(), fresh.session.bound_workspace, fresh.adapter.interface());
            defer report.deinit();
            try t.expectEqual(@as(u64, 1), report.value.uncertain);
        }
        try repo.bytes(false, false);
    }
}
const Queued = struct {
    fixture: *f.Fixture,
    ticket: ?f.workspace.CallbackTicket = null,
    parent: *f.edit.publish.Parent,
    temp: *f.edit.publish.Temp,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    blocked: bool = false,
    fn run(self: *Queued) void {
        defer self.done.store(true, .release);
        const guard = self.fixture.registry.acquireCommit(self.ticket.?) catch |err| {
            self.failure = err;
            return;
        };
        defer guard.release();
        self.parent.publishCreate(self.temp) catch |err| {
            self.failure = err;
            return;
        };
        guard.markApplied();
    }
    fn stage(ctx: ?*anyopaque, event: f.edit.Stage) void {
        const self: *Queued = @ptrCast(@alignCast(ctx.?));
        if (event == .after_read) {
            self.ticket = self.fixture.registry.beginCallback(self.fixture.lease.?) catch unreachable;
            return;
        }
        if (event != .after_commit) return;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch unreachable;
        var spins: usize = 0;
        while (spins < 100_000_000) : (spins += 1) {
            self.fixture.registry.mutex.lockUncancelable(f.io);
            self.blocked = self.fixture.registry.entries[0].?.publication_waiters != 0;
            self.fixture.registry.mutex.unlock(f.io);
            if (self.blocked or self.done.load(.acquire)) break;
            std.atomic.spinLoopHint();
        }
    }
};
test "WR-007 real persistent failures atomically block queued filesystem publication" {
    for (0..3) |variant| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer fixture.deinit();
        var parent = try f.edit.publish.Parent.open(f.io, fixture.root.dir, "queued.txt");
        defer parent.close(f.io);
        var temp = try parent.createTemp(f.io);
        defer temp.file.close(f.io);
        defer temp.cleanupName(&parent) catch unreachable;
        try temp.writeAll(f.io, "must not publish", .{ .requested = &fixture.cancel });
        var queued: Queued = .{ .fixture = fixture, .parent = &parent, .temp = &temp };
        var edit_fault: f.edit.Fault = .{ .context = &queued, .on_stage = Queued.stage, .failure = if (variant == 2) .sync else null };
        var store_fault: storage.Fault = .{ .fail_write_state = if (variant == 0) .applied else if (variant == 1) .committed else null };
        fixture.store.fault = &store_fault;
        const outcome = fixture.run(&edit_fault);
        if (queued.thread) |thread| thread.join();
        defer if (queued.ticket) |ticket| fixture.registry.endCallback(ticket) catch unreachable;
        const receipt = try outcome;
        try t.expect(receipt.applied and !receipt.durable);
        try t.expectEqual(@as(?core.errors.WireCode, if (variant == 2) .E_DURABILITY else .E_RECOVERY_REQUIRED), receipt.error_code);
        try t.expect(queued.blocked and queued.done.load(.acquire));
        try t.expectEqual(@as(?anyerror, error.FenceMismatch), queued.failure);
        try t.expect(!temp.published);
        try t.expect((try f.policy.paths.statAt(fixture.root.dir.handle, "queued.txt")) == null);
        try repo.bytes(false, true);
    }
}
test "WR-008 moved and recreated roots cannot use retained namespace continuity" {
    for ([_]bool{ false, true }) |recreate| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const old = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer old.deinit();
        _ = try old.adapter.interface().prepare(try prepared(old));
        const fresh = try f.Fixture.init(repo.root.canonical_path, repo.state, false, old.store.options.namespace);
        defer fresh.deinit();
        try repo.tmp.dir.rename("repo", repo.tmp.dir, "retired", f.io);
        if (recreate) {
            const base = try repo.tmp.dir.realPathFileAlloc(f.io, ".", repo.arena.allocator());
            try f.git(repo.arena.allocator(), base, &.{ "clone", "--no-hardlinks", "retired", "repo" });
        }
        var witness: LocalWitness = .{ .repo = &repo };
        var recoverer = storage.recovery.Recoverer.init(fresh.root, &fresh.registry, &fresh.store, .{ .data = try grantFor(fresh, old.store.options.namespace), .context = &witness, .validate = LocalWitness.validate, .validate_publication = LocalWitness.publication }, f.approved);
        try t.expectError(error.RecoveryRequired, recoverer.recover(f.io, fresh.reserved.allocator(), fresh.session.bound_workspace, fresh.adapter.interface()));
        try t.expectEqual(@as(u32, 1), fresh.store.head.?.sequence);
        try repo.bytes(false, false);
    }
}

test "WR-008 complete checksummed receipt chains reject generation and durability drift" {
    for (0..4) |variant| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer fixture.deinit();
        const p = try prepared(fixture);
        _ = try fixture.adapter.interface().prepare(p);
        const r = receiptFor(p, true);
        _ = try fixture.adapter.interface().transition(.{ .applied = r });
        const entry = fixture.store.head.?;
        var final = r;
        final.durable = true;
        if (variant == 0) final.generation += 1;
        if (variant == 1) final.durable = false;
        const frame: storage.receipts.Frame = .{ .store_id = fixture.store.options.namespace.store_id, .namespace_digest = fixture.store.namespace_digest, .sequence = 3, .previous = entry.digest, .state = .committed, .prepared = p, .receipt = final, .origin = if (variant == 2) .recovered else .live, .created_unix_ms = entry.created_unix_ms + @as(i64, if (variant == 3) 1 else 0) };
        var buf: [storage.receipts.max_frame_bytes]u8 = undefined;
        const bytes = try storage.receipts.encode(storage.receipts.Frame, frame, &buf);
        const file = try fixture.state.dir.openFile(f.io, &entry.name, .{ .mode = .read_write });
        defer file.close(f.io);
        try file.writePositionalAll(f.io, bytes, entry.valid_bytes);
        var opts = fixture.store.options;
        opts.create = false;
        try t.expectError(error.RecoveryRequired, storage.Store.init(opts));
    }
}

const Permissions = struct {
    fixture: *f.Fixture,
    variant: u8,
    file: ?std.Io.File = null,
    denied: bool = false,
    fn deny(self: *Permissions) void {
        const name: [:0]const u8 = if (self.variant == 0) "permission-probe" else &self.fixture.store.head.?.name;
        if (self.variant == 0) {
            t.expectEqual(@as(c_int, 0), std.c.fchmod(self.fixture.state.dir.handle, 0o500)) catch unreachable;
        } else {
            self.file = self.fixture.state.dir.openFile(f.io, name, .{ .mode = .read_write }) catch unreachable;
            t.expectEqual(@as(c_int, 0), std.c.fchmod(self.file.?.handle, 0)) catch unreachable;
        }
        const probe = std.posix.openatZ(self.fixture.state.dir.handle, name, .{ .ACCMODE = .RDWR, .CREAT = self.variant == 0, .EXCL = self.variant == 0, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch |err| {
            self.denied = err == error.AccessDenied;
            return;
        };
        std.Io.File.close(.{ .handle = probe, .flags = .{ .nonblocking = false } }, f.io);
    }
    fn restore(self: *Permissions) void {
        if (self.file) |file| {
            _ = std.c.fchmod(file.handle, 0o600);
            file.close(f.io);
        }
        _ = std.c.fchmod(self.fixture.state.dir.handle, 0o700);
    }
    fn journal(ctx: ?*anyopaque, event: storage.Stage) void {
        const self: *Permissions = @ptrCast(@alignCast(ctx.?));
        if (self.variant == 0 and event == .before_prepared) self.deny();
    }
    fn editor(ctx: ?*anyopaque, event: f.edit.Stage) void {
        const self: *Permissions = @ptrCast(@alignCast(ctx.?));
        if ((self.variant == 1 and event == .after_commit) or (self.variant == 2 and event == .before_record)) self.deny();
    }
};
test "WR-007 actual kernel EACCES before PREPARED after publish and before receipt" {
    for (0..3) |variant| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer fixture.deinit();
        var permissions: Permissions = .{ .fixture = fixture, .variant = @intCast(variant) };
        defer permissions.restore();
        var store_fault: storage.Fault = .{ .context = &permissions, .stage = Permissions.journal };
        fixture.store.fault = &store_fault;
        var edit_fault: f.edit.Fault = .{ .context = &permissions, .on_stage = Permissions.editor };
        if (variant == 0) try t.expectError(error.RecoveryRequired, fixture.run(&edit_fault)) else {
            const receipt = try fixture.run(&edit_fault);
            try t.expect(receipt.applied and !receipt.durable);
            try t.expectEqual(@as(?core.errors.WireCode, .E_RECOVERY_REQUIRED), receipt.error_code);
        }
        try t.expect(permissions.denied);
        try t.expectError(error.LeaseExpired, fixture.registry.acquireWriter(f.task, fixture.session.bound_workspace));
        try repo.bytes(false, variant != 0);
    }
}
const ConcurrentPrepare = struct {
    fixture: *f.Fixture,
    p: core.PreparedRecord,
    start: *std.atomic.Value(bool),
    result: ?core.JournalResult = null,
    failure: ?anyerror = null,
    fn run(self: *ConcurrentPrepare) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        self.result = self.fixture.adapter.interface().prepare(self.p) catch |err| {
            self.failure = err;
            return;
        };
    }
};
test "WR-006 concurrent same key admission persists once and bounds storage without eviction" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
    defer fixture.deinit();
    const p = try prepared(fixture);
    var start: std.atomic.Value(bool) = .init(false);
    var first: ConcurrentPrepare = .{ .fixture = fixture, .p = p, .start = &start };
    var second: ConcurrentPrepare = .{ .fixture = fixture, .p = p, .start = &start };
    const a = try std.Thread.spawn(.{}, ConcurrentPrepare.run, .{&first});
    const b = try std.Thread.spawn(.{}, ConcurrentPrepare.run, .{&second});
    start.store(true, .release);
    a.join();
    b.join();
    try t.expect((first.result != null and first.result.? == .stored and (second.failure != null and second.failure.? == error.Busy)) or (second.result != null and second.result.? == .stored and (first.failure != null and first.failure.? == error.Busy)));
    try t.expectEqual(@as(u32, 1), fixture.store.count);
    const entry = fixture.store.head.?;
    try t.expectEqual(@as(u32, 1), entry.sequence);
    var next = try storage.Adapter.init(&fixture.store, f.task.task_id, "capacity", fixture.digest());
    var other = p;
    other.key = next.key;
    other.path.bytes = "capacity.txt";
    fixture.store.options.caps.storage_bytes = fixture.store.obligated_bytes;
    const disk_before = fixture.store.disk_bytes;
    try t.expectError(error.ResourceExhausted, next.interface().prepare(other));
    try t.expectEqual(disk_before, fixture.store.disk_bytes);
    try t.expectEqual(@as(u32, 1), fixture.store.count);
}

test "WR-008 retained publication parent move and missing publication attestation quarantine" {
    for ([_]bool{ false, true }) |move| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const old = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer old.deinit();
        var p = try prepared(old);
        if (move) {
            try repo.root.dir.createDir(f.io, "parent", .default_dir);
            try repo.root.dir.rename("file.txt", repo.root.dir, "parent/file.txt", f.io);
            const temp_path = try std.fmt.allocPrint(repo.arena.allocator(), "parent/{s}", .{temp_name});
            try repo.root.dir.rename(temp_name, repo.root.dir, temp_path, f.io);
            p.path.bytes = "parent/file.txt";
            const dir = try repo.root.dir.openDir(f.io, "parent", .{});
            defer dir.close(f.io);
            p.publication.?.parent_id = (try storage.metadata(dir.handle, true)).id;
        }
        _ = try old.adapter.interface().prepare(p);
        if (move) repo.publication = try PublicationWitness.acquire(&repo, p);
        if (move) {
            try repo.root.dir.rename("parent", repo.root.dir, "moved-parent", f.io);
            try repo.root.dir.createDir(f.io, "parent", .default_dir);
            try repo.root.dir.writeFile(f.io, .{ .sub_path = "parent/file.txt", .data = old.old });
        }
        const fresh = try f.Fixture.init(repo.root.canonical_path, repo.state, false, old.store.options.namespace);
        defer fresh.deinit();
        var witness: LocalWitness = .{ .repo = &repo };
        var recoverer = storage.recovery.Recoverer.init(fresh.root, &fresh.registry, &fresh.store, .{ .data = try grantFor(fresh, old.store.options.namespace), .context = &witness, .validate = LocalWitness.validate, .validate_publication = LocalWitness.publication }, f.approved);
        var report = try recoverer.recover(f.io, fresh.reserved.allocator(), fresh.session.bound_workspace, fresh.adapter.interface());
        defer report.deinit();
        try t.expectEqual(@as(u64, 1), report.value.uncertain);
        try t.expectError(error.RecoveryRequired, fresh.adapter.interface().lookup(fresh.adapter.key));
        try t.expectEqualStrings("untouched sentinel\n", try repo.root.dir.readFileAlloc(f.io, "sentinel", repo.arena.allocator(), .limited(100)));
    }
}
test "WR-008 copied private journal directory cannot replace retained store witness" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    const old = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
    defer old.deinit();
    _ = try old.adapter.interface().prepare(try prepared(old));
    try repo.tmp.dir.rename("state", repo.tmp.dir, "old-state", f.io);
    try repo.tmp.dir.createDir(f.io, "state", .fromMode(0o700));
    const new_state = try repo.tmp.dir.openDir(f.io, "state", .{});
    defer new_state.close(f.io);
    for ([_][]const u8{ "namespace", &old.store.head.?.name }) |name| {
        const bytes = try old.state.dir.readFileAlloc(f.io, name, repo.arena.allocator(), .limited(storage.receipts.max_frame_bytes));
        const file = try new_state.createFile(f.io, name, .{ .permissions = .fromMode(0o600) });
        defer file.close(f.io);
        try file.writePositionalAll(f.io, bytes, 0);
    }
    const fresh = try f.Fixture.init(repo.root.canonical_path, repo.state, false, old.store.options.namespace);
    defer fresh.deinit();
    var witness: LocalWitness = .{ .repo = &repo };
    var grant = try grantFor(fresh, old.store.options.namespace);
    grant.store_root_id = (try storage.metadata(repo.state_witness.handle, true)).id;
    var recoverer = storage.recovery.Recoverer.init(fresh.root, &fresh.registry, &fresh.store, .{ .data = grant, .context = &witness, .validate = LocalWitness.validate, .validate_publication = LocalWitness.publication }, f.approved);
    try t.expectError(error.RecoveryRequired, recoverer.recover(f.io, fresh.reserved.allocator(), fresh.session.bound_workspace, fresh.adapter.interface()));
    try repo.bytes(false, false);
}

test "WR-006 ancient and future receipt clocks retain borrowed output under cap pressure" {
    for ([_]i64{ 1, std.math.maxInt(i64) }) |recorded_clock| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer fixture.deinit();
        const receipt = try fixture.run(null);
        const name = &fixture.store.head.?.name;
        const bytes = try fixture.state.dir.readFileAlloc(f.io, name, repo.arena.allocator(), .limited(storage.operation_credit));
        var rewritten: std.ArrayList(u8) = .empty;
        defer rewritten.deinit(repo.arena.allocator());
        var offset: usize = 0;
        var previous: core.Sha256 = @splat(0);
        while (offset < bytes.len) {
            const len = try storage.receipts.length(bytes[offset..]);
            const parsed = try storage.receipts.decode(storage.receipts.Frame, f.A, bytes[offset..][0..len]);
            defer parsed.deinit();
            var frame = parsed.value;
            frame.created_unix_ms = recorded_clock;
            frame.previous = previous;
            var buffer: [storage.receipts.max_frame_bytes]u8 = undefined;
            const encoded = try storage.receipts.encode(storage.receipts.Frame, frame, &buffer);
            try rewritten.appendSlice(repo.arena.allocator(), encoded);
            previous = storage.receipts.hash(encoded);
            offset += len;
        }
        try fixture.state.dir.writeFile(f.io, .{ .sub_path = name, .data = rewritten.items });
        var options = fixture.store.options;
        options.create = false;
        options.caps.entries = 1;
        var reopened = try storage.Store.init(options);
        defer reopened.deinit();
        var adapter = try storage.Adapter.init(&reopened, f.task.task_id, f.key, fixture.digest());
        const borrowed = (try adapter.interface().lookup(adapter.key)).found;
        var other = try storage.Adapter.init(&reopened, f.task.task_id, "clock-pressure", fixture.digest());
        var p = try prepared(fixture);
        p.key = other.key;
        p.path.bytes = "another.txt";
        try t.expectError(error.ResourceExhausted, other.interface().prepare(p));
        try t.expect(storage.receiptEqual(receipt, borrowed));
        try t.expectEqual(recorded_clock, reopened.head.?.created_unix_ms);
        try t.expectEqual(@as(u32, 1), reopened.count);
    }
}

test "WR-005 successive torn recovery sequences preserve each forensic suffix" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    const first = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
    defer first.deinit();
    const p = try prepared(first);
    _ = try first.adapter.interface().prepare(p);
    const r = receiptFor(p, true);
    var fault: storage.Fault = .{ .fail_write_state = .applied };
    first.store.fault = &fault;
    try t.expectError(error.IoFailure, first.adapter.interface().transition(.{ .applied = r }));
    const second = try f.Fixture.init(repo.root.canonical_path, repo.state, false, first.store.options.namespace);
    defer second.deinit();
    try second.store.preserveTail(second.store.head.?);
    _ = try second.adapter.interface().transition(.{ .applied = r });
    fault.fail_write_state = .committed;
    second.store.fault = &fault;
    var final = r;
    final.durable = true;
    try t.expectError(error.IoFailure, second.adapter.interface().record(final));
    const third = try f.Fixture.init(repo.root.canonical_path, repo.state, false, first.store.options.namespace);
    defer third.deinit();
    try third.store.preserveTail(third.store.head.?);
    _ = try third.adapter.interface().record(final);
    try t.expect(storage.receiptEqual(final, (try third.adapter.interface().lookup(third.adapter.key)).found));
    try t.expectEqual(@as(u32, 3), third.store.head.?.sequence);
    try repo.bytes(false, false);
}

const RetainPublication = struct {
    repo: *Repo,
    fixture: *f.Fixture,
    witness: ?PublicationWitness = null,
    fn stage(ctx: ?*anyopaque, event: f.edit.Stage) void {
        const self: *RetainPublication = @ptrCast(@alignCast(ctx.?));
        if (event == .after_prepare) self.witness = PublicationWitness.acquire(self.repo, self.fixture.store.head.?.prepared.?) catch @panic("publication witness acquisition failed");
    }
};
fn historyRecovery(repo: *Repo, fixture: *f.Fixture, witnesses: *[2]PublicationWitness) !f.HistoryResult {
    var child = try spawn(repo);
    defer child.kill(f.io);
    const ns = fixture.store.options.namespace;
    try f.send(child.stdin.?.handle, f.Manifest, .{ .role = .recovery, .point = 10, .create = false, .root = repo.root.canonical_path, .state = repo.state, .namespace = ns, .history = true });
    const hello = try f.receive(child.stdout.?.handle, f.Hello, repo.arena.allocator());
    try repo.verify(hello.value);
    try t.expect(!hello.value.current.eql(ns.workspace_id));
    try t.expect(!std.meta.eql(hello.value.boot, fixture.registry.bootNonce()));
    const digests = [_]core.Sha256{ try witnesses[0].validate(), try witnesses[1].validate() };
    const grant: storage.recovery.GrantData = .{ .store_id = ns.store_id, .store_root_id = (try storage.metadata(repo.state_witness.handle, true)).id, .original_workspace = ns.workspace_id, .current_workspace = hello.value.current, .current_boot = hello.value.boot, .namespace_digest = try ns.digest(), .security_domain = ns.security_domain, .policy_digest = ns.policy_digest, .approved_tasks = &.{f.task.task_id}, .exclusive_recovery = true, .publication_digests = &digests };
    try f.send(child.stdin.?.handle, storage.recovery.GrantData, grant);
    const result = try f.receive(child.stdout.?.handle, f.HistoryResult, repo.arena.allocator());
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(f.io));
    return result.value;
}
test "WR-006 F1 terminal history survives actual commit commit and abort commit fresh restart" {
    for (0..3) |variant| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer fixture.deinit();
        var retain: RetainPublication = .{ .repo = &repo, .fixture = fixture };
        var fault: f.edit.Fault = .{ .context = &retain, .on_stage = RetainPublication.stage, .failure = if (variant == 1) .publish else null };
        const first = if (variant == 1) blk: {
            try t.expectError(error.IoFailure, fixture.run(&fault));
            break :blk (try fixture.adapter.interface().lookup(fixture.adapter.key)).found;
        } else try fixture.run(&fault);
        var witnesses: [2]PublicationWitness = undefined;
        witnesses[0] = retain.witness.?;
        defer witnesses[0].deinit();
        if (variant != 1) @memcpy(fixture.old, fixture.new);
        // Variant 2 deliberately replaces the target with identical bytes but
        // a distinct inode; both historical receipts must remain replayable.
        if (variant != 2) @memset(fixture.new, 'C');
        fixture.adapter = try storage.Adapter.init(&fixture.store, f.task.task_id, "history-second", fixture.digest());
        fault.failure = null;
        const second = try fixture.runKey("history-second", &fault);
        witnesses[1] = retain.witness.?;
        defer witnesses[1].deinit();
        try t.expect(!std.meta.eql(first.id, second.id));
        try t.expectEqual(variant != 1, first.applied);
        try t.expect(second.applied and second.durable);
        const before = (try repo.targetMetadata()).?;
        const one = try historyRecovery(&repo, fixture, &witnesses);
        const two = try historyRecovery(&repo, fixture, &witnesses);
        for ([_]f.HistoryResult{ one, two }) |result| {
            try t.expectEqual(@as(u64, 0), result.uncertain);
            try t.expectEqual(@as(u64, if (variant == 1) 1 else 2), result.committed);
            try t.expectEqual(@as(u64, if (variant == 1) 1 else 0), result.aborted);
            try t.expect(storage.receiptEqual(first, result.receipts[0]));
            try t.expect(storage.receiptEqual(second, result.receipts[1]));
        }
        try t.expectEqual(one.sequences, two.sequences);
        try t.expectEqual(before, (try repo.targetMetadata()).?);
        try t.expectEqualSlices(u8, fixture.new, try repo.root.dir.readFileAlloc(f.io, "file.txt", repo.arena.allocator(), .limited(f.size + 1)));
        try t.expectEqualStrings("untouched sentinel\n", try repo.root.dir.readFileAlloc(f.io, "sentinel", repo.arena.allocator(), .limited(100)));
        const Evidence = struct { variant: usize, original: [2]core.Receipt, first: f.HistoryResult, second: f.HistoryResult, target: storage.Metadata };
        var buf: [64 * 1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try std.json.Stringify.value(Evidence{ .variant = variant, .original = .{ first, second }, .first = one, .second = two, .target = before }, .{}, &w);
        try repo.tmp.dir.writeFile(f.io, .{ .sub_path = "history.json", .data = w.buffered() });
    }
}
test "WR-005 F2 terminal prefixes normalize incomplete uncertainty tails before replay" {
    for ([_]bool{ false, true }) |abort| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer fixture.deinit();
        var retain: RetainPublication = .{ .repo = &repo, .fixture = fixture };
        var fault: f.edit.Fault = .{ .context = &retain, .on_stage = RetainPublication.stage, .failure = if (abort) .publish else null };
        const receipt = if (abort) blk: {
            try t.expectError(error.IoFailure, fixture.run(&fault));
            break :blk (try fixture.adapter.interface().lookup(fixture.adapter.key)).found;
        } else try fixture.run(&fault);
        repo.publication = retain.witness.?;
        const entry = fixture.store.head.?;
        const sequence = entry.sequence;
        const valid = entry.valid_bytes;
        var interrupted: storage.Fault = .{ .fail_write_state = .uncertain };
        fixture.store.fault = &interrupted;
        try t.expectError(error.IoFailure, fixture.store.append(entry, .uncertain, receipt, entry.origin, entry.reason, true));
        const raw = try fixture.state.dir.readFileAlloc(f.io, &entry.name, repo.arena.allocator(), .limited(storage.operation_credit));
        const suffix = raw[@intCast(valid)..];
        try t.expect(suffix.len > storage.receipts.header_bytes);
        const manifest: f.Manifest = .{ .role = .recovery, .point = 10, .create = false, .root = repo.root.canonical_path, .state = repo.state };
        const one = try recovery(&repo, manifest, fixture.store.options.namespace, fixture.registry.bootNonce());
        const two = try recovery(&repo, manifest, fixture.store.options.namespace, fixture.registry.bootNonce());
        for ([_]f.Result{ one, two }) |result| {
            try t.expectEqual(@as(u64, 0), result.uncertain);
            try t.expectEqual(@as(u64, if (abort) 0 else 1), result.committed);
            try t.expectEqual(@as(u64, if (abort) 1 else 0), result.aborted);
            try t.expect(storage.receiptEqual(receipt, result.receipt.?));
            try t.expectEqual(sequence, result.sequence);
        }
        const tail_name = try std.fmt.allocPrint(repo.arena.allocator(), "{s}.tail-{x:0>2}", .{ entry.name, sequence + 1 });
        try t.expectEqualSlices(u8, suffix, try fixture.state.dir.readFileAlloc(f.io, tail_name, repo.arena.allocator(), .limited(storage.receipts.max_frame_bytes)));
        try t.expectEqualSlices(u8, raw[0..@intCast(valid)], try fixture.state.dir.readFileAlloc(f.io, &entry.name, repo.arena.allocator(), .limited(storage.operation_credit)));
        try repo.bytes(false, !abort);
    }
}

test "WR-008 F2 failed tail preservation and complete uncertainty remain quarantined" {
    for ([_]bool{ false, true }) |abort| for ([_]bool{ false, true }) |complete| {
        var repo = try Repo.init(false);
        defer repo.deinit();
        const old = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
        defer old.deinit();
        var retain: RetainPublication = .{ .repo = &repo, .fixture = old };
        var fault: f.edit.Fault = .{ .context = &retain, .on_stage = RetainPublication.stage, .failure = if (abort) .publish else null };
        const receipt = if (abort) blk: {
            try t.expectError(error.IoFailure, old.run(&fault));
            break :blk (try old.adapter.interface().lookup(old.adapter.key)).found;
        } else try old.run(&fault);
        repo.publication = retain.witness.?;
        const entry = old.store.head.?;
        const sequence = entry.sequence;
        const terminal = entry.state;
        var interrupted: storage.Fault = .{ .fail_write_state = .uncertain };
        if (complete) {
            try old.store.append(entry, .uncertain, receipt, entry.origin, entry.reason, true);
        } else {
            old.store.fault = &interrupted;
            try t.expectError(error.IoFailure, old.store.append(entry, .uncertain, receipt, entry.origin, entry.reason, true));
            const name = try std.fmt.allocPrint(repo.arena.allocator(), "{s}.tail-{x:0>2}", .{ entry.name, sequence + 1 });
            const conflicting = try old.state.dir.createFile(f.io, name, .{ .permissions = .fromMode(0o600) });
            defer conflicting.close(f.io);
            try old.state.dir.writeFile(f.io, .{ .sub_path = name, .data = "preserve conflicting forensic evidence" });
        }
        const raw = try old.state.dir.readFileAlloc(f.io, &entry.name, repo.arena.allocator(), .limited(storage.operation_credit));
        const fresh = try f.Fixture.init(repo.root.canonical_path, repo.state, false, old.store.options.namespace);
        defer fresh.deinit();
        var witness: LocalWitness = .{ .repo = &repo };
        var recoverer = storage.recovery.Recoverer.init(fresh.root, &fresh.registry, &fresh.store, .{ .data = try grantFor(fresh, old.store.options.namespace), .context = &witness, .validate = LocalWitness.validate, .validate_publication = LocalWitness.publication }, f.approved);
        var report = try recoverer.recover(f.io, fresh.reserved.allocator(), fresh.session.bound_workspace, fresh.adapter.interface());
        defer report.deinit();
        try t.expectEqual(@as(u64, 1), report.value.uncertain);
        try t.expectEqual(@as(u64, 0), report.value.committed + report.value.aborted);
        try t.expectEqual(@as(usize, 1), report.value.quarantined_paths.len);
        try t.expectError(error.RecoveryRequired, fresh.adapter.interface().lookup(fresh.adapter.key));
        try t.expectEqual(if (complete) core.JournalState.uncertain else terminal, fresh.store.head.?.state);
        try t.expectEqual(sequence + @as(u32, if (complete) 1 else 0), fresh.store.head.?.sequence);
        try t.expectError(error.LeaseExpired, fresh.registry.acquireWriter(f.task, fresh.session.bound_workspace));
        try t.expectEqualSlices(u8, raw, try fresh.state.dir.readFileAlloc(f.io, &entry.name, repo.arena.allocator(), .limited(storage.operation_credit)));
        try repo.bytes(false, !abort);
    };
}

test "WR-008 host witness grants once and refuses a replaced temp name after unlink" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
    defer fixture.deinit();
    const p = try prepared(fixture);
    const ns = fixture.store.options.namespace;
    const data = try grantFor(fixture, ns);
    // The production host retains the root/Git/common identity, the private state
    // directory and, per pending publication, the parent, temp and original handles.
    var witness = storage.recovery.HostWitness.init(f.io, &repo.witness, repo.state_witness);
    defer witness.deinit();
    const parent = try std.Io.Dir.openDirAbsolute(f.io, repo.root.canonical_path, .{});
    try witness.retainPublication(parent, p);
    const grant = witness.grant(data);
    const validate_publication = grant.validate_publication.?;
    // A publication is never attested before the one-use continuity check.
    try t.expectError(error.RecoveryRequired, validate_publication(grant.context, data, p));
    try grant.validate(grant.context, data, ns);
    try t.expectError(error.RecoveryRequired, grant.validate(grant.context, data, ns));
    try validate_publication(grant.context, data, p);
    var other = p;
    other.generation += 1;
    try t.expectError(error.RecoveryRequired, validate_publication(grant.context, data, other));
    // The retained descriptor keeps its inode after unlink, so only the current
    // name's identity shows that the temp file was replaced.
    try repo.root.dir.deleteFile(f.io, temp_name);
    try repo.root.dir.writeFile(f.io, .{ .sub_path = temp_name, .data = fixture.new });
    try t.expectError(error.RecoveryRequired, validate_publication(grant.context, data, p));
}

test "WR-008 host witness accepts an applied publication and refuses a foreign target" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    const fixture = try f.Fixture.init(repo.root.canonical_path, repo.state, false, null);
    defer fixture.deinit();
    const p = try prepared(fixture);
    const ns = fixture.store.options.namespace;
    const data = try grantFor(fixture, ns);
    var witness = storage.recovery.HostWitness.init(f.io, &repo.witness, repo.state_witness);
    defer witness.deinit();
    const parent = try std.Io.Dir.openDirAbsolute(f.io, repo.root.canonical_path, .{});
    try witness.retainPublication(parent, p);
    const grant = witness.grant(data);
    try grant.validate(grant.context, data, ns);
    // Publication renames the temp onto the target: the target name now resolves
    // to the retained temp and the temp name is gone. Recovery must still see it.
    try repo.root.dir.rename(temp_name, repo.root.dir, "file.txt", f.io);
    try grant.validate_publication.?(grant.context, data, p);
    // A file that is neither the retained original nor the temp is refused.
    try repo.root.dir.deleteFile(f.io, "file.txt");
    try repo.root.dir.writeFile(f.io, .{ .sub_path = "file.txt", .data = fixture.new });
    try t.expectError(error.RecoveryRequired, grant.validate_publication.?(grant.context, data, p));
}
