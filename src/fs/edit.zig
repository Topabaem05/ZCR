const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const workspace = @import("zcr_workspace");
pub const publish = @import("publish.zig");
const Io = std.Io;
const max_file = core.limits.values.max_write_file_bytes;

pub const production_writes_enabled = false;
/// Parent/old/temp plus bounded path and workspace revalidation handles.
pub const required_fds: u16 = 8;
pub const Stage = enum { after_read, after_temp_chunk, before_metadata, after_temp, after_prepare, before_commit, guarded, after_commit, before_sync, after_sync, before_record, after_record };
pub const Failure = enum { temp_write, read_only, metadata, prepare, publish, publish_error_after_success, sync, record };
pub const Fault = struct {
    context: ?*anyopaque = null,
    on_stage: ?*const fn (?*anyopaque, Stage) void = null,
    failure: ?Failure = null,
};
pub const Options = struct {
    allocator: std.mem.Allocator,
    reservation: *core.Reservation,
    registry: *workspace.Registry,
    authorizer: *policy.Authorizer,
    session: core.SessionContext,
    /// A JournalStore whose context is bound to this session's domain,
    /// workspace incarnation and task. Receipt-only record cannot infer them.
    journal: core.JournalStore,
    cancel: core.Cancel,
};
pub const Editor = struct {
    options: Options,
    fault: if (@import("builtin").is_test) ?*Fault else void = if (@import("builtin").is_test) null else {},
    const Pending = struct { receipt: ?core.Receipt = null, prepared: bool = false, guard: ?workspace.CommitGuard = null };
    pub fn init(options: Options) Editor {
        return .{ .options = options };
    }
    /// Request-scoped editor: allocator/reservation/cancel, the immutable session,
    /// authorizer and bound journal context must outlive the synchronous call.
    pub fn applyPatch(self: *Editor, io: Io, capability: core.Capability, lease: *const core.WriterLease, spec: core.PatchSpec) core.WriteError!core.Receipt {
        try self.check(io, capability, lease, .patch, spec.path, spec.idempotency_key, spec.durability);
        try validateReplacements(spec.replacements);
        const digest = patchDigest(spec);
        const ticket = try self.options.registry.beginCallback(lease.*);
        defer self.options.registry.endCallback(ticket) catch unreachable;
        if (try self.lookup(spec.idempotency_key, digest)) |receipt| return receipt;
        const generation = (try self.options.registry.snapshot(lease.workspace_id)).generation;
        var parent = try publish.Parent.open(io, self.options.authorizer.root.dir, spec.path.bytes);
        defer parent.close(io);
        try self.checkParentAuthority(&parent);
        var original = try parent.openOriginal(io);
        defer original.file.close(io);
        try self.checkIdentityAuthority(original.metadata.identity);
        if (original.metadata.size > max_file) return error.Unsupported;
        if (original.metadata.size > self.options.reservation.bytes) return error.ResourceExhausted;
        const old = try self.options.allocator.alloc(u8, @intCast(original.metadata.size));
        defer self.options.allocator.free(old);
        try original.readAll(io, old, self.options.cancel);
        if (!std.mem.eql(u8, &hash(old), &spec.expected_sha256)) return error.VersionConflict;
        if (!validText(old)) return error.Unsupported;
        const size = try resultingSize(old, spec.replacements);
        if (old.len + size > self.options.reservation.bytes) return error.ResourceExhausted;
        const new = try self.options.allocator.alloc(u8, size);
        defer self.options.allocator.free(new);
        synthesize(old, spec.replacements, new);
        self.stage(.after_read);
        return self.prepareAndPublish(io, &parent, &original, old, new, spec.expected_sha256, digest, spec.idempotency_key, spec.durability, generation, ticket, lease.fence);
    }
    pub fn createFile(self: *Editor, io: Io, capability: core.Capability, lease: *const core.WriterLease, spec: core.CreateSpec) core.WriteError!core.Receipt {
        try self.check(io, capability, lease, .create, spec.path, spec.idempotency_key, spec.durability);
        if (spec.content.len > max_file or !validText(spec.content)) return error.InvalidArgument;
        if (spec.content.len > self.options.reservation.bytes) return error.ResourceExhausted;
        const digest = createDigest(spec);
        const ticket = try self.options.registry.beginCallback(lease.*);
        defer self.options.registry.endCallback(ticket) catch unreachable;
        if (try self.lookup(spec.idempotency_key, digest)) |receipt| return receipt;
        const generation = (try self.options.registry.snapshot(lease.workspace_id)).generation;
        var parent = try publish.Parent.open(io, self.options.authorizer.root.dir, spec.path.bytes);
        defer parent.close(io);
        try self.checkParentAuthority(&parent);
        if (try policy.paths.statAt(parent.dir.handle, parent.name()) != null) return error.VersionConflict;
        self.stage(.after_read);
        return self.prepareAndPublish(io, &parent, null, &.{}, spec.content, null, digest, spec.idempotency_key, spec.durability, generation, ticket, lease.fence);
    }

    fn check(self: *Editor, io: Io, capability: core.Capability, lease: *const core.WriterLease, operation: core.Operation, path: core.RelativePath, key: []const u8, durability: core.Durability) core.WriteError!void {
        // T12 must replace the fake-store/crash-recovery gate before any runtime
        // caller can enable writes. A runtime option cannot override this gate.
        if (!@import("builtin").is_test and !production_writes_enabled) return error.Unsupported;
        if (!@import("builtin").is_test and self.options.journal.vtable.transition == null) return error.Unsupported;
        if (durability == .strongest_available) return error.Unsupported;
        if (key.len == 0 or key.len > 128) return error.InvalidArgument;
        for (key) |byte| if (byte < 0x20 or byte > 0x7e) return error.InvalidArgument;
        try self.options.cancel.check();
        if (self.options.reservation.released or self.options.reservation.fd < required_fds) return error.ResourceExhausted;
        if (!lease.workspace_id.eql(self.options.session.bound_workspace) or !std.mem.eql(u8, &lease.task_id.uuid, &self.options.session.bound_task.uuid)) return error.FenceMismatch;
        if (capability.handle == .none or capability.operation != operation or !capability.workspace_id.eql(self.options.session.bound_workspace) or !std.mem.eql(u8, &capability.task_id.uuid, &self.options.session.bound_task.uuid) or !std.mem.eql(u8, &capability.policy_digest, &self.options.session.policy_digest) or !std.mem.eql(u8, capability.path.bytes, path.bytes)) return error.OutOfScope;
        try self.options.registry.validateSession(self.options.session, self.options.registry.bootNonce());
        _ = try self.options.authorizer.authorize(io, self.options.session, operation, path);
        try self.options.registry.validateLease(lease.*);
    }
    fn checkIdentityAuthority(self: *Editor, identity: policy.paths.Identity) core.WriteError!void {
        for (self.options.authorizer.git_identities) |protected| if (identity.eql(protected)) return error.OutOfScope;
        for (self.options.authorizer.immutable_identities) |protected| if (identity.eql(protected)) return error.OutOfScope;
    }
    fn checkParentAuthority(self: *Editor, parent: *publish.Parent) core.WriteError!void {
        for (parent.chain.entries()) |entry| try self.checkIdentityAuthority(entry.identity);
    }
    fn journalKey(self: *Editor, idempotency: []const u8) core.JournalKey {
        return .{ .security_domain = self.options.session.security_domain, .workspace_incarnation = self.options.session.bound_workspace.incarnation, .task_id = self.options.session.bound_task, .idempotency_key = idempotency };
    }
    fn matchingReceipt(receipt: core.Receipt, digest: core.Sha256) core.WriteError!core.Receipt {
        if (!std.mem.eql(u8, &receipt.op_digest, &digest)) return error.InvalidArgument;
        return receipt;
    }
    fn lookup(self: *Editor, idempotency: []const u8, digest: core.Sha256) core.WriteError!?core.Receipt {
        // The caller retains a callback before any store operation can require
        // allocation-free emergency quarantine.
        const result = self.options.journal.lookup(self.journalKey(idempotency)) catch |err| {
            if (uncertainJournalError(err)) {
                self.options.registry.failRecovery(self.options.session.bound_workspace);
                return error.RecoveryRequired;
            }
            return err;
        };
        return switch (result) {
            .absent => null,
            .found => |receipt| try matchingReceipt(receipt, digest),
            .conflict => error.InvalidArgument,
            .stored => blk: {
                self.options.registry.failRecovery(self.options.session.bound_workspace);
                break :blk error.RecoveryRequired;
            },
        };
    }
    fn stage(self: *Editor, event: Stage) void {
        if (@import("builtin").is_test) if (self.fault) |fault| if (fault.on_stage) |call| call(fault.context, event);
    }
    fn fails(self: *Editor, failure: Failure) bool {
        if (@import("builtin").is_test) if (self.fault) |fault| return fault.failure == failure;
        return false;
    }
    fn tempStage(context: *anyopaque, event: publish.TempStage) void {
        const self: *Editor = @ptrCast(@alignCast(context));
        self.stage(switch (event) {
            .after_write_chunk => .after_temp_chunk,
            .before_metadata => .before_metadata,
        });
    }
    fn quarantine(self: *Editor, pending: *const Pending) void {
        if (pending.guard) |guard| guard.failRecovery() else self.options.registry.failRecovery(self.options.session.bound_workspace);
    }
    fn transition(self: *Editor, event: core.JournalTransition) core.WriteError!void {
        if (self.options.journal.vtable.transition == null) {
            if (@import("builtin").is_test) return; // Explicit test-only fake-store compatibility.
            return error.Unsupported;
        }
        switch (try self.options.journal.transition(event)) {
            .stored => {},
            else => return error.InvariantViolation,
        }
    }
    fn recoveryReceipt(self: *Editor, pending: *const Pending, receipt_: core.Receipt) core.Receipt {
        var receipt = receipt_;
        receipt.durable = false;
        receipt.error_code = .E_RECOVERY_REQUIRED;
        receipt.cancellation_observed = receipt.cancellation_observed or self.options.cancel.isRequested();
        self.quarantine(pending);
        return receipt;
    }
    fn prepareAndPublish(self: *Editor, io: Io, parent: *publish.Parent, original: ?*publish.Original, old: []u8, new: []const u8, old_hash: ?core.ContentHash, digest: core.Sha256, idempotency: []const u8, durability: core.Durability, generation: u64, ticket: workspace.CallbackTicket, fence: core.FenceToken) core.WriteError!core.Receipt {
        try self.options.cancel.check();
        if (self.fails(.read_only)) return error.IoFailure;
        var pending: Pending = .{};
        // Keep admission closed until abort cleanup and persistence are resolved.
        defer if (pending.guard) |guard| guard.release();
        var temp = parent.createTemp(io) catch |err| {
            if (err == error.RecoveryRequired) self.quarantine(&pending);
            return err;
        };
        defer temp.file.close(io);
        if (@import("builtin").is_test) temp.probe = .{ .context = self, .call = tempStage };
        if (@import("builtin").is_test) parent.after_publish_error = self.fails(.publish_error_after_success);
        const result = self.finishPublish(io, parent, &temp, original, old, new, old_hash, digest, idempotency, durability, generation, ticket, fence, &pending) catch |err| {
            if (err == error.RecoveryRequired) {
                self.quarantine(&pending);
                return err;
            }
            parent.revalidate(io) catch {
                self.quarantine(&pending);
                return error.RecoveryRequired;
            };
            temp.cleanupName(parent) catch {
                self.quarantine(&pending);
                return error.RecoveryRequired;
            };
            if (pending.prepared) {
                var aborted = pending.receipt.?;
                aborted.error_code = core.errors.wireCode(err);
                aborted.cancellation_observed = self.options.cancel.isRequested();
                self.transition(.{ .aborted = aborted }) catch {
                    self.quarantine(&pending);
                    return error.RecoveryRequired;
                };
            }
            return err;
        };
        // A concurrent duplicate may return its prior receipt before publication.
        if (!temp.published) {
            parent.revalidate(io) catch return self.recoveryReceipt(&pending, result);
            temp.cleanupName(parent) catch return self.recoveryReceipt(&pending, result);
        }
        return result;
    }
    fn finishPublish(self: *Editor, io: Io, parent: *publish.Parent, temp: *publish.Temp, original: ?*publish.Original, old: []u8, new: []const u8, old_hash: ?core.ContentHash, digest: core.Sha256, idempotency: []const u8, durability: core.Durability, generation: u64, ticket: workspace.CallbackTicket, fence: core.FenceToken, pending: *Pending) core.WriteError!core.Receipt {
        if (self.fails(.temp_write)) return error.IoFailure;
        try temp.writeAll(io, new, self.options.cancel);
        if (self.fails(.metadata)) return error.IoFailure;
        try temp.copyMetadata(original);
        self.stage(.after_temp);
        try self.options.cancel.check();
        if (durability != .process) {
            try parent.sync(); // Refuse unsupported directory persistence before commit.
            try temp.sync(io);
        }
        try self.options.cancel.check();
        const new_hash = hash(new);
        var receipt: core.Receipt = .{ .id = undefined, .idempotency_key = idempotency, .op_digest = digest, .applied = false, .durable = false, .cancellation_observed = false, .old_hash = old_hash, .new_hash = new_hash, .generation = generation, .error_code = null };
        io.randomSecure(&receipt.id.uuid) catch return error.IoFailure;
        if (self.fails(.prepare)) return error.IoFailure;
        pending.receipt = receipt;
        const publication: core.PublicationIdentity = .{
            .workspace_id = ticket.workspace_id,
            .root_id = fileId((try policy.paths.statHandle(parent.root.handle)).identity),
            .parent_id = fileId((try policy.paths.statHandle(parent.dir.handle)).identity),
            .temp_id = fileId(temp.identity),
            .temp_name = &temp.name,
            .old_file_id = if (original) |source| fileId(source.metadata.identity) else null,
            .fence = fence,
            .durability = durability,
            .receipt_id = receipt.id,
        };
        const prepared = self.options.journal.prepare(.{ .key = self.journalKey(idempotency), .op_digest = digest, .path = .{ .bytes = parent.path }, .old_hash = old_hash, .new_hash = new_hash, .generation = generation, .publication = publication }) catch |err| {
            // Persistence may have completed before a filesystem error reached
            // this caller. Preserve the exact temp and pending identity proof.
            if (uncertainJournalError(err)) return error.RecoveryRequired;
            return err;
        };
        switch (prepared) {
            .stored => {},
            .found => |prior| return matchingReceipt(prior, digest),
            .conflict => return error.InvalidArgument,
            .absent => return error.RecoveryRequired,
        }
        pending.prepared = true;
        self.stage(.after_prepare);
        self.stage(.before_commit);
        try self.options.cancel.check();
        const guard = try self.options.registry.acquireCommit(ticket);
        pending.guard = guard;
        try parent.revalidate(io);
        if (original) |source| try source.checkUnchanged(io, parent, old, old_hash.?, self.options.cancel);
        self.stage(.guarded);
        try self.options.cancel.check();
        if (self.fails(.publish)) return error.IoFailure;
        if (original != null) try parent.publishReplace(temp) else try parent.publishCreate(temp);
        // No error return after this point may erase the committed mutation.
        guard.markApplied();
        receipt.applied = true;
        receipt.generation = guard.next_generation;
        self.stage(.after_commit);
        self.transition(.{ .applied = receipt }) catch return self.recoveryReceipt(pending, receipt);
        if (durability != .process) {
            self.stage(.before_sync);
            if (self.fails(.sync)) {
                receipt.error_code = .E_DURABILITY;
            } else if (parent.sync()) |_| {
                receipt.durable = true;
                self.stage(.after_sync);
            } else |_| {
                receipt.error_code = .E_DURABILITY;
            }
        }
        receipt.cancellation_observed = self.options.cancel.isRequested();
        self.stage(.before_record);
        receipt.cancellation_observed = receipt.cancellation_observed or self.options.cancel.isRequested();
        if (self.fails(.record)) return self.recoveryReceipt(pending, receipt);
        const recorded = self.options.journal.record(receipt) catch return self.recoveryReceipt(pending, receipt);
        switch (recorded) {
            .stored => {},
            else => return self.recoveryReceipt(pending, receipt),
        }
        // A recovery-aware APPLIED durability outcome must not be obscured by a
        // later write. Successful exclusive recovery is required to re-enable.
        if (receipt.error_code == .E_DURABILITY) guard.failRecovery();
        self.stage(.after_record);
        return receipt;
    }
    comptime {
        core.conforms(core.ApplyPatchFn(Editor), applyPatch);
        core.conforms(core.CreateFileFn(Editor), createFile);
    }
};

/// The remaining contract/resource errors are documented side-effect-free
/// admission refusals: the store must not persist partial state before them.
fn uncertainJournalError(err: core.JournalError) bool {
    return switch (err) {
        error.NotFound, error.NotRegular, error.IoFailure, error.DurabilityFailed, error.RecoveryRequired, error.InvariantViolation => true,
        else => false,
    };
}
fn fileId(identity: policy.paths.Identity) core.FileId {
    return .{ .device = identity.device, .inode = identity.inode };
}
fn validText(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes) and std.mem.indexOfScalar(u8, bytes, 0) == null;
}
fn hash(bytes: []const u8) core.ContentHash {
    var digest: core.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}
fn validateReplacements(replacements: []const core.Replacement) core.WriteError!void {
    if (replacements.len == 0 or replacements.len > core.limits.values.max_patch_spans) return error.InvalidArgument;
    var previous_end: u64 = 0;
    var previous_insertion: ?u64 = null;
    var total: u64 = 0;
    for (replacements) |replacement| {
        if (replacement.span.start < previous_end or replacement.span.end < replacement.span.start or replacement.span.end > max_file or !validText(replacement.text)) return error.InvalidArgument;
        if (replacement.span.start == replacement.span.end) {
            if (previous_insertion == replacement.span.start) return error.InvalidArgument;
            previous_insertion = replacement.span.start;
        }
        total = std.math.add(u64, total, replacement.text.len) catch return error.InvalidArgument;
        if (total > max_file) return error.InvalidArgument;
        previous_end = replacement.span.end;
    }
}
fn boundary(bytes: []const u8, offset: u64) bool {
    return offset == bytes.len or (offset < bytes.len and bytes[@intCast(offset)] & 0xc0 != 0x80);
}
fn resultingSize(old: []const u8, replacements: []const core.Replacement) core.WriteError!usize {
    var size: u64 = old.len;
    for (replacements) |replacement| {
        if (replacement.span.end > old.len or !boundary(old, replacement.span.start) or !boundary(old, replacement.span.end)) return error.InvalidArgument;
        size -= replacement.span.end - replacement.span.start;
        size = std.math.add(u64, size, replacement.text.len) catch return error.InvalidArgument;
    }
    if (size > max_file) return error.InvalidArgument;
    return @intCast(size);
}
fn synthesize(old: []const u8, replacements: []const core.Replacement, new: []u8) void {
    var source: usize = 0;
    var target: usize = 0;
    for (replacements) |replacement| {
        const start: usize = @intCast(replacement.span.start);
        const end: usize = @intCast(replacement.span.end);
        const unchanged = old[source..start];
        @memcpy(new[target..][0..unchanged.len], unchanged);
        target += unchanged.len;
        @memcpy(new[target..][0..replacement.text.len], replacement.text);
        target += replacement.text.len;
        source = end;
    }
    @memcpy(new[target..], old[source..]);
}
const Sha = std.crypto.hash.sha2.Sha256;
fn number(hasher: *Sha, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}
fn field(hasher: *Sha, bytes: []const u8) void {
    number(hasher, bytes.len);
    hasher.update(bytes);
}
fn patchDigest(spec: core.PatchSpec) core.Sha256 {
    var hasher = Sha.init(.{});
    field(&hasher, "zcr/write-operation/1/patch");
    field(&hasher, spec.path.bytes);
    hasher.update(&spec.expected_sha256);
    number(&hasher, @intFromEnum(spec.durability));
    number(&hasher, spec.replacements.len);
    for (spec.replacements) |replacement| {
        number(&hasher, replacement.span.start);
        number(&hasher, replacement.span.end);
        field(&hasher, replacement.text);
    }
    return hasher.finalResult();
}
fn createDigest(spec: core.CreateSpec) core.Sha256 {
    var hasher = Sha.init(.{});
    field(&hasher, "zcr/write-operation/1/create");
    field(&hasher, spec.path.bytes);
    number(&hasher, @intFromEnum(spec.durability));
    field(&hasher, spec.content);
    return hasher.finalResult();
}
