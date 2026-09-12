//! T10 workspace authority. The host supplies an approved absolute Git executable,
//! root handle, immutable policy, and authenticated session binding. Public I08/I09
//! signatures stay frozen. Call validateWorkspace before using a static Authorizer;
//! writer publication holds acquireCommit(ticket) through filesystem publish;
//! CommitGuard.markApplied publishes its reserved generation before release.
const std = @import("std");
const core = @import("zcr_core");
const paths = @import("zcr_policy").paths;
pub const identity = @import("identity.zig");
pub const lease = @import("lease.zig");
const Io = std.Io;
const A = std.mem.Allocator;
pub const max_workspaces = 32;
pub const max_sessions = 16;
pub const max_pending_discovery = 2;
pub const max_commit_waiters = 64;

pub const Snapshot = struct {
    workspace_id: core.WorkspaceId,
    repo_id: core.RepoId,
    root_id: core.FileId,
    git_dir_id: core.FileId,
    generation: u64,
    /// HEAD retained from the same trusted discovery that registered this entry.
    head: [64]u8 = @splat(0),
    head_len: u8 = 0,
    root: core.TrustedRoot,
    git: core.GitMetadata,
};
pub const CallbackTicket = struct { workspace_id: core.WorkspaceId, ticket: lease.CallbackTicket };
const Publishing = struct {
    id: u64,
    ticket: lease.CallbackTicket,
    next_generation: u64,
    applied: bool = false,
};
/// Owns one workspace's filesystem publication slot. Keep the Registry alive
/// through release; copied/duplicate guards cannot release a later guard.
/// While held, use the already-retained Snapshot and next_generation; call only
/// markApplied/release/failRecovery on this workspace. Ordinary Registry calls, including
/// snapshot/validateWorkspace, may wait for publication if identity changed.
/// Other workspaces progress independently; owner endCallback returns Busy.
pub const CommitGuard = struct {
    registry: *Registry,
    workspace_id: core.WorkspaceId,
    id: u64,
    next_generation: u64,
    pub fn markApplied(self: CommitGuard) void {
        self.registry.markCommitApplied(self);
    }
    pub fn release(self: CommitGuard) void {
        self.registry.releaseCommit(self);
    }
    /// Disable managed writes and revoke the writer before waking any waiting
    /// publisher. This cannot fail due to waiter capacity or a retired binding.
    pub fn failRecovery(self: CommitGuard) void {
        self.registry.failCommitRecovery(self);
    }
};
const Entry = struct {
    id: core.WorkspaceId,
    discovery: identity.Identity,
    policy: core.Policy,
    writer: lease.State = .{},
    publishing: ?Publishing = null,
    publication_done: Io.Condition = .init,
    publication_waiters: usize = 0,
    recovery_waiters: usize = 0,
    generation: u64 = 1,
    active: bool = true,
    managed_write: bool = false,
};
const Binding = struct {
    session: core.SessionContext,
    task: core.TaskContext,
    base: [64]u8,
    base_len: u8,
    fn matches(self: *const Binding, task: core.TaskContext) bool {
        return std.mem.eql(u8, &self.task.task_id.uuid, &task.task_id.uuid) and
            std.mem.eql(u8, &self.task.scope_digest, &task.scope_digest) and self.task.fence == task.fence and
            self.task.expires_at_unix_ms == task.expires_at_unix_ms and
            std.mem.eql(u8, self.base[0..self.base_len], task.base_commit orelse return false);
    }
};

pub const Registry = struct {
    allocator: A,
    io: Io,
    git_executable: []const u8,
    boot_nonce: core.Uuid,
    registry_uuid: core.Uuid,
    mutex: Io.Mutex = .init,
    entries: [max_workspaces]?Entry = @splat(null),
    bindings: [max_sessions]?Binding = @splat(null),
    used: usize = 0,
    pending: usize = 0,
    last_commit_id: u64 = 0,
    capacity: usize,
    /// Compiled out of runtime builds. Tests use this barrier to suspend a call
    /// immediately before its serialized authority check takes the mutex.
    test_before_lock: if (@import("builtin").is_test) ?struct {
        context: *anyopaque,
        enter: *const fn (*anyopaque) void,
    } else void = if (@import("builtin").is_test) null else {},

    pub const Options = struct { git_executable: []const u8, capacity: usize = max_workspaces };
    pub fn init(allocator: A, io: Io, options: Options) core.RegisterError!Registry {
        if (options.capacity == 0 or options.capacity > max_workspaces or !std.fs.path.isAbsolute(options.git_executable) or
            options.git_executable.len > 4096 or std.mem.indexOfScalar(u8, options.git_executable, 0) != null) return error.InvalidArgument;
        var boot: core.Uuid = undefined;
        var uuid: core.Uuid = undefined;
        io.randomSecure(&boot) catch return error.IoFailure;
        io.randomSecure(&uuid) catch return error.IoFailure;
        return .{ .allocator = allocator, .io = io, .git_executable = try allocator.dupe(u8, options.git_executable), .boot_nonce = boot, .registry_uuid = uuid, .capacity = options.capacity };
    }

    /// Exclusive teardown only, after callers stop. Busy preserves every handle
    /// and callback context until the host drains in-flight work and retries.
    pub fn deinit(self: *Registry) core.LeaseError!void {
        self.lock();
        if (self.pending != 0) {
            self.unlock();
            return error.Busy;
        }
        for (self.entries[0..self.used]) |*slot| {
            const entry = &slot.*.?;
            if (entry.publishing != null or entry.publication_waiters != 0 or entry.recovery_waiters != 0 or !entry.writer.isDrained()) {
                self.unlock();
                return error.Busy;
            }
        }
        self.unlock();
        for (self.entries[0..self.used]) |*entry| entry.*.?.discovery.deinit(self.io);
        self.allocator.free(self.git_executable);
        self.* = undefined;
    }
    pub fn bootNonce(self: *const Registry) core.Uuid {
        return self.boot_nonce;
    }
    fn lock(self: *Registry) void {
        if (@import("builtin").is_test) {
            if (self.test_before_lock) |hook| hook.enter(hook.context);
        }
        self.mutex.lockUncancelable(self.io);
    }
    fn unlock(self: *Registry) void {
        self.mutex.unlock(self.io);
    }
    fn find(self: *Registry, id: core.WorkspaceId) ?*Entry {
        for (self.entries[0..self.used]) |*slot| {
            const e = &slot.*.?;
            if (e.id.eql(id)) return e;
        }
        return null;
    }
    /// Called with the registry mutex held. Entries retain their address, but
    /// callers must recheck authority and binding slots after this releases it.
    fn waitForPublication(self: *Registry, entry: *Entry) error{ResourceExhausted}!void {
        if (entry.publishing == null) return;
        if (entry.publication_waiters == max_commit_waiters) return error.ResourceExhausted;
        entry.publication_waiters += 1;
        defer entry.publication_waiters -= 1;
        while (entry.publishing != null) entry.publication_done.waitUncancelable(self.io, &self.mutex);
    }
    /// Return a stable entry with the mutex held and no publication in progress.
    /// A potentially long wait invalidates earlier filesystem checks, so repeat
    /// those checks outside the mutex before exposing authority again.
    fn lockForMutation(self: *Registry, id: core.WorkspaceId, owner: ?lease.CallbackTicket) core.LeaseError!*Entry {
        while (true) {
            try self.validateWorkspace(id);
            self.lock();
            const entry = self.find(id).?;
            if (!entry.active) {
                self.unlock();
                return error.FenceMismatch;
            }
            if (entry.publishing) |publishing| {
                if (owner) |ticket| if (ticket == publishing.ticket) {
                    self.unlock();
                    return error.Busy;
                };
                self.waitForPublication(entry) catch |err| {
                    self.unlock();
                    return err;
                };
                self.unlock();
                continue;
            }
            return entry;
        }
    }
    fn retire(self: *Registry, e: *Entry) void {
        std.debug.assert(e.publishing == null);
        e.active = false;
        e.managed_write = false;
        e.writer.revoke();
        for (&self.bindings) |*binding| if (binding.* != null and binding.*.?.session.bound_workspace.eql(e.id)) {
            binding.* = null;
        };
    }

    pub fn registerWorkspace(self: *Registry, io: Io, root: core.TrustedRoot, policy: core.Policy) core.RegisterError!core.WorkspaceId {
        try validatePolicy(policy);
        self.lock();
        if (self.pending == max_pending_discovery) {
            self.unlock();
            return error.Busy;
        }
        self.pending += 1;
        self.unlock();
        defer {
            self.lock();
            self.pending -= 1;
            self.unlock();
        }
        // A condition wait may allow another registration/retirement to finish.
        // Rediscover outside the lock and rescan every slot rather than reuse
        // stale root metadata or a decision made before the wait.
        discover_again: while (true) {
            var discovered = try identity.discover(self.allocator, io, self.git_executable, root);
            var transferred = false;
            defer if (!transferred) discovered.deinit(io);
            const owned_policy = try clonePolicy(discovered.arena.allocator(), policy);
            var incarnation: core.Uuid = undefined;
            io.randomSecure(&incarnation) catch return error.IoFailure;
            self.lock();
            defer self.unlock();
            for (self.entries[0..self.used]) |*slot| {
                const e = &slot.*.?;
                if (e.active and e.publishing != null and
                    (identity.eql(e.discovery.root_id, discovered.root_id) or
                        std.mem.eql(u8, e.discovery.root.canonical_path, discovered.root.canonical_path)))
                {
                    try self.waitForPublication(e);
                    continue :discover_again;
                }
            }
            for (self.entries[0..self.used]) |*slot| {
                const e = &slot.*.?;
                if (!e.active) continue;
                if (e.discovery.same(&discovered)) {
                    if (!std.mem.eql(u8, &e.policy.digest, &policy.digest) or !policyEqual(e.policy, policy)) return error.OutOfScope;
                    if (e.discovery.head_len != discovered.head_len or !std.mem.eql(u8, &e.discovery.head, &discovered.head)) {
                        e.generation = std.math.add(u64, e.generation, 1) catch {
                            self.retire(e);
                            return error.ResourceExhausted;
                        };
                        e.discovery.head = discovered.head;
                        e.discovery.head_len = discovered.head_len;
                    }
                    return e.id;
                }
                if (identity.eql(e.discovery.root_id, discovered.root_id) or std.mem.eql(u8, e.discovery.root.canonical_path, discovered.root.canonical_path)) self.retire(e);
            }
            // Retired entries retain descriptors and callback/guard counters.
            if (self.used == self.capacity) return error.ResourceExhausted;
            const id: core.WorkspaceId = .{ .registry_uuid = self.registry_uuid, .incarnation = incarnation };
            self.entries[self.used] = .{ .id = id, .discovery = discovered, .policy = owned_policy };
            self.used += 1;
            transferred = true;
            return id;
        }
    }

    pub fn validateWorkspace(self: *Registry, id: core.WorkspaceId) core.LeaseError!void {
        self.lock();
        const e = self.find(id) orelse {
            self.unlock();
            return error.FenceMismatch;
        };
        if (!e.active) {
            self.unlock();
            return error.FenceMismatch;
        }
        // Entries are address-stable until exclusive deinit; no filesystem I/O
        // occurs while the registry lock is held.
        self.unlock();
        e.discovery.validate(self.io) catch {
            self.lock();
            defer self.unlock();
            try self.waitForPublication(e);
            self.retire(e);
            return error.FenceMismatch;
        };
        self.lock();
        defer self.unlock();
        if (!e.active) return error.FenceMismatch;
    }
    pub fn snapshot(self: *Registry, id: core.WorkspaceId) core.LeaseError!Snapshot {
        try self.validateWorkspace(id);
        self.lock();
        defer self.unlock();
        const e = self.find(id).?;
        if (!e.active) return error.FenceMismatch;
        return .{ .workspace_id = id, .repo_id = .{ .common_dir = e.discovery.common_dir_id, .registry_uuid = self.registry_uuid }, .root_id = e.discovery.root_id, .git_dir_id = e.discovery.git_dir_id, .generation = e.generation, .head = e.discovery.head, .head_len = e.discovery.head_len, .root = e.discovery.root, .git = e.discovery.git };
    }
    pub fn markChanged(self: *Registry, id: core.WorkspaceId) core.LeaseError!u64 {
        const e = try self.lockForMutation(id, null);
        defer self.unlock();
        if (!e.active) return error.FenceMismatch;
        e.generation = std.math.add(u64, e.generation, 1) catch {
            self.retire(e);
            return error.ResourceExhausted;
        };
        return e.generation;
    }
    /// Host assertion: every writer to this dedicated workspace participates in
    /// ZCR. Never infer this condition from a clean worktree or a policy digest.
    pub fn setManagedWrite(self: *Registry, id: core.WorkspaceId, enabled: bool) core.LeaseError!void {
        const e = try self.lockForMutation(id, null);
        defer self.unlock();
        if (!e.active) return error.FenceMismatch;
        e.managed_write = enabled;
        if (!enabled) e.writer.revoke();
    }
    /// Trusted handshake only. TaskContext in I09 is matched against this stored
    /// session authority, because I09 has no SessionContext parameter.
    pub fn bindSession(self: *Registry, session: core.SessionContext, task: core.TaskContext, boot_nonce: core.Uuid) core.RegisterError!void {
        if (!std.mem.eql(u8, &boot_nonce, &self.boot_nonce)) return error.OutOfScope;
        self.validateWorkspace(session.bound_workspace) catch return error.OutOfScope;
        if (session.capability_handle == .none or allZero(&session.session_id.uuid) or allZero(&task.task_id.uuid) or
            !std.mem.eql(u8, &session.bound_task.uuid, &task.task_id.uuid) or !std.mem.eql(u8, &session.policy_digest, &task.scope_digest) or
            task.fence == 0) return error.OutOfScope;
        const base = task.base_commit orelse return error.ManifestUnbound;
        if (base.len != 40 and base.len != 64) return error.InvalidArgument;
        for (base) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidArgument;
        self.lock();
        defer self.unlock();
        const e = self.find(session.bound_workspace).?;
        if (task.expires_at_unix_ms <= wallNow(self.io) or !e.active or
            !std.mem.eql(u8, &session.policy_digest, &e.policy.digest)) return error.OutOfScope;
        var empty: ?usize = null;
        for (&self.bindings, 0..) |*slot, i| {
            const b = &(slot.* orelse {
                if (empty == null) empty = i;
                continue;
            });
            if (std.mem.eql(u8, &b.session.session_id.uuid, &session.session_id.uuid) or std.mem.eql(u8, &b.task.task_id.uuid, &task.task_id.uuid)) {
                if (b.matches(task) and std.meta.eql(b.session, session)) return;
                return error.OutOfScope;
            }
        }
        const i = empty orelse return error.ResourceExhausted;
        var binding: Binding = .{ .session = session, .task = task, .base = @splat(0), .base_len = @intCast(base.len) };
        // Borrowed base_commit never escapes; matches uses the owned array.
        binding.task.base_commit = null;
        @memcpy(binding.base[0..base.len], base);
        self.bindings[i] = binding;
    }
    pub fn validateSession(self: *Registry, session: core.SessionContext, boot: core.Uuid) core.RegisterError!void {
        if (!std.mem.eql(u8, &boot, &self.boot_nonce)) return error.OutOfScope;
        self.validateWorkspace(session.bound_workspace) catch return error.OutOfScope;
        self.lock();
        defer self.unlock();
        const wall = wallNow(self.io);
        for (&self.bindings) |*slot| if (slot.*) |*b| {
            if (std.meta.eql(b.session, session) and b.task.expires_at_unix_ms > wall) return;
        };
        return error.OutOfScope;
    }
    pub fn unbindSession(self: *Registry, id: core.SessionId, boot: core.Uuid) core.RegisterError!void {
        if (!std.mem.eql(u8, &boot, &self.boot_nonce)) return error.OutOfScope;
        self.lock();
        defer self.unlock();
        relookup: while (true) {
            for (&self.bindings) |*slot| if (slot.*) |*binding| {
                if (!std.mem.eql(u8, &binding.session.session_id.uuid, &id.uuid)) continue;
                if (self.find(binding.session.bound_workspace)) |entry| {
                    if (entry.publishing != null) {
                        try self.waitForPublication(entry);
                        // The old slot may now be cleared/reused. Never retain
                        // a Binding pointer or task identity across this wait.
                        continue :relookup;
                    }
                    revokeTaskWriter(entry, binding.task.task_id);
                }
                slot.* = null;
                return;
            };
            return error.OutOfScope;
        }
    }
    fn authorizeTask(self: *Registry, e: *Entry, task: core.TaskContext, now_ms: i64) core.LeaseError!void {
        if (!e.active) return error.FenceMismatch;
        var found = false;
        for (&self.bindings) |*slot| if (slot.*) |*b| {
            if (b.session.bound_workspace.eql(e.id) and b.matches(task)) {
                found = true;
                break;
            }
        };
        if (!found) return error.FenceMismatch;
        if (task.expires_at_unix_ms <= now_ms) {
            revokeTaskWriter(e, task.task_id);
            return error.LeaseExpired;
        }
        if (!e.managed_write or !allowsWrite(e.policy)) return error.LeaseExpired;
    }
    pub fn acquireWriter(self: *Registry, task: core.TaskContext, id: core.WorkspaceId) core.LeaseError!core.WriterLease {
        const e = try self.lockForMutation(id, null);
        defer self.unlock();
        const now = monotonicNow(self.io);
        const wall = wallNow(self.io);
        try self.authorizeTask(e, task, wall);
        for (self.entries[0..self.used]) |*slot| {
            const predecessor = &slot.*.?;
            if (predecessor != e and !predecessor.writer.isDrained() and
                (identity.eql(predecessor.discovery.root_id, e.discovery.root_id) or std.mem.eql(u8, predecessor.discovery.root.canonical_path, e.discovery.root.canonical_path))) return error.Busy;
        }
        return e.writer.acquire(id, task.task_id, now);
    }
    fn checkLeaseBinding(self: *Registry, e: *Entry, l: core.WriterLease, wall: i64) core.LeaseError!void {
        if (!e.active) return error.FenceMismatch;
        if (!e.managed_write or !allowsWrite(e.policy)) return error.LeaseExpired;
        for (&self.bindings) |*slot| if (slot.*) |*b| {
            if (b.session.bound_workspace.eql(e.id) and std.mem.eql(u8, &b.task.task_id.uuid, &l.task_id.uuid)) {
                if (b.task.expires_at_unix_ms <= wall) {
                    revokeTaskWriter(e, b.task.task_id);
                    return error.LeaseExpired;
                }
                return;
            }
        };
        return error.FenceMismatch;
    }
    pub fn validateLease(self: *Registry, l: core.WriterLease) core.LeaseError!void {
        const e = try self.lockForMutation(l.workspace_id, null);
        defer self.unlock();
        const now = monotonicNow(self.io);
        const wall = wallNow(self.io);
        try self.checkLeaseBinding(e, l, wall);
        try e.writer.validate(l, now);
    }
    pub fn renewWriter(self: *Registry, l: core.WriterLease) core.LeaseError!core.WriterLease {
        const e = try self.lockForMutation(l.workspace_id, null);
        defer self.unlock();
        const now = monotonicNow(self.io);
        const wall = wallNow(self.io);
        try self.checkLeaseBinding(e, l, wall);
        return e.writer.renew(l, now);
    }
    pub fn revokeWriter(self: *Registry, id: core.WorkspaceId) core.LeaseError!void {
        self.lock();
        defer self.unlock();
        const e = self.find(id) orelse return error.FenceMismatch;
        try self.waitForPublication(e);
        e.writer.revoke();
    }
    /// Emergency recovery path for a caller retaining an outstanding callback.
    /// Never call while owning this workspace's guard: use guard.failRecovery.
    /// Stop new writes immediately, then let an already-admitted publication
    /// finish before revoking. Waiting allocates nothing and uses the caller's
    /// existing bounded callback resources, independent of ordinary waiter quota.
    pub fn failRecovery(self: *Registry, id: core.WorkspaceId) void {
        self.lock();
        defer self.unlock();
        const e = self.find(id) orelse return;
        e.managed_write = false;
        e.recovery_waiters += 1;
        defer e.recovery_waiters -= 1;
        while (e.publishing != null) e.publication_done.waitUncancelable(self.io, &self.mutex);
        e.managed_write = false;
        e.writer.revoke();
    }
    pub fn beginCallback(self: *Registry, l: core.WriterLease) core.LeaseError!CallbackTicket {
        const e = try self.lockForMutation(l.workspace_id, null);
        defer self.unlock();
        const now = monotonicNow(self.io);
        const wall = wallNow(self.io);
        try self.checkLeaseBinding(e, l, wall);
        return .{ .workspace_id = l.workspace_id, .ticket = try e.writer.beginCallback(l, now) };
    }
    pub fn validateCallback(self: *Registry, ticket: CallbackTicket) core.LeaseError!void {
        const e = try self.lockForMutation(ticket.workspace_id, null);
        defer self.unlock();
        const now = monotonicNow(self.io);
        const wall = wallNow(self.io);
        // Every callback must still belong to a live bound task. The State checks
        // its own task/fence; task expiry is checked through the active lease.
        if (!e.active or !e.managed_write) return error.FenceMismatch;
        if (e.writer.currentLease()) |active| try self.checkLeaseBinding(e, active, wall);
        try e.writer.validateCallback(ticket.ticket, now);
    }
    /// Acquire immediately before filesystem publication. The registry mutex is
    /// released on return; this guard retains only the workspace publishing slot.
    pub fn acquireCommit(self: *Registry, ticket: CallbackTicket) core.LeaseError!CommitGuard {
        const e = try self.lockForMutation(ticket.workspace_id, ticket.ticket);
        defer self.unlock();
        const now = monotonicNow(self.io);
        const wall = wallNow(self.io);
        if (!e.active or !e.managed_write) return error.FenceMismatch;
        if (e.writer.currentLease()) |active| try self.checkLeaseBinding(e, active, wall);
        try e.writer.validateCallback(ticket.ticket, now);
        const generation = std.math.add(u64, e.generation, 1) catch return error.ResourceExhausted;
        const id = std.math.add(u64, self.last_commit_id, 1) catch return error.ResourceExhausted;
        self.last_commit_id = id;
        e.publishing = .{ .id = id, .ticket = ticket.ticket, .next_generation = generation };
        return .{ .registry = self, .workspace_id = ticket.workspace_id, .id = id, .next_generation = generation };
    }
    fn markCommitApplied(self: *Registry, guard: CommitGuard) void {
        self.lock();
        defer self.unlock();
        const e = self.find(guard.workspace_id) orelse return;
        const publishing = &(e.publishing orelse return);
        if (publishing.id != guard.id or publishing.applied) return;
        e.generation = publishing.next_generation;
        e.publishing.?.applied = true;
    }
    fn releaseCommit(self: *Registry, guard: CommitGuard) void {
        self.lock();
        defer self.unlock();
        const e = self.find(guard.workspace_id) orelse return;
        const publishing = e.publishing orelse return;
        if (publishing.id != guard.id) return;
        e.publishing = null;
        e.publication_done.broadcast(self.io);
    }
    fn failCommitRecovery(self: *Registry, guard: CommitGuard) void {
        self.lock();
        defer self.unlock();
        const e = self.find(guard.workspace_id) orelse return;
        const publishing = e.publishing orelse return;
        if (publishing.id != guard.id) return;
        e.managed_write = false;
        e.writer.revoke();
        e.publishing = null;
        e.publication_done.broadcast(self.io);
    }
    pub fn endCallback(self: *Registry, ticket: CallbackTicket) core.LeaseError!void {
        self.lock();
        defer self.unlock();
        const e = self.find(ticket.workspace_id) orelse return error.FenceMismatch;
        // The publishing owner must release its guard before completing itself.
        // Waiting here could deadlock that same callback, so reject explicitly.
        if (e.publishing) |publishing| if (publishing.ticket == ticket.ticket) return error.Busy;
        // Other callback completions and retired-entry drains grant no authority.
        try e.writer.endCallback(ticket.ticket);
    }
    comptime {
        core.conforms(core.RegisterWorkspaceFn(Registry), registerWorkspace);
        core.conforms(core.AcquireWriterFn(Registry), acquireWriter);
    }
};
/// A session ending or an expired request only revokes its own task's writer.
/// Workspace retirement and explicit revoke remain workspace-wide operations.
fn revokeTaskWriter(entry: *Entry, task_id: core.TaskId) void {
    std.debug.assert(entry.publishing == null);
    const current = entry.writer.currentLease() orelse return;
    if (std.mem.eql(u8, &current.task_id.uuid, &task_id.uuid)) entry.writer.revoke();
}
fn monotonicNow(io: Io) u64 {
    return @intCast(@max(0, Io.Clock.awake.now(io).nanoseconds));
}
fn wallNow(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}
fn allZero(bytes: []const u8) bool {
    for (bytes) |b| if (b != 0) return false;
    return true;
}
fn allowsWrite(p: core.Policy) bool {
    if (p.state != .active or p.write_paths.len == 0 or p.max_changed_files == 0) return false;
    for (p.operations) |op| if (op == .patch or op == .create) return true;
    return false;
}
fn validatePolicy(p: core.Policy) core.RegisterError!void {
    if (p.state == .planned) return error.ManifestUnbound;
    if (p.state != .active and p.state != .ready) return error.OutOfScope;
    if (allZero(&p.digest) or p.operations.len == 0 or p.operations.len > 8) return error.InvalidArgument;
    var count: usize = 0;
    var bytes: usize = 0;
    for ([_][]const core.RelativePath{ p.read_paths, p.write_paths, p.immutable_paths }) |list| {
        count += list.len;
        if (count > 64) return error.ResourceExhausted;
        for (list) |path| {
            try paths.validate(path.bytes);
            bytes += path.bytes.len;
            if (bytes > 65536) return error.ResourceExhausted;
        }
    }
    var seen: u16 = 0;
    for (p.operations) |op| {
        const bit = @as(u16, 1) << @intCast(@intFromEnum(op));
        if (seen & bit != 0) return error.InvalidArgument;
        seen |= bit;
    }
}
fn clonePaths(a: A, list: []const core.RelativePath) A.Error![]const core.RelativePath {
    const out = try a.alloc(core.RelativePath, list.len);
    for (list, out) |src, *dst| dst.* = .{ .bytes = try a.dupe(u8, src.bytes) };
    return out;
}
fn clonePolicy(a: A, p: core.Policy) A.Error!core.Policy {
    var result = p;
    result.read_paths = try clonePaths(a, p.read_paths);
    result.write_paths = try clonePaths(a, p.write_paths);
    result.immutable_paths = try clonePaths(a, p.immutable_paths);
    result.operations = try a.dupe(core.Operation, p.operations);
    return result;
}
fn policyEqual(a: core.Policy, b: core.Policy) bool {
    if (a.state != b.state or a.max_changed_files != b.max_changed_files or !std.mem.eql(core.Operation, a.operations, b.operations)) return false;
    for ([_][]const core.RelativePath{ a.read_paths, a.write_paths, a.immutable_paths }, [_][]const core.RelativePath{ b.read_paths, b.write_paths, b.immutable_paths }) |left, right| {
        if (left.len != right.len) return false;
        for (left, right) |x, y| if (!std.mem.eql(u8, x.bytes, y.bytes)) return false;
    }
    return true;
}
