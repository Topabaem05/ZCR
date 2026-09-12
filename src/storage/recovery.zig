//! Recovery only reconciles; it never publishes or re-runs an edit. A host must
//! retain identity witnesses across the writer death and attest their mapping
//! to this fresh boot. Matching paths/hashes on a cold start are insufficient.
const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const workspace = @import("zcr_workspace");
const journal = @import("journal.zig");
const receipts = @import("receipts.zig");
const Io = std.Io;
const A = std.mem.Allocator;
const E = core.RecoverError;
pub const GrantData = struct {
    store_id: core.Uuid,
    store_root_id: core.FileId,
    original_workspace: core.WorkspaceId,
    current_workspace: core.WorkspaceId,
    current_boot: core.Uuid,
    namespace_digest: core.Sha256,
    security_domain: core.SecurityDomain,
    policy_digest: core.PolicyDigest,
    approved_tasks: []const core.TaskId,
    exclusive_recovery: bool,
    /// Full PREPARED digests attested over the protected host channel, while
    /// parent/temp/original descriptors remain retained by that host.
    publication_digests: []const core.Sha256,
};
pub const ContinuityGrant = struct {
    data: GrantData,
    /// Required host-owned attestation. A checksum loaded from disk is not a
    /// witness. The callback checks retained root/Git/common descriptors or a
    /// protected, one-use supervisor message bound to data/current boot.
    context: ?*anyopaque,
    validate: *const fn (?*anyopaque, GrantData, journal.Namespace) core.RecoverError!void,
    /// Required for each operation. Root/Git witnesses alone do not prevent
    /// inode reuse after unlinking an old target or temporary file.
    validate_publication: ?*const fn (?*anyopaque, GrantData, core.PreparedRecord) core.RecoverError!void = null,
};
pub const Recoverer = struct {
    root: core.TrustedRoot,
    registry: *workspace.Registry,
    store: *journal.Store,
    grant: ?ContinuityGrant,
    approved_policy: core.Policy,
    git_executable: []const u8 = "/usr/bin/git",
    pub fn init(root: core.TrustedRoot, registry: *workspace.Registry, store: *journal.Store, grant: ?ContinuityGrant, approved_policy: core.Policy) Recoverer {
        return .{ .root = root, .registry = registry, .store = store, .grant = grant, .approved_policy = approved_policy };
    }
    /// allocator belongs to the caller's recovery/output reservation. It must
    /// outlive the returned Owned report. budgetCost bounds the report + scan.
    pub fn recover(self: *Recoverer, io: Io, allocator: A, current: core.WorkspaceId, interface: core.JournalStore) E!core.Owned(core.RecoveryReport) {
        errdefer self.registry.failRecovery(current);
        if (interface.vtable != &journal.Adapter.vtable) return error.RecoveryRequired;
        const adapter: *journal.Adapter = @ptrCast(@alignCast(interface.context));
        if (adapter.store != self.store) return error.RecoveryRequired;
        const grant = self.grant orelse return error.RecoveryRequired;
        const data = grant.data;
        const ns = self.store.options.namespace;
        if (!data.current_workspace.eql(current) or current.eql(ns.workspace_id) or !data.original_workspace.eql(ns.workspace_id) or !std.meta.eql(data.current_boot, self.registry.bootNonce()) or !std.meta.eql(data.store_id, ns.store_id) or !std.meta.eql(data.store_root_id, self.store.root_id) or !std.meta.eql(data.namespace_digest, self.store.namespace_digest) or data.security_domain.id != ns.security_domain.id or !std.meta.eql(data.policy_digest, ns.policy_digest) or !std.meta.eql(self.approved_policy.digest, ns.policy_digest) or !data.exclusive_recovery or data.approved_tasks.len == 0 or data.approved_tasks.len > journal.max_entries or !approved(data, adapter.key.task_id)) return error.RecoveryRequired;
        try grant.validate(grant.context, data, ns);
        self.registry.validateWorkspace(current) catch return error.RecoveryRequired;
        const snapshot = self.registry.snapshot(current) catch return error.RecoveryRequired;
        if (!std.meta.eql(snapshot.root_id, ns.root_id) or !std.meta.eql(snapshot.git_dir_id, ns.git_dir_id) or !std.meta.eql(snapshot.repo_id.common_dir, ns.common_dir_id) or !std.mem.eql(u8, snapshot.head[0..snapshot.head_len], ns.head)) return error.RecoveryRequired;
        var discovered = workspace.identity.discover(allocator, io, self.git_executable, self.root) catch return error.RecoveryRequired;
        defer discovered.deinit(io);
        discovered.validate(io) catch return error.RecoveryRequired;
        if (!identityMatches(&discovered, ns)) return error.RecoveryRequired;
        self.store.validateRoot() catch return error.RecoveryRequired;
        var report: core.Owned(core.RecoveryReport) = .{ .value = .{ .workspace_id = current, .committed = 0, .aborted = 0, .uncertain = 0, .quarantined_paths = &.{} }, .arena = .init(allocator) };
        errdefer report.deinit();
        var quarantined: std.ArrayList(core.RelativePath) = .empty;
        self.store.mutex.lockUncancelable(io);
        defer self.store.mutex.unlock(io);
        var node = self.store.head;
        while (node) |entry| : (node = entry.next) {
            const p = entry.prepared orelse {
                report.value.uncertain += 1;
                continue;
            };
            // A recovery scan may identify other task records, but that is not
            // authority to reconcile or expose their historical receipts.
            if (!approved(data, p.key.task_id)) return error.RecoveryRequired;
            // Authenticated terminal records describe immutable historical
            // outcomes. A later authorized edit may replace their target;
            // replay therefore does not infer anything from current paths or
            // require publication witnesses for a new filesystem observation.
            if (entry.state == .committed or entry.state == .aborted) {
                if (entry.torn) self.store.preserveTail(entry) catch {
                    // Do not rewrite a proven outcome as UNCERTAIN when its
                    // incomplete suffix cannot be safely preserved. Lookup
                    // remains blocked by torn and the report quarantines it.
                    report.value.uncertain += 1;
                    try quarantined.append(report.arena.allocator(), .{ .bytes = try report.arena.allocator().dupe(u8, p.path.bytes) });
                    continue;
                };
                if (entry.state == .committed) report.value.committed += 1 else report.value.aborted += 1;
                continue;
            }
            const validate_publication = grant.validate_publication orelse {
                try self.uncertain(entry);
                report.value.uncertain += 1;
                try quarantined.append(report.arena.allocator(), .{ .bytes = try report.arena.allocator().dupe(u8, p.path.bytes) });
                continue;
            };
            validate_publication(grant.context, data, p) catch {
                try self.uncertain(entry);
                report.value.uncertain += 1;
                try quarantined.append(report.arena.allocator(), .{ .bytes = try report.arena.allocator().dupe(u8, p.path.bytes) });
                continue;
            };
            var auth = policy.Authorizer.init(report.arena.allocator(), io, snapshot.root, current, p.key.task_id, self.approved_policy, snapshot.git) catch return error.RecoveryRequired;
            const session: core.SessionContext = .{ .session_id = .{ .uuid = @splat(0) }, .security_domain = ns.security_domain, .policy_digest = ns.policy_digest, .bound_workspace = current, .bound_task = p.key.task_id, .capability_handle = .none };
            _ = auth.authorize(io, session, if (p.old_hash == null) .create else .patch, p.path) catch {
                try self.uncertain(entry);
                report.value.uncertain += 1;
                try quarantined.append(report.arena.allocator(), .{ .bytes = try report.arena.allocator().dupe(u8, p.path.bytes) });
                continue;
            };
            self.reconcile(io, current, entry, &auth) catch {
                try self.uncertain(entry);
                report.value.uncertain += 1;
                try quarantined.append(report.arena.allocator(), .{ .bytes = try report.arena.allocator().dupe(u8, p.path.bytes) });
                continue;
            };
            switch (entry.state) {
                .committed => report.value.committed += 1,
                .aborted => report.value.aborted += 1,
                else => {
                    report.value.uncertain += 1;
                    try quarantined.append(report.arena.allocator(), .{ .bytes = try report.arena.allocator().dupe(u8, p.path.bytes) });
                },
            }
        }
        report.value.quarantined_paths = try quarantined.toOwnedSlice(report.arena.allocator());
        if (report.value.uncertain > 0) self.registry.failRecovery(current);
        // Successful reconciliation never re-enables writes; that is a later
        // trusted launch decision after every recovery gate is complete.
        return report;
    }
    fn uncertain(self: *Recoverer, entry: *journal.Entry) E!void {
        if (entry.state == .uncertain) return;
        if (entry.torn) self.store.preserveTail(entry) catch return error.RecoveryRequired;
        self.store.append(entry, .uncertain, entry.receipt, entry.origin, entry.reason, true) catch return error.RecoveryRequired;
    }
    fn reconcile(self: *Recoverer, io: Io, current: core.WorkspaceId, entry: *journal.Entry, auth: *policy.Authorizer) E!void {
        const p = entry.prepared.?;
        const pubid = p.publication.?;
        var parent = try Parent.open(io, self.root, p.path.bytes, pubid.parent_id);
        defer parent.dir.close(io);
        const target = try observe(io, parent.dir, parent.name(), auth);
        const temp = try observe(io, parent.dir, @as([*:0]const u8, @ptrCast(pubid.temp_name.ptr))[0..pubid.temp_name.len :0], auth);
        try parent.revalidate(io);
        const new_target = if (target) |t| std.meta.eql(t.id, pubid.temp_id) and std.meta.eql(t.hash, p.new_hash) else false;
        const old_target = if (p.old_hash) |old| if (target) |t| std.meta.eql(t.id, pubid.old_file_id.?) and std.meta.eql(t.hash, old) else false else target == null;
        const exact_temp = if (temp) |t| std.meta.eql(t.id, pubid.temp_id) and std.meta.eql(t.hash, p.new_hash) else false;
        if (entry.state == .uncertain) return error.RecoveryRequired;
        if (entry.torn) self.store.preserveTail(entry) catch return error.RecoveryRequired;
        if (new_target and temp == null) {
            var receipt = entry.receipt orelse core.Receipt{ .id = pubid.receipt_id, .idempotency_key = p.key.idempotency_key, .op_digest = p.op_digest, .applied = true, .durable = false, .cancellation_observed = false, .old_hash = p.old_hash, .new_hash = p.new_hash, .generation = 0, .error_code = null };
            var origin = entry.origin;
            if (entry.state == .prepared) {
                // Never infer an old live generation from PREPARED+1.
                receipt.generation = self.registry.markChanged(current) catch return error.RecoveryRequired;
                origin = .recovered;
                self.store.append(entry, .applied, receipt, origin, .ordinary, true) catch return error.RecoveryRequired;
            }
            receipt.applied = true;
            receipt.error_code = null;
            if (pubid.durability != .process) {
                const target_file = try openObserved(io, parent.dir, parent.name(), target.?.id);
                defer target_file.close(io);
                journal.sync(target_file.handle) catch return error.DurabilityFailed;
                journal.sync(parent.dir.handle) catch return error.DurabilityFailed;
                receipt.durable = true;
            } else receipt.durable = false;
            try parent.revalidate(io);
            const final = try observe(io, parent.dir, parent.name(), auth) orelse return error.RecoveryRequired;
            if (!std.meta.eql(final, target.?)) return error.RecoveryRequired;
            self.store.append(entry, .committed, receipt, origin, .ordinary, true) catch return error.RecoveryRequired;
        } else if (old_target and exact_temp and entry.state == .prepared) {
            const receipt: core.Receipt = .{ .id = pubid.receipt_id, .idempotency_key = p.key.idempotency_key, .op_digest = p.op_digest, .applied = false, .durable = false, .cancellation_observed = false, .old_hash = p.old_hash, .new_hash = p.new_hash, .generation = p.generation, .error_code = .E_IO };
            self.store.append(entry, .aborted, receipt, .live, .recovered_not_applied, true) catch return error.RecoveryRequired;
            // Cleanup is optional. Retaining authenticated temps avoids adding
            // a delete operation to recovery; unrecorded temps are untouched too.
        } else return error.RecoveryRequired;
    }
    comptime {
        core.conforms(core.RecoverFn(Recoverer), recover);
    }
};
pub fn budgetCost(count: u32) core.ResourceCost {
    return .{ .scratch_bytes = 512 * 1024, .output_bytes = @as(u64, count) * 8192 + 64 * 1024, .fds = 12 };
}
fn approved(data: GrantData, task: core.TaskId) bool {
    for (data.approved_tasks) |allowed| if (std.meta.eql(allowed, task)) return true;
    return false;
}
pub fn identityMatches(id: *const workspace.identity.Identity, ns: journal.Namespace) bool {
    return std.meta.eql(id.root_id, ns.root_id) and std.meta.eql(id.git_dir_id, ns.git_dir_id) and std.meta.eql(id.common_dir_id, ns.common_dir_id) and std.meta.eql(id.marker.id, ns.marker_id) and std.meta.eql(id.marker.hash, ns.marker_hash) and std.mem.eql(u8, id.root.canonical_path, ns.root_path) and std.mem.eql(u8, id.git.git_dir.?, ns.git_path) and std.mem.eql(u8, id.git.common_dir.?, ns.common_path) and std.mem.eql(u8, id.head[0..id.head_len], ns.head);
}
const Observation = struct { id: core.FileId, hash: core.Sha256 };
const Parent = struct {
    root: core.TrustedRoot,
    dir: Io.Dir,
    path: []const u8,
    parent_path: []const u8,
    expected: core.FileId,
    leaf: [4097]u8 = undefined,
    leaf_len: usize,
    fn name(self: *Parent) [:0]const u8 {
        return self.leaf[0..self.leaf_len :0];
    }
    fn open(io: Io, root: core.TrustedRoot, path: []const u8, expected: core.FileId) E!Parent {
        const pp = std.fs.path.dirname(path) orelse ".";
        const chain = policy.paths.resolve(io, root.dir, pp) catch return error.RecoveryRequired;
        if (!chain.exists() or chain.final().?.kind != .directory) return error.RecoveryRequired;
        var dir = root.dir.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false }) catch return error.RecoveryRequired;
        errdefer dir.close(io);
        if (!std.mem.eql(u8, pp, ".")) {
            var parts = std.mem.splitScalar(u8, pp, '/');
            var index: usize = 1;
            while (parts.next()) |part| : (index += 1) {
                const next = dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false }) catch return error.RecoveryRequired;
                const meta = journal.metadata(next.handle, true) catch {
                    next.close(io);
                    return error.RecoveryRequired;
                };
                if (meta.id.device != chain.chain[index].identity.device or meta.id.inode != chain.chain[index].identity.inode) {
                    next.close(io);
                    return error.RecoveryRequired;
                }
                dir.close(io);
                dir = next;
            }
        }
        if (!std.meta.eql((journal.metadata(dir.handle, true) catch return error.RecoveryRequired).id, expected)) return error.RecoveryRequired;
        const leaf = std.fs.path.basename(path);
        var result: Parent = .{ .root = root, .dir = dir, .path = path, .parent_path = pp, .expected = expected, .leaf_len = leaf.len };
        @memcpy(result.leaf[0..leaf.len], leaf);
        result.leaf[leaf.len] = 0;
        return result;
    }
    fn revalidate(self: *Parent, io: Io) E!void {
        const chain = policy.paths.resolve(io, self.root.dir, self.parent_path) catch return error.RecoveryRequired;
        if (!chain.exists() or chain.final().?.identity.device != self.expected.device or chain.final().?.identity.inode != self.expected.inode) return error.RecoveryRequired;
    }
};
fn openObserved(io: Io, dir: Io.Dir, name: [:0]const u8, expected: core.FileId) E!Io.File {
    const fd = std.posix.openatZ(dir.handle, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return error.RecoveryRequired;
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    errdefer file.close(io);
    if (!std.meta.eql((journal.metadata(fd, false) catch return error.RecoveryRequired).id, expected)) return error.RecoveryRequired;
    return file;
}
fn observe(io: Io, dir: Io.Dir, name: [:0]const u8, auth: *policy.Authorizer) E!?Observation {
    const entry = policy.paths.statAt(dir.handle, name) catch return error.RecoveryRequired;
    if (entry == null) return null;
    if (entry.?.kind != .regular) return error.RecoveryRequired;
    const id: core.FileId = .{ .device = entry.?.identity.device, .inode = entry.?.identity.inode };
    for (auth.git_identities) |other| if (other.eql(entry.?.identity)) return error.RecoveryRequired;
    for (auth.immutable_identities) |other| if (other.eql(entry.?.identity)) return error.RecoveryRequired;
    const file = try openObserved(io, dir, name, id);
    defer file.close(io);
    const before = journal.metadata(file.handle, false) catch return error.RecoveryRequired;
    if (before.size > core.limits.values.max_write_file_bytes) return error.RecoveryRequired;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [256 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < before.size) {
        const count: usize = @intCast(@min(buffer.len, before.size - offset));
        journal.readAt(file, io, buffer[0..count], offset) catch return error.RecoveryRequired;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    if (!before.same(journal.metadata(file.handle, false) catch return error.RecoveryRequired)) return error.RecoveryRequired;
    const after = policy.paths.statAt(dir.handle, name) catch return error.RecoveryRequired;
    if (after == null or !after.?.identity.eql(entry.?.identity)) return error.RecoveryRequired;
    var digest: core.Sha256 = undefined;
    hasher.final(&digest);
    return .{ .id = id, .hash = digest };
}

/// A digest binds a protected host attestation to every field of PREPARED. It
/// authenticates nothing by itself and must never be sourced from disk grants.
pub fn publicationDigest(p: core.PreparedRecord) E!core.Sha256 {
    var buffer: [receipts.max_frame_bytes]u8 = undefined;
    const encoded = receipts.encode(core.PreparedRecord, p, &buffer) catch return error.RecoveryRequired;
    return receipts.hash(encoded);
}
