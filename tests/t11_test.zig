const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const workspace = @import("zcr_workspace");
const edit = @import("zcr_fs_edit");
const t = std.testing;
const io = t.io;
const A = t.allocator;
const MiB = core.limits.MiB;
const approved: core.Policy = .{ .digest = @splat(9), .state = .active, .read_paths = &.{.{ .bytes = "." }}, .write_paths = &.{.{ .bytes = "." }}, .immutable_paths = &.{}, .operations = &.{ .read, .patch, .create }, .max_changed_files = 32 };
fn hash(bytes: []const u8) core.ContentHash {
    var result: core.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

const FakeJournal = struct {
    const Entry = struct { key: [128]u8 = undefined, key_len: usize, digest: core.Sha256, receipt: ?core.Receipt = null, publication: ?core.PublicationIdentity = null, temp_name: [41]u8 = undefined };
    session: core.SessionContext,
    entries: [16]?Entry = @splat(null),
    prepares: usize = 0,
    records: usize = 0,
    applied_transitions: usize = 0,
    aborted_transitions: usize = 0,
    fail_transition: bool = false,
    lookup_error: ?core.JournalError = null,
    prepare_error: ?core.JournalError = null,
    impossible_lookup: bool = false,
    impossible_prepare: bool = false,
    last_transition: ?core.JournalTransition = null,
    mutex: std.Io.Mutex = .init,
    fn interface(self: *FakeJournal) core.JournalStore {
        return .{ .context = self, .vtable = &.{ .prepare = prepare, .record = record, .lookup = lookup } };
    }
    fn transitionInterface(self: *FakeJournal) core.JournalStore {
        return .{ .context = self, .vtable = &.{ .prepare = prepare, .record = record, .lookup = lookup, .transition = transition } };
    }
    fn bound(self: *FakeJournal, key: core.JournalKey) bool {
        return key.security_domain.id == self.session.security_domain.id and std.mem.eql(u8, &key.workspace_incarnation, &self.session.bound_workspace.incarnation) and std.mem.eql(u8, &key.task_id.uuid, &self.session.bound_task.uuid);
    }
    fn find(self: *FakeJournal, key: []const u8) ?*Entry {
        for (&self.entries) |*entry| if (entry.* != null) {
            const e = &entry.*.?;
            if (std.mem.eql(u8, e.key[0..e.key_len], key)) return e;
        };
        return null;
    }
    fn lookup(context: *anyopaque, key: core.JournalKey) core.JournalError!core.JournalResult {
        const self: *FakeJournal = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.bound(key)) return error.InvalidArgument;
        if (self.lookup_error) |err| return err;
        if (self.impossible_lookup) return .stored;
        if (self.find(key.idempotency_key)) |entry| {
            if (entry.receipt) |receipt| return .{ .found = receipt };
            return error.Busy;
        }
        return .absent;
    }
    fn prepare(context: *anyopaque, prepared: core.PreparedRecord) core.JournalError!core.JournalResult {
        const self: *FakeJournal = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.bound(prepared.key) or prepared.key.idempotency_key.len > 128) return error.InvalidArgument;
        self.prepares += 1;
        if (self.find(prepared.key.idempotency_key)) |entry| {
            if (!std.mem.eql(u8, &entry.digest, &prepared.op_digest)) return .{ .conflict = entry.digest };
            if (entry.receipt) |receipt| return .{ .found = receipt };
            return error.Busy;
        }
        for (&self.entries) |*entry| if (entry.* == null) {
            entry.* = .{ .key_len = prepared.key.idempotency_key.len, .digest = prepared.op_digest };
            @memcpy(entry.*.?.key[0..entry.*.?.key_len], prepared.key.idempotency_key);
            if (prepared.publication) |publication| {
                if (publication.temp_name.len != 41) return error.InvalidArgument;
                entry.*.?.publication = publication;
                @memcpy(&entry.*.?.temp_name, publication.temp_name);
                entry.*.?.publication.?.temp_name = &entry.*.?.temp_name;
            }
            // Model an append that became observable before reporting failure.
            if (self.prepare_error) |err| return err;
            if (self.impossible_prepare) return .absent;
            return .stored;
        };
        return error.ResourceExhausted;
    }
    fn record(context: *anyopaque, receipt: core.Receipt) core.JournalError!core.JournalResult {
        const self: *FakeJournal = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // Namespace comes from this bound store; never infer it from a bare key.
        const entry = self.find(receipt.idempotency_key) orelse return error.InvalidArgument;
        if (!std.mem.eql(u8, &entry.digest, &receipt.op_digest)) return error.InvalidArgument;
        self.records += 1;
        entry.receipt = receipt;
        entry.receipt.?.idempotency_key = entry.key[0..entry.key_len];
        return .stored;
    }
    fn transition(context: *anyopaque, event: core.JournalTransition) core.JournalError!core.JournalResult {
        const self: *FakeJournal = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.fail_transition) return error.IoFailure;
        const receipt = switch (event) {
            inline else => |r| r,
        };
        const entry = self.find(receipt.idempotency_key) orelse return error.InvalidArgument;
        const publication = entry.publication orelse return error.InvalidArgument;
        if (!std.mem.eql(u8, &entry.digest, &receipt.op_digest) or !std.meta.eql(publication.receipt_id, receipt.id)) return error.InvalidArgument;
        switch (event) {
            .applied => self.applied_transitions += 1,
            .aborted => self.aborted_transitions += 1,
        }
        self.last_transition = event;
        return .stored;
    }
};

const Fixture = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    registry: workspace.Registry,
    authorizer: policy.Authorizer,
    session: core.SessionContext,
    lease: core.WriterLease,
    task: core.TaskContext,
    root: core.TrustedRoot,
    journal: FakeJournal,
    cancel: std.atomic.Value(bool) = .init(false),
    budget_counters: memory.accounting.Counters = .{},
    allocation_counters: memory.accounting.Counters = .{},
    budget: memory.Budget,
    reservation: core.Reservation,
    reserved: memory.ReservedAllocator,
    editor: edit.Editor,
    fn init(bytes: []const u8) !*Fixture {
        const self = try A.create(Fixture);
        errdefer A.destroy(self);
        self.* = .{ .tmp = t.tmpDir(.{}), .arena = .init(A), .registry = undefined, .authorizer = undefined, .session = undefined, .lease = undefined, .task = undefined, .root = undefined, .journal = undefined, .budget = undefined, .reservation = undefined, .reserved = undefined, .editor = undefined };
        const a = self.arena.allocator();
        const path = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        var env: std.process.Environ.Map = .init(a);
        try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        const result = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/git", "-C", path, "init", "-q", "-b", "main" }, .environ_map = &env });
        try t.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try self.tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = bytes });
        const added = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/git", "-C", path, "add", "file.txt" }, .environ_map = &env });
        try t.expectEqual(std.process.Child.Term{ .exited = 0 }, added.term);
        const committed = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/git", "-C", path, "-c", "user.name=T11", "-c", "user.email=t11@example.invalid", "commit", "-q", "-m", "fixture" }, .environ_map = &env });
        try t.expectEqual(std.process.Child.Term{ .exited = 0 }, committed.term);
        self.root = .{ .dir = try std.Io.Dir.openDirAbsolute(io, path, .{}), .canonical_path = path };
        self.registry = try workspace.Registry.init(a, io, .{ .git_executable = "/usr/bin/git" });
        const id = try self.registry.registerWorkspace(io, self.root, approved);
        const task: core.TaskContext = .{ .task_id = .{ .uuid = @splat(4) }, .base_commit = "0123456789012345678901234567890123456789", .scope_digest = approved.digest, .fence = 1, .expires_at_unix_ms = std.math.maxInt(i64) };
        self.task = task;
        self.session = .{ .session_id = .{ .uuid = @splat(7) }, .security_domain = .{ .id = 1 }, .policy_digest = approved.digest, .bound_workspace = id, .bound_task = task.task_id, .capability_handle = @enumFromInt(1) };
        try self.registry.bindSession(self.session, task, self.registry.bootNonce());
        try self.registry.setManagedWrite(id, true);
        self.lease = try self.registry.acquireWriter(task, id);
        const snapshot = try self.registry.snapshot(id);
        self.authorizer = try policy.Authorizer.init(a, io, snapshot.root, id, task.task_id, approved, snapshot.git);
        self.journal = .{ .session = self.session };
        self.budget = memory.Budget.init(1, .{ .bytes = 64 * MiB, .fds = 16, .cpu = 1, .output_bytes = 2 * MiB }, &self.budget_counters);
        self.reservation = try self.budget.reserve(self.session, .{ .scratch_bytes = 20 * MiB, .fds = 8 });
        self.reserved = memory.ReservedAllocator.init(A, &self.reservation, &self.allocation_counters, null);
        self.editor = edit.Editor.init(.{ .allocator = self.reserved.allocator(), .reservation = &self.reservation, .registry = &self.registry, .authorizer = &self.authorizer, .session = self.session, .journal = self.journal.interface(), .cancel = .{ .requested = &self.cancel } });
        return self;
    }
    fn deinit(self: *Fixture) void {
        t.expectEqual(@as(u64, 0), self.reserved.liveBytes()) catch unreachable;
        self.budget.release(&self.reservation) catch unreachable;
        self.registry.deinit() catch unreachable;
        self.root.dir.close(io);
        self.tmp.cleanup();
        self.arena.deinit();
        A.destroy(self);
    }
    fn capability(self: *Fixture, operation: core.Operation, path: []const u8) !core.Capability {
        return self.authorizer.authorize(io, self.session, operation, .{ .bytes = path });
    }
    fn patch(self: *Fixture, spec: core.PatchSpec) !core.Receipt {
        return self.editor.applyPatch(io, try self.capability(.patch, spec.path.bytes), &self.lease, spec);
    }
    fn create(self: *Fixture, path: []const u8, content: []const u8, key: []const u8) !core.Receipt {
        return self.editor.createFile(io, try self.capability(.create, path), &self.lease, .{ .path = .{ .bytes = path }, .content = content, .idempotency_key = key });
    }
    fn expectBytes(self: *Fixture, path: []const u8, expected: []const u8) !void {
        try t.expectEqualStrings(expected, try self.root.dir.readFileAlloc(io, path, self.arena.allocator(), .limited(9 * MiB)));
    }
};

test "WR-001 exact digest and original nonoverlap spans preserve unchanged bytes" {
    const old = "alpha\r\nbravo\ncharlie\n";
    const f = try Fixture.init(old);
    defer f.deinit();
    const receipt = try f.patch(.{ .path = .{ .bytes = "file.txt" }, .expected_sha256 = hash(old), .replacements = &.{ .{ .span = .{ .start = 0, .end = 5 }, .text = "ALPHA" }, .{ .span = .{ .start = 13, .end = 20 }, .text = "CHARLIE" } }, .idempotency_key = "patch-1" });
    try f.expectBytes("file.txt", "ALPHA\r\nbravo\nCHARLIE\n");
    try t.expect(receipt.applied);
    try t.expect(!receipt.durable);
    try t.expectEqual(hash(old), receipt.old_hash.?);
    try t.expectEqual(hash("ALPHA\r\nbravo\nCHARLIE\n"), receipt.new_hash.?);
    try t.expectEqual(@as(u64, 2), receipt.generation);
    try t.expectEqual(@as(usize, 1), f.journal.records);
}

test "WR-001 journal receives exact live publication identities and applied transition" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    f.editor.options.journal = f.journal.transitionInterface();
    const old = (try policy.paths.statAt(f.root.dir.handle, "file.txt")).?.identity;
    const receipt = try f.patch(simplePatch("base\n", "publication-metadata"));
    const entry = f.journal.find("publication-metadata").?;
    const publication = entry.publication orelse return error.MissingPublicationIdentity;
    const root_id = (try policy.paths.statHandle(f.root.dir.handle)).identity;
    const published = (try policy.paths.statAt(f.root.dir.handle, "file.txt")).?.identity;
    try t.expect(publication.workspace_id.eql(f.session.bound_workspace));
    try t.expectEqual(root_id.device, publication.root_id.device);
    try t.expectEqual(root_id.inode, publication.parent_id.inode);
    try t.expectEqual(old.inode, publication.old_file_id.?.inode);
    try t.expectEqual(published.inode, publication.temp_id.inode);
    try t.expectEqual(f.lease.fence, publication.fence);
    try t.expectEqual(receipt.id, publication.receipt_id);
    try t.expectEqual(core.Durability.process, publication.durability);
    try t.expect(std.mem.startsWith(u8, publication.temp_name, ".zcr-tmp-"));
    try t.expectEqual(@as(usize, 1), f.journal.applied_transitions);
    try t.expectEqual(@as(usize, 0), f.journal.aborted_transitions);
    try t.expectEqual(receipt.generation, f.journal.last_transition.?.applied.generation);
}

test "WR-004 journal records established precommit abort with truthful cancellation" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    f.editor.options.journal = f.journal.transitionInterface();
    var event: Event = .{ .fixture = f, .at = .before_commit, .action = .cancel };
    var fault: edit.Fault = .{ .context = &event, .on_stage = Event.call };
    f.editor.fault = &fault;
    try t.expectError(error.Cancelled, f.patch(simplePatch("base\n", "journal-abort")));
    try t.expectEqual(@as(usize, 1), f.journal.aborted_transitions);
    const receipt = f.journal.last_transition.?.aborted;
    try t.expect(!receipt.applied and receipt.cancellation_observed);
    try t.expectEqual(core.errors.WireCode.E_CANCELLED, receipt.error_code.?);
    try f.expectBytes("file.txt", "base\n");
    try expectNoTemps(f, ".");
}

test "WR-007 applied journal transition failure returns applied recovery receipt and quarantine" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    f.editor.options.journal = f.journal.transitionInterface();
    f.journal.fail_transition = true;
    const receipt = try f.patch(simplePatch("base\n", "transition-failure"));
    try t.expect(receipt.applied and !receipt.durable);
    try t.expectEqual(@as(?core.errors.WireCode, .E_RECOVERY_REQUIRED), receipt.error_code);
    try t.expectEqual(@as(usize, 0), f.journal.records);
    try t.expectError(error.LeaseExpired, f.registry.acquireWriter(f.task, f.session.bound_workspace));
    try f.expectBytes("file.txt", "Xase\n");
}
test "WR-009 create existing path preserves original" {
    const f = try Fixture.init("original\n");
    defer f.deinit();
    try t.expectError(error.VersionConflict, f.create("file.txt", "replacement\n", "create-existing"));
    try f.expectBytes("file.txt", "original\n");
}
test "WR-010 new create publishes only complete bytes" {
    const f = try Fixture.init("original\n");
    defer f.deinit();
    const receipt = try f.create("new.txt", "whole new content\n", "create-new");
    try t.expect(receipt.applied);
    try t.expect(receipt.old_hash == null);
    try f.expectBytes("new.txt", "whole new content\n");
}

fn simplePatch(old: []const u8, key: []const u8) core.PatchSpec {
    return .{ .path = .{ .bytes = "file.txt" }, .expected_sha256 = hash(old), .replacements = &.{.{ .span = .{ .start = 0, .end = 1 }, .text = "X" }}, .idempotency_key = key };
}

test "WR-002 stale expected digest leaves mediated writers bytes unchanged" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    _ = try f.patch(simplePatch("base\n", "first"));
    try t.expectError(error.VersionConflict, f.patch(simplePatch("base\n", "stale")));
    try f.expectBytes("file.txt", "Xase\n");
}

test "WR-003 overlap overflow order and UTF-8 split fail before mutation" {
    const original = "AéZ\n";
    const f = try Fixture.init(original);
    defer f.deinit();
    const invalid = [_][]const core.Replacement{
        &.{.{ .span = .{ .start = 2, .end = 3 }, .text = "x" }},
        &.{.{ .span = .{ .start = 4, .end = 2 }, .text = "x" }},
        &.{.{ .span = .{ .start = 0, .end = std.math.maxInt(u64) }, .text = "x" }},
        &.{ .{ .span = .{ .start = 0, .end = 3 }, .text = "x" }, .{ .span = .{ .start = 1, .end = 3 }, .text = "y" } },
        &.{ .{ .span = .{ .start = 3, .end = 4 }, .text = "x" }, .{ .span = .{ .start = 0, .end = 1 }, .text = "y" } },
        &.{.{ .span = .{ .start = 0, .end = 1 }, .text = "\xff" }},
        &.{.{ .span = .{ .start = 0, .end = 1 }, .text = "\x00" }},
        &.{},
    };
    for (invalid) |replacements| {
        var spec = simplePatch(original, "invalid");
        spec.replacements = replacements;
        try t.expectError(error.InvalidArgument, f.patch(spec));
        try f.expectBytes("file.txt", original);
    }
    try t.expectEqual(@as(usize, 0), f.journal.prepares);
}

test "WR-003 duplicate insertion positions are refused before prepare or mutation" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var spec = simplePatch("base\n", "duplicate-insertion");
    spec.replacements = &.{
        .{ .span = .{ .start = 1, .end = 1 }, .text = "first" },
        .{ .span = .{ .start = 1, .end = 1 }, .text = "second" },
    };
    try t.expectError(error.InvalidArgument, f.patch(spec));
    try f.expectBytes("file.txt", "base\n");
    try t.expectEqual(@as(usize, 0), f.journal.prepares);
}

const Event = struct {
    fixture: *Fixture,
    at: edit.Stage,
    action: enum { cancel, revoke, move_parent, replace_temp, mediated_patch },
    fired: bool = false,
    fn call(context: ?*anyopaque, stage: edit.Stage) void {
        const self: *Event = @ptrCast(@alignCast(context.?));
        if (stage != self.at or self.fired) return;
        self.fired = true;
        switch (self.action) {
            .cancel => self.fixture.cancel.store(true, .release),
            .revoke => self.fixture.registry.revokeWriter(self.fixture.session.bound_workspace) catch unreachable,
            .move_parent => {
                self.fixture.root.dir.rename("dir", self.fixture.root.dir, "moved", io) catch unreachable;
                self.fixture.root.dir.createDir(io, "dir", .default_dir) catch unreachable;
            },
            .replace_temp => {
                var dir = self.fixture.root.dir.openDir(io, ".", .{ .iterate = true }) catch unreachable;
                defer dir.close(io);
                var iterator = dir.iterate();
                while (iterator.next(io) catch unreachable) |entry| {
                    if (!std.mem.startsWith(u8, entry.name, ".zcr-tmp-")) continue;
                    const name = self.fixture.arena.allocator().dupe(u8, entry.name) catch unreachable;
                    dir.rename(name, dir, "retained-real-temp", io) catch unreachable;
                    dir.writeFile(io, .{ .sub_path = name, .data = "unrelated replacement\n" }) catch unreachable;
                    self.fixture.cancel.store(true, .release);
                    return;
                }
                unreachable;
            },
            .mediated_patch => {
                var spec = simplePatch("base\n", "competing-mediated-write");
                spec.replacements = &.{.{ .span = .{ .start = 0, .end = 1 }, .text = "Y" }};
                const receipt = self.fixture.patch(spec) catch unreachable;
                t.expect(receipt.applied) catch unreachable;
            },
        }
    }
};

test "WR-002 mediated change after original read is a final version conflict" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    f.editor.options.journal = f.journal.transitionInterface();
    var event: Event = .{ .fixture = f, .at = .after_read, .action = .mediated_patch };
    var fault: edit.Fault = .{ .context = &event, .on_stage = Event.call };
    f.editor.fault = &fault;
    try t.expectError(error.VersionConflict, f.patch(simplePatch("base\n", "paused-original")));
    try f.expectBytes("file.txt", "Yase\n");
    try t.expectEqual(@as(usize, 1), f.journal.applied_transitions);
    try t.expectEqual(@as(usize, 1), f.journal.aborted_transitions);
    try expectNoTemps(f, ".");
}

test "WR-007 ambiguous temp cleanup quarantines before and after guard admission" {
    for ([_]edit.Stage{ .after_temp, .guarded }) |at| {
        const f = try Fixture.init("base\n");
        defer f.deinit();
        f.editor.options.journal = f.journal.transitionInterface();
        var event: Event = .{ .fixture = f, .at = at, .action = .replace_temp };
        var fault: edit.Fault = .{ .context = &event, .on_stage = Event.call };
        f.editor.fault = &fault;
        try t.expectError(error.RecoveryRequired, f.patch(simplePatch("base\n", "uncertain-cleanup")));
        try t.expect(event.fired);
        try f.expectBytes("file.txt", "base\n");
        try t.expectEqual(@as(usize, 0), f.journal.aborted_transitions);
        try t.expectError(error.LeaseExpired, f.registry.acquireWriter(f.task, f.session.bound_workspace));
    }
}

test "WR-004 precommit cancellation preserves original and drains callback" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var event: Event = .{ .fixture = f, .at = .before_commit, .action = .cancel };
    var fault: edit.Fault = .{ .context = &event, .on_stage = Event.call };
    f.editor.fault = &fault;
    try t.expectError(error.Cancelled, f.patch(simplePatch("base\n", "cancel-before")));
    try t.expect(event.fired);
    try f.expectBytes("file.txt", "base\n");
}

test "WR-004 postcommit cancellation returns applied receipt with observation" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var event: Event = .{ .fixture = f, .at = .after_commit, .action = .cancel };
    var fault: edit.Fault = .{ .context = &event, .on_stage = Event.call };
    f.editor.fault = &fault;
    const receipt = try f.patch(simplePatch("base\n", "cancel-after"));
    try t.expect(event.fired);
    try t.expect(receipt.applied and receipt.cancellation_observed);
    try f.expectBytes("file.txt", "Xase\n");
}

test "WR-007 injected ENOSPC read-only metadata and prepare failures preserve original" {
    for ([_]edit.Failure{ .temp_write, .read_only, .metadata, .prepare, .publish }) |failure| {
        const f = try Fixture.init("base\n");
        defer f.deinit();
        var fault: edit.Fault = .{ .failure = failure };
        f.editor.fault = &fault;
        try t.expectError(error.IoFailure, f.patch(simplePatch("base\n", "io-fail")));
        try f.expectBytes("file.txt", "base\n");
    }
}

test "WR-007 postcommit sync failure is applied with durability error" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var fault: edit.Fault = .{ .failure = .sync };
    f.editor.fault = &fault;
    var spec = simplePatch("base\n", "sync-fail");
    spec.durability = .durable;
    const receipt = try f.patch(spec);
    try t.expect(receipt.applied and !receipt.durable);
    try t.expectEqual(core.errors.WireCode.E_DURABILITY, receipt.error_code.?);
    try f.expectBytes("file.txt", "Xase\n");
}

test "WR-004 revoked callback cannot pass final publication fence" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var event: Event = .{ .fixture = f, .at = .before_commit, .action = .revoke };
    var fault: edit.Fault = .{ .context = &event, .on_stage = Event.call };
    f.editor.fault = &fault;
    try t.expectError(error.FenceMismatch, f.patch(simplePatch("base\n", "revoked")));
    try t.expect(event.fired);
    try f.expectBytes("file.txt", "base\n");
}

test "IS-007 moved parent is refused after temp preparation" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    try f.root.dir.createDir(io, "dir", .default_dir);
    try f.root.dir.writeFile(io, .{ .sub_path = "dir/file.txt", .data = "base\n" });
    var event: Event = .{ .fixture = f, .at = .after_temp, .action = .move_parent };
    var fault: edit.Fault = .{ .context = &event, .on_stage = Event.call };
    f.editor.fault = &fault;
    var spec = simplePatch("base\n", "moved");
    spec.path.bytes = "dir/file.txt";
    try t.expectError(error.RecoveryRequired, f.patch(spec));
    try t.expect(event.fired);
    try f.expectBytes("moved/file.txt", "base\n");
}

extern "c" fn mkfifoat(fd: c_int, path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn fsetxattr(fd: c_int, name: [*:0]const u8, value: [*]const u8, size: usize, flags: c_int) c_int;

fn expectNoTemps(f: *Fixture, path: []const u8) !void {
    var dir = try f.root.dir.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| try t.expect(!std.mem.startsWith(u8, entry.name, ".zcr-tmp-"));
}

test "WR-001 primitive preserves ordinary mode and exact source identity" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var parent = try edit.publish.Parent.open(io, f.root.dir, "file.txt");
    defer parent.close(io);
    const handle = try f.root.dir.openFile(io, "file.txt", .{ .mode = .read_write });
    defer handle.close(io);
    try t.expectEqual(@as(c_int, 0), std.c.fchmod(handle.handle, 0o640));
    var original = try parent.openOriginal(io);
    defer original.file.close(io);
    var temp = try parent.createTemp(io);
    defer temp.file.close(io);
    defer temp.cleanupName(&parent) catch unreachable;
    try temp.writeAll(io, "complete\n", .{ .requested = &f.cancel });
    try temp.copyMetadata(&original);
    try t.expectEqual(@as(u32, 0o640), (try edit.publish.Metadata.read(temp.file.handle)).mode);
    try parent.revalidate(io);
    try parent.publishReplace(&temp);
    try f.expectBytes("file.txt", "complete\n");
    try expectNoTemps(f, ".");
}

test "IS-007 primitive rejects hardlink and special file without blocking" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    try t.expectEqual(@as(c_int, 0), std.c.linkat(f.root.dir.handle, "file.txt", f.root.dir.handle, "alias.txt", 0));
    var linked = try edit.publish.Parent.open(io, f.root.dir, "file.txt");
    defer linked.close(io);
    try t.expectError(error.Unsupported, linked.openOriginal(io));
    try t.expectEqual(@as(c_int, 0), mkfifoat(f.root.dir.handle, "fifo", 0o600));
    var fifo = try edit.publish.Parent.open(io, f.root.dir, "fifo");
    defer fifo.close(io);
    try t.expectError(error.NotRegular, fifo.openOriginal(io));
    try f.expectBytes("alias.txt", "base\n");
}

test "WR-007 primitive refuses xattr and ACL metadata it cannot preserve" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    const handle = try f.root.dir.openFile(io, "file.txt", .{ .mode = .read_write });
    defer handle.close(io);
    try t.expectEqual(@as(c_int, 0), fsetxattr(handle.handle, "user.zcr-test", "value", 5, 0));
    var parent = try edit.publish.Parent.open(io, f.root.dir, "file.txt");
    defer parent.close(io);
    try t.expectError(error.Unsupported, parent.openOriginal(io));
    try f.root.dir.writeFile(io, .{ .sub_path = "acl.txt", .data = "acl\n" });
    const acl_file = try f.root.dir.openFile(io, "acl.txt", .{ .mode = .read_write });
    defer acl_file.close(io);
    // Linux POSIX ACL xattr version 2, with one named user and a mask.
    var acl: [44]u8 = undefined;
    std.mem.writeInt(u32, acl[0..4], 2, .little);
    const tags = [_]u16{ 1, 2, 4, 16, 32 };
    const permissions = [_]u16{ 6, 4, 4, 4, 0 };
    for (tags, permissions, 0..) |tag, perm, i| {
        const offset = 4 + i * 8;
        std.mem.writeInt(u16, acl[offset..][0..2], tag, .little);
        std.mem.writeInt(u16, acl[offset + 2 ..][0..2], perm, .little);
        std.mem.writeInt(u32, acl[offset + 4 ..][0..4], if (tag == 2) (try edit.publish.Metadata.read(acl_file.handle)).uid else std.math.maxInt(u32), .little);
    }
    try t.expectEqual(@as(c_int, 0), fsetxattr(acl_file.handle, "system.posix_acl_access", &acl, acl.len, 0));
    var acl_parent = try edit.publish.Parent.open(io, f.root.dir, "acl.txt");
    defer acl_parent.close(io);
    try t.expectError(error.Unsupported, acl_parent.openOriginal(io));
    try f.expectBytes("file.txt", "base\n");
    try f.expectBytes("acl.txt", "acl\n");
}

const PublishRace = struct {
    parent: *edit.publish.Parent,
    temp: *edit.publish.Temp,
    ready: *std.atomic.Value(u32),
    abort: *std.atomic.Value(bool),
    outcome: ?anyerror = null,
    fn run(self: *PublishRace) void {
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (self.ready.load(.acquire) < 2) {
            if (self.abort.load(.acquire)) return;
            std.atomic.spinLoopHint();
        }
        if (self.abort.load(.acquire)) return;
        self.parent.publishCreate(self.temp) catch |err| {
            self.outcome = err;
        };
    }
};

test "WR-010 primitive simultaneous no-replace publish admits exactly one complete file" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var a = try edit.publish.Parent.open(io, f.root.dir, "new.txt");
    defer a.close(io);
    var b = try edit.publish.Parent.open(io, f.root.dir, "new.txt");
    defer b.close(io);
    var ta = try a.createTemp(io);
    defer ta.file.close(io);
    defer ta.cleanupName(&a) catch unreachable;
    var tb = try b.createTemp(io);
    defer tb.file.close(io);
    defer tb.cleanupName(&b) catch unreachable;
    try ta.writeAll(io, "a" ** 8192, .{ .requested = &f.cancel });
    try tb.writeAll(io, "b" ** 8192, .{ .requested = &f.cancel });
    var ready: std.atomic.Value(u32) = .init(0);
    var abort: std.atomic.Value(bool) = .init(false);
    var ra: PublishRace = .{ .parent = &a, .temp = &ta, .ready = &ready, .abort = &abort };
    var rb: PublishRace = .{ .parent = &b, .temp = &tb, .ready = &ready, .abort = &abort };
    const thread_a = try std.Thread.spawn(.{}, PublishRace.run, .{&ra});
    const thread_b = std.Thread.spawn(.{}, PublishRace.run, .{&rb}) catch |err| {
        abort.store(true, .release);
        thread_a.join();
        return err;
    };
    thread_a.join();
    thread_b.join();
    try t.expect((ra.outcome == null) != (rb.outcome == null));
    try t.expectEqual(error.VersionConflict, if (ra.outcome) |err| err else rb.outcome.?);
    try f.expectBytes("new.txt", if (ra.outcome == null) "a" ** 8192 else "b" ** 8192);
}

test "WR-001 idempotency reuses receipt and rejects altered canonical payload" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    const spec = simplePatch("base\n", "stable-key");
    const first = try f.patch(spec);
    const second = try f.patch(spec);
    try t.expectEqual(first.id, second.id);
    try t.expectEqual(first.generation, second.generation);
    try t.expectEqual(@as(usize, 1), f.journal.records);
    var changed = spec;
    changed.replacements = &.{.{ .span = .{ .start = 0, .end = 1 }, .text = "Y" }};
    try t.expectError(error.InvalidArgument, f.patch(changed));
    try f.expectBytes("file.txt", "Xase\n");
    var foreign: core.JournalKey = .{ .security_domain = f.session.security_domain, .workspace_incarnation = f.session.bound_workspace.incarnation, .task_id = f.session.bound_task, .idempotency_key = "stable-key" };
    foreign.security_domain.id += 1;
    try t.expectError(error.InvalidArgument, f.journal.interface().lookup(foreign));
    foreign.security_domain = f.session.security_domain;
    foreign.task_id.uuid[0] ^= 1;
    try t.expectError(error.InvalidArgument, f.journal.interface().lookup(foreign));
}

test "WR-003 full 8 MiB boundary and decoded output growth stay bounded" {
    const f = try Fixture.init("b");
    defer f.deinit();
    const text = try f.arena.allocator().alloc(u8, 8 * MiB + 1);
    @memset(text, 'a');
    try t.expectError(error.InvalidArgument, f.create("too-large.txt", text, "oversize"));
    _ = try f.create("limit.txt", text[0 .. 8 * MiB], "exact-limit");
    const result = try f.root.dir.openFile(io, "limit.txt", .{});
    defer result.close(io);
    try t.expectEqual(@as(u64, 8 * MiB), (try result.stat(io)).size);
    var spec = simplePatch("b", "growth");
    spec.replacements = &.{.{ .span = .{ .start = 0, .end = 0 }, .text = text[0 .. 8 * MiB] }};
    try t.expectError(error.InvalidArgument, f.patch(spec));
    try f.expectBytes("file.txt", "b");
}

test "WR-003 invalid keys binary text and unsupported durability are refused" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    for ([_][]const u8{ "", "x" ** 129, "bad\nkey", "é" }) |key| try t.expectError(error.InvalidArgument, f.create("new.txt", "text\n", key));
    try t.expectError(error.InvalidArgument, f.create("new.txt", "\xff", "binary"));
    var spec = simplePatch("base\n", "unsupported");
    spec.durability = .strongest_available;
    try t.expectError(error.Unsupported, f.patch(spec));
    try t.expectEqual(@as(usize, 0), f.journal.prepares);
}

test "WR-004 precommit deadline and missing reservation leave original unchanged" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    f.editor.options.cancel = f.editor.options.cancel.withTimeout(io, 0);
    try t.expectError(error.DeadlineExceeded, f.patch(simplePatch("base\n", "deadline")));
    f.editor.options.cancel = .{ .requested = &f.cancel };
    const saved = f.reservation.fd;
    f.reservation.fd = 0;
    try t.expectError(error.ResourceExhausted, f.patch(simplePatch("base\n", "no-fd")));
    f.reservation.fd = saved;
    const bytes = f.reservation.bytes;
    f.reservation.bytes = 1;
    try t.expectError(error.ResourceExhausted, f.patch(simplePatch("base\n", "no-memory")));
    f.reservation.bytes = bytes;
    try f.expectBytes("file.txt", "base\n");
}

test "WR-007 allocation faults free all buffers and never publish partial text" {
    var success = false;
    for (1..5) |index| {
        const f = try Fixture.init("base\n");
        defer f.deinit();
        var allocation: memory.FaultPlan = .{ .fail_at = index };
        f.reserved.fault = &allocation;
        if (f.patch(simplePatch("base\n", "allocation"))) |receipt| {
            try t.expect(receipt.applied);
            success = true;
            try t.expectEqual(@as(u64, 0), allocation.injected.load(.monotonic));
            break;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(@as(u64, 1), allocation.injected.load(.monotonic));
            try f.expectBytes("file.txt", "base\n");
        }
        try expectNoTemps(f, ".");
    }
    try t.expect(success);
}

test "WR-007 receipt failure preserves applied outcome and disables further writes" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var fault: edit.Fault = .{ .failure = .record };
    f.editor.fault = &fault;
    const receipt = try f.patch(simplePatch("base\n", "receipt-failure"));
    try t.expect(receipt.applied and !receipt.durable);
    try t.expectEqual(core.errors.WireCode.E_RECOVERY_REQUIRED, receipt.error_code.?);
    try f.expectBytes("file.txt", "Xase\n");
    f.editor.fault = null;
    try t.expectError(error.LeaseExpired, f.registry.acquireWriter(f.task, f.session.bound_workspace));
    try expectNoTemps(f, ".");
}

const CreateRace = struct {
    editor: *edit.Editor,
    capability: core.Capability,
    lease: *const core.WriterLease,
    spec: core.CreateSpec,
    ready: *std.atomic.Value(u32),
    abort: *std.atomic.Value(bool),
    outcome: core.WriteError!core.Receipt = error.InvariantViolation,
    fn run(self: *CreateRace) void {
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (self.ready.load(.acquire) < 2) {
            if (self.abort.load(.acquire)) return;
            std.atomic.spinLoopHint();
        }
        if (self.abort.load(.acquire)) return;
        self.outcome = self.editor.createFile(io, self.capability, self.lease, self.spec);
    }
};

test "WR-010 concurrent callbacks racing one create yield one truthful applied receipt" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    const session_b = f.session;
    var reservation_b = try f.budget.reserve(session_b, .{ .scratch_bytes = 2 * MiB, .fds = 8 });
    defer f.budget.release(&reservation_b) catch unreachable;
    var counters_b: memory.accounting.Counters = .{};
    var reserved_b = memory.ReservedAllocator.init(A, &reservation_b, &counters_b, null);
    var options_b = f.editor.options;
    options_b.session = session_b;
    options_b.allocator = reserved_b.allocator();
    options_b.reservation = &reservation_b;
    var editor_b = edit.Editor.init(options_b);
    var ready: std.atomic.Value(u32) = .init(0);
    var abort: std.atomic.Value(bool) = .init(false);
    const path: core.RelativePath = .{ .bytes = "new.txt" };
    var a: CreateRace = .{ .editor = &f.editor, .capability = try f.capability(.create, path.bytes), .lease = &f.lease, .spec = .{ .path = path, .content = "a" ** 8192, .idempotency_key = "session-a" }, .ready = &ready, .abort = &abort };
    var b: CreateRace = .{ .editor = &editor_b, .capability = try f.authorizer.authorize(io, session_b, .create, path), .lease = &f.lease, .spec = .{ .path = path, .content = "b" ** 8192, .idempotency_key = "session-b" }, .ready = &ready, .abort = &abort };
    const first = try std.Thread.spawn(.{}, CreateRace.run, .{&a});
    const second = std.Thread.spawn(.{}, CreateRace.run, .{&b}) catch |err| {
        abort.store(true, .release);
        first.join();
        return err;
    };
    first.join();
    second.join();
    var wins: usize = 0;
    for ([_]*CreateRace{ &a, &b }) |candidate| {
        if (candidate.outcome) |receipt| {
            try t.expect(receipt.applied);
            wins += 1;
            try f.expectBytes("new.txt", candidate.spec.content);
        } else |err| try t.expectEqual(error.VersionConflict, err);
    }
    try t.expectEqual(@as(usize, 1), wins);
    try t.expectEqual(@as(u64, 0), reserved_b.liveBytes());
    try expectNoTemps(f, ".");
}

test "WR-010 distinct bound sessions cannot bypass the exclusive task writer lease" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var session_b = f.session;
    session_b.session_id.uuid[0] ^= 1;
    session_b.bound_task.uuid[0] ^= 1;
    var task_b = f.task;
    task_b.task_id = session_b.bound_task;
    try f.registry.bindSession(session_b, task_b, f.registry.bootNonce());
    try t.expectError(error.Busy, f.registry.acquireWriter(task_b, session_b.bound_workspace));
    const receipt = try f.create("new.txt", "session a complete bytes\n", "session-a-only");
    try t.expect(receipt.applied);
    try t.expectError(error.Busy, f.registry.acquireWriter(task_b, session_b.bound_workspace));
    try f.expectBytes("new.txt", "session a complete bytes\n");
    try f.expectBytes("file.txt", "base\n");
}

fn noSpaceWrite(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = data;
    _ = splat;
    _ = offset;
    return error.NoSpaceLeft;
}

test "WR-007 primitive real Io write boundary propagates ENOSPC and temp cleanup" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var parent = try edit.publish.Parent.open(io, f.root.dir, "file.txt");
    defer parent.close(io);
    var temp = try parent.createTemp(io);
    defer temp.file.close(io);
    var vtable = io.vtable.*;
    vtable.fileWritePositional = noSpaceWrite;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try t.expectError(error.IoFailure, temp.writeAll(failing_io, "new bytes\n", .{ .requested = &f.cancel }));
    try temp.cleanupName(&parent);
    try f.expectBytes("file.txt", "base\n");
    try expectNoTemps(f, ".");
}

const GuardedRevoke = struct {
    fixture: *Fixture,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    blocked: bool = false,
    registry_mutex_free: bool = false,
    fn revoke(self: *GuardedRevoke) void {
        self.fixture.registry.revokeWriter(self.fixture.session.bound_workspace) catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
    fn stage(context: ?*anyopaque, event: edit.Stage) void {
        const self: *GuardedRevoke = @ptrCast(@alignCast(context.?));
        if (event != .guarded) return;
        self.registry_mutex_free = self.fixture.registry.mutex.tryLock();
        if (self.registry_mutex_free) self.fixture.registry.mutex.unlock(io);
        self.thread = std.Thread.spawn(.{}, revoke, .{self}) catch unreachable;
        while (true) {
            self.fixture.registry.mutex.lockUncancelable(io);
            self.blocked = self.fixture.registry.entries[0].?.publication_waiters != 0;
            self.fixture.registry.mutex.unlock(io);
            if (self.blocked or self.done.load(.acquire)) break;
            std.atomic.spinLoopHint();
        }
    }
};

test "WR-004 actual publication linearizes before concurrent lease revocation returns" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var raced: GuardedRevoke = .{ .fixture = f };
    var fault: edit.Fault = .{ .context = &raced, .on_stage = GuardedRevoke.stage };
    f.editor.fault = &fault;
    const outcome = f.patch(simplePatch("base\n", "guarded-publication"));
    if (raced.thread) |thread| thread.join();
    const receipt = try outcome;
    try t.expect(raced.registry_mutex_free and raced.blocked and raced.done.load(.acquire));
    try t.expect(raced.failure == null and receipt.applied);
    try f.expectBytes("file.txt", "Xase\n");
    f.editor.fault = null;
    try t.expectError(error.FenceMismatch, f.patch(simplePatch("Xase\n", "stale-after-revoke")));
    try f.expectBytes("file.txt", "Xase\n");
}

test "WR-007 syscall error after successful rename reconciles to applied receipt" {
    for ([_]bool{ false, true }) |create| {
        const f = try Fixture.init("base\n");
        defer f.deinit();
        f.editor.options.journal = f.journal.transitionInterface();
        var fault: edit.Fault = .{ .failure = .publish_error_after_success };
        f.editor.fault = &fault;
        const receipt = if (create) try f.create("new.txt", "complete\n", "uncertain-syscall") else try f.patch(simplePatch("base\n", "uncertain-syscall"));
        try t.expect(receipt.applied and receipt.error_code == null);
        try t.expectEqual(@as(usize, 1), f.journal.applied_transitions);
        try t.expectEqual(@as(usize, 1), f.journal.records);
        try f.expectBytes(if (create) "new.txt" else "file.txt", if (create) "complete\n" else "Xase\n");
        try expectNoTemps(f, ".");
    }
}

fn zeroRandom(_: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
    @memset(buffer, 0);
}

test "WR-007 primitive exclusive temp collision exhausts bounded retries without overwrite" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    const name = ".zcr-tmp-" ++ "0" ** 32;
    try f.root.dir.writeFile(io, .{ .sub_path = name, .data = "unrelated existing temp\n" });
    var parent = try edit.publish.Parent.open(io, f.root.dir, "file.txt");
    defer parent.close(io);
    var vtable = io.vtable.*;
    vtable.randomSecure = zeroRandom;
    const colliding: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try t.expectError(error.Busy, parent.createTemp(colliding));
    try f.expectBytes(name, "unrelated existing temp\n");
    try f.expectBytes("file.txt", "base\n");
}

test "WR-010 abandoned second launch aborts and drains the first publisher" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    var parent = try edit.publish.Parent.open(io, f.root.dir, "new.txt");
    defer parent.close(io);
    var temp = try parent.createTemp(io);
    defer temp.file.close(io);
    defer temp.cleanupName(&parent) catch unreachable;
    try temp.writeAll(io, "prepared\n", .{ .requested = &f.cancel });
    var ready: std.atomic.Value(u32) = .init(0);
    var abort: std.atomic.Value(bool) = .init(false);
    var raced: PublishRace = .{ .parent = &parent, .temp = &temp, .ready = &ready, .abort = &abort };
    const first = try std.Thread.spawn(.{}, PublishRace.run, .{&raced});
    while (ready.load(.acquire) == 0) std.atomic.spinLoopHint();
    abort.store(true, .release);
    first.join();
    try t.expect(!temp.published);
    try t.expect((try policy.paths.statAt(f.root.dir.handle, "new.txt")) == null);
}

const QueuedPublisher = struct {
    fixture: *Fixture,
    ticket: workspace.CallbackTicket,
    parent: *edit.publish.Parent,
    temp: *edit.publish.Temp,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    blocked: bool = false,
    fn run(self: *QueuedPublisher) void {
        defer self.done.store(true, .release);
        const guard = self.fixture.registry.acquireCommit(self.ticket) catch |err| {
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
    fn stage(context: ?*anyopaque, event: edit.Stage) void {
        const self: *QueuedPublisher = @ptrCast(@alignCast(context.?));
        if (event != .before_record) return;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch unreachable;
        while (true) {
            self.fixture.registry.mutex.lockUncancelable(io);
            self.blocked = self.fixture.registry.entries[0].?.publication_waiters != 0;
            self.fixture.registry.mutex.unlock(io);
            if (self.blocked or self.done.load(.acquire)) break;
            std.atomic.spinLoopHint();
        }
    }
};

fn queuedFailureCase(failure: edit.Failure, expected: core.errors.WireCode) !void {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    const ticket = try f.registry.beginCallback(f.lease);
    defer f.registry.endCallback(ticket) catch unreachable;
    var parent = try edit.publish.Parent.open(io, f.root.dir, "queued.txt");
    defer parent.close(io);
    var temp = try parent.createTemp(io);
    defer temp.file.close(io);
    defer temp.cleanupName(&parent) catch unreachable;
    try temp.writeAll(io, "must never publish\n", .{ .requested = &f.cancel });
    var queued: QueuedPublisher = .{ .fixture = f, .ticket = ticket, .parent = &parent, .temp = &temp };
    var fault: edit.Fault = .{ .context = &queued, .on_stage = QueuedPublisher.stage, .failure = failure };
    f.editor.fault = &fault;
    var spec = simplePatch("base\n", "fail-with-waiter");
    if (failure == .sync) spec.durability = .durable;
    const outcome = f.patch(spec);
    if (queued.thread) |thread| thread.join();
    const receipt = try outcome;
    try t.expect(receipt.applied and receipt.error_code == expected);
    try t.expect(queued.blocked and queued.done.load(.acquire));
    try t.expect(!temp.published);
    try t.expectEqual(@as(?anyerror, error.FenceMismatch), queued.failure);
    try t.expect((try policy.paths.statAt(f.root.dir.handle, "queued.txt")) == null);
    try f.expectBytes("file.txt", "Xase\n");
}

test "WR-007 failed receipt atomically blocks an already queued filesystem publisher" {
    try queuedFailureCase(.record, .E_RECOVERY_REQUIRED);
}

test "WR-007 unresolved durability blocks an already queued filesystem publisher" {
    try queuedFailureCase(.sync, .E_DURABILITY);
}

test "WR-007 ambiguous lookup errors quarantine instead of accepting new mutation" {
    for ([_]core.JournalError{ error.IoFailure, error.DurabilityFailed, error.NotFound, error.NotRegular, error.RecoveryRequired, error.InvariantViolation }) |err| {
        const f = try Fixture.init("base\n");
        defer f.deinit();
        f.journal.lookup_error = err;
        try t.expectError(error.RecoveryRequired, f.patch(simplePatch("base\n", "lookup-error")));
        try t.expectError(error.LeaseExpired, f.registry.validateLease(f.lease));
        try t.expectEqual(@as(usize, 0), f.journal.prepares);
        try f.expectBytes("file.txt", "base\n");
        try expectNoTemps(f, ".");
    }
}

test "WR-007 ambiguous prepare errors preserve exact pending temp and quarantine" {
    for ([_]core.JournalError{ error.IoFailure, error.DurabilityFailed, error.NotFound, error.NotRegular, error.RecoveryRequired, error.InvariantViolation }) |err| {
        const f = try Fixture.init("base\n");
        defer f.deinit();
        f.editor.options.journal = f.journal.transitionInterface();
        f.journal.prepare_error = err;
        try t.expectError(error.RecoveryRequired, f.patch(simplePatch("base\n", "prepare-error")));
        try t.expectError(error.LeaseExpired, f.registry.validateLease(f.lease));
        const publication = f.journal.find("prepare-error").?.publication.?;
        try f.expectBytes(publication.temp_name, "Xase\n");
        try t.expectEqual(@as(usize, 0), f.journal.aborted_transitions);
        try f.expectBytes("file.txt", "base\n");
    }
}

test "WR-007 impossible journal result shapes preserve uncertainty and quarantine" {
    for ([_]bool{ false, true }) |prepare| {
        const f = try Fixture.init("base\n");
        defer f.deinit();
        f.journal.impossible_prepare = prepare;
        f.journal.impossible_lookup = !prepare;
        try t.expectError(error.RecoveryRequired, f.patch(simplePatch("base\n", "impossible-shape")));
        try t.expectError(error.LeaseExpired, f.registry.validateLease(f.lease));
        if (prepare) {
            const publication = f.journal.find("impossible-shape").?.publication.?;
            try f.expectBytes(publication.temp_name, "Xase\n");
        } else try expectNoTemps(f, ".");
        try f.expectBytes("file.txt", "base\n");
    }
}

test "WR-007 failed abort persistence keeps pending state and quarantines" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    f.editor.options.journal = f.journal.transitionInterface();
    f.journal.fail_transition = true;
    var event: Event = .{ .fixture = f, .at = .before_commit, .action = .cancel };
    var fault: edit.Fault = .{ .context = &event, .on_stage = Event.call };
    f.editor.fault = &fault;
    try t.expectError(error.RecoveryRequired, f.patch(simplePatch("base\n", "abort-failure")));
    try t.expectEqual(@as(usize, 1), f.journal.prepares);
    try t.expectEqual(@as(usize, 0), f.journal.aborted_transitions);
    try t.expectEqual(@as(usize, 0), f.journal.records);
    try t.expectError(error.LeaseExpired, f.registry.validateLease(f.lease));
    try f.expectBytes("file.txt", "base\n");
    try expectNoTemps(f, ".");
}

const StageTrace = struct {
    stages: [32]edit.Stage = undefined,
    len: usize = 0,
    fn call(context: ?*anyopaque, stage: edit.Stage) void {
        const self: *StageTrace = @ptrCast(@alignCast(context.?));
        self.stages[self.len] = stage;
        self.len += 1;
    }
};

test "WR-001 durable create exposes actual chunk metadata sync and receipt crash boundaries" {
    const f = try Fixture.init("base\n");
    defer f.deinit();
    f.editor.options.journal = f.journal.transitionInterface();
    var trace: StageTrace = .{};
    var fault: edit.Fault = .{ .context = &trace, .on_stage = StageTrace.call };
    f.editor.fault = &fault;
    const text = try f.arena.allocator().alloc(u8, 2 * core.limits.values.chunk_bytes + 1);
    @memset(text, 'c');
    const receipt = try f.editor.createFile(io, try f.capability(.create, "durable.txt"), &f.lease, .{ .path = .{ .bytes = "durable.txt" }, .content = text, .idempotency_key = "durable-create", .durability = .durable });
    try t.expect(receipt.applied and receipt.durable and receipt.error_code == null);
    try f.expectBytes("durable.txt", text);
    const publication = f.journal.find("durable-create").?.publication.?;
    try t.expect(publication.old_file_id == null and publication.durability == .durable);
    try t.expectEqualSlices(edit.Stage, &.{ .after_read, .after_temp_chunk, .after_temp_chunk, .after_temp_chunk, .before_metadata, .after_temp, .after_prepare, .before_commit, .guarded, .after_commit, .before_sync, .after_sync, .before_record, .after_record }, trace.stages[0..trace.len]);
}
