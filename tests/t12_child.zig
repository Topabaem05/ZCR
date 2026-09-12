const std = @import("std");
const f = @import("t12_fixtures.zig");
const core = f.core;
const storage = f.storage;
const Crash = struct {
    fixture: *f.Fixture,
    point: u8,
    kill_recovery: bool,
    fn stop(self: *Crash, point: u8) void {
        if (point != 12 and self.point != point and !(point == 11 and self.kill_recovery)) return;
        const entry = self.fixture.store.head;
        f.send(1, f.Ack, .{ .point = point, .store = self.fixture.store.options.namespace.store_id, .receipt_id = if (entry) |e| if (e.prepared) |p| p.publication.?.receipt_id else null else null, .prepared = if (entry) |e| e.prepared else null, .digest = self.fixture.digest() }) catch @panic("ack failure");
        const response = f.receive(0, bool, f.A) catch @panic("missing SIGKILL");
        response.deinit();
        if (point == 12 and response.value) return;
        @panic("unexpected continuation");
    }
    fn editor(context: ?*anyopaque, stage: f.edit.Stage) void {
        const self: *Crash = @ptrCast(@alignCast(context.?));
        if (stage == .after_prepare) self.stop(12);
        self.stop(switch (stage) {
            .after_temp_chunk => 1,
            .before_metadata => 2,
            .after_prepare => 5,
            .guarded => 6,
            .after_commit => 7,
            .after_sync => 8,
            .after_record => 10,
            else => 0,
        });
    }
    fn journal(context: ?*anyopaque, stage: storage.Stage) void {
        const self: *Crash = @ptrCast(@alignCast(context.?));
        self.stop(switch (stage) {
            .before_prepared => 3,
            .partial_prepared => 4,
            .partial_committed => 9,
            .partial_recovery => 11,
            else => 0,
        });
    }
};
const Witness = struct {
    expected: storage.recovery.GrantData,
    consumed: bool = false,
    fn publication(context: ?*anyopaque, data: storage.recovery.GrantData, p: core.PreparedRecord) core.RecoverError!void {
        const self: *Witness = @ptrCast(@alignCast(context.?));
        if (!self.consumed or !data.current_workspace.eql(self.expected.current_workspace)) return error.RecoveryRequired;
        const digest = try storage.recovery.publicationDigest(p);
        for (self.expected.publication_digests) |expected| if (std.meta.eql(expected, digest)) return;
        return error.RecoveryRequired;
    }
    fn validate(context: ?*anyopaque, data: storage.recovery.GrantData, ns: storage.Namespace) core.RecoverError!void {
        const self: *Witness = @ptrCast(@alignCast(context.?));
        if (self.consumed or !data.current_workspace.eql(self.expected.current_workspace) or !std.meta.eql(data.current_boot, self.expected.current_boot) or !std.meta.eql(data.store_id, ns.store_id) or !std.meta.eql(data.namespace_digest, ns.digest() catch return error.RecoveryRequired)) return error.RecoveryRequired;
        self.consumed = true;
    }
};
test "T12 protected child role is mandatory" {
    const input = try f.receive(0, f.Manifest, f.A);
    defer input.deinit();
    const m = input.value;
    if (m.point < 1 or m.point > 10) return error.InvalidCrashPoint;
    const fixture = try f.Fixture.init(m.root, m.state, m.create, m.namespace);
    defer fixture.deinit();
    try f.send(1, f.Hello, .{ .store_root_id = fixture.store.root_id, .namespace = fixture.store.options.namespace, .current = fixture.session.bound_workspace, .boot = fixture.registry.bootNonce() });
    var crash: Crash = .{ .fixture = fixture, .point = m.point, .kill_recovery = m.kill_recovery };
    var journal_fault: storage.Fault = .{ .context = &crash, .stage = Crash.journal };
    fixture.store.fault = &journal_fault;
    if (m.role == .writer) {
        const go = try f.receive(0, bool, f.A);
        defer go.deinit();
        try std.testing.expect(go.value);
        var fault: f.edit.Fault = .{ .context = &crash, .on_stage = Crash.editor };
        _ = try fixture.run(&fault);
        return error.ExpectedSIGKILL;
    }
    const grant = try f.receive(0, storage.recovery.GrantData, f.A);
    defer grant.deinit();
    var witness: Witness = .{ .expected = grant.value };
    var recoverer = storage.recovery.Recoverer.init(fixture.root, &fixture.registry, &fixture.store, .{ .data = grant.value, .context = &witness, .validate = Witness.validate, .validate_publication = Witness.publication }, f.approved);
    var report = try recoverer.recover(f.io, fixture.reserved.allocator(), fixture.session.bound_workspace, fixture.adapter.interface());
    defer report.deinit();
    if (m.history) {
        var result: f.HistoryResult = .{ .committed = report.value.committed, .aborted = report.value.aborted, .uncertain = report.value.uncertain, .receipts = undefined, .sequences = undefined };
        var seen: [2]bool = @splat(false);
        var node = fixture.store.head;
        while (node) |entry| : (node = entry.next) {
            const p = entry.prepared orelse return error.MissingHistory;
            const slot: usize = if (std.mem.eql(u8, p.key.idempotency_key, f.key)) 0 else if (std.mem.eql(u8, p.key.idempotency_key, "history-second")) 1 else return error.UnexpectedHistory;
            try std.testing.expect(!seen[slot]);
            seen[slot] = true;
            var adapter = try storage.Adapter.init(&fixture.store, f.task.task_id, p.key.idempotency_key, p.op_digest);
            result.receipts[slot] = (try adapter.interface().lookup(adapter.key)).found;
            result.sequences[slot] = entry.sequence;
            var conflict = try storage.Adapter.init(&fixture.store, f.task.task_id, p.key.idempotency_key, @splat(99));
            try std.testing.expectEqual(p.op_digest, (try conflict.interface().lookup(conflict.key)).conflict);
        }
        try std.testing.expect(seen[0] and seen[1]);
        try f.send(1, f.HistoryResult, result);
        return;
    }
    const entry = try fixture.store.find(fixture.adapter.key);
    const receipt: ?core.Receipt = if (entry) |e| if (e.state == .committed or e.state == .aborted) e.receipt else null else null;
    if (receipt) |r| {
        const replay = try fixture.adapter.interface().lookup(fixture.adapter.key);
        try std.testing.expect(storage.receiptEqual(r, replay.found));
        var conflicting = try storage.Adapter.init(&fixture.store, f.task.task_id, f.key, @splat(99));
        try std.testing.expectEqual(r.op_digest, (try conflicting.interface().lookup(conflicting.key)).conflict);
    } else if (entry != null) try std.testing.expectError(error.RecoveryRequired, fixture.adapter.interface().lookup(fixture.adapter.key));
    try f.send(1, f.Result, .{ .committed = report.value.committed, .aborted = report.value.aborted, .uncertain = report.value.uncertain, .receipt = receipt, .origin = if (entry) |e| e.origin else null, .sequence = if (entry) |e| e.sequence else 0 });
}
