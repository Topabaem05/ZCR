//! Watch events invalidate hints, never grant authority or certify snapshots.
//! Callbacks only update bounded owned metadata; actor work performs live I/O.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const workspace = @import("zcr_workspace");
const cache = @import("zcr_cache");
const fs = @import("zcr_fs_traverse");
const Io = std.Io;
pub const linux = @import("linux.zig");
pub const darwin = @import("darwin.zig");
pub const Native = if (builtin.os.tag == .linux) linux else darwin;
pub const max_dirty = 64;
pub const path_max = core.limits.values.path_max_utf8_bytes;
pub const Dirty = struct {
    bytes: [path_max]u8 = undefined,
    len: usize = 0,
    pub fn path(d: *const Dirty) []const u8 {
        return d.bytes[0..d.len];
    }
};
pub const Snapshot = struct { state: core.IndexState, full_dirty: bool, dirty_count: usize, epoch: u64, generation: u64, cursor: u64 };
/// One workspace/incarnation, fixed storage. Parent allocation funds this object.
/// Concurrent invalidate/snapshot are supported; no filesystem or cache calls here.
pub const Index = struct {
    io: Io,
    id: core.WorkspaceId,
    dirty_limit: usize,
    mutex: Io.Mutex = .init,
    state: core.IndexState = .uncertain,
    full_dirty: bool = true,
    dirty: [max_dirty]Dirty = @splat(.{}),
    dirty_count: usize = 0,
    epoch: u64 = 1,
    cursor: u64 = 0,
    generation: u64 = 0,
    pub fn init(io: Io, id: core.WorkspaceId, limit: usize) error{InvalidArgument}!Index {
        if (limit == 0 or limit > max_dirty) return error.InvalidArgument;
        return .{ .io = io, .id = id, .dirty_limit = limit };
    }
    fn lock(i: *Index) void {
        i.mutex.lockUncancelable(i.io);
    }
    fn unlock(i: *Index) void {
        i.mutex.unlock(i.io);
    }
    fn uncertain(i: *Index) void {
        i.full_dirty = true;
        i.dirty_count = 0;
        i.state = .uncertain;
    }
    pub fn invalidate(i: *Index, id: core.WorkspaceId, event: core.WatchEvent) core.InvalidateError!core.IndexState {
        if (!i.id.eql(id)) return error.InvariantViolation;
        i.lock();
        defer i.unlock();
        i.epoch +|= 1;
        const cursor_lost = event.cursor != 0 and i.cursor != 0 and event.cursor < i.cursor;
        if (event.cursor != 0) i.cursor = event.cursor;
        if (cursor_lost or i.epoch == std.math.maxInt(u64)) i.uncertain();
        switch (event.kind) {
            .overflow, .dropped, .root_changed, .cursor_wrapped => i.uncertain(),
            else => {
                const raw = if (event.path) |p| p.bytes else {
                    i.uncertain();
                    return i.state;
                };
                policy.paths.validate(raw) catch {
                    i.uncertain();
                    return i.state;
                };
                if (i.full_dirty) return i.state;
                const parent = if (std.mem.lastIndexOfScalar(u8, raw, '/')) |slash| raw[0..slash] else ".";
                for (i.dirty[0..i.dirty_count]) |*existing| {
                    if (within(parent, existing.path())) return i.state;
                }
                var n: usize = 0;
                while (n < i.dirty_count) {
                    if (within(i.dirty[n].path(), parent)) {
                        i.dirty_count -= 1;
                        i.dirty[n] = i.dirty[i.dirty_count];
                    } else n += 1;
                }
                if (i.dirty_count == i.dirty_limit) {
                    i.uncertain();
                    return i.state;
                }
                const target = &i.dirty[i.dirty_count];
                i.dirty_count += 1;
                target.len = parent.len;
                @memcpy(target.bytes[0..parent.len], parent);
                if (i.state == .live) i.state = .stale;
            },
        }
        return i.state;
    }
    pub fn snapshot(i: *Index) Snapshot {
        i.lock();
        defer i.unlock();
        return .{ .state = i.state, .full_dirty = i.full_dirty, .dirty_count = i.dirty_count, .epoch = i.epoch, .generation = i.generation, .cursor = i.cursor };
    }
    pub fn copyDirty(i: *Index, out: []Dirty) usize {
        i.lock();
        defer i.unlock();
        const n = @min(out.len, i.dirty_count);
        @memcpy(out[0..n], i.dirty[0..n]);
        return n;
    }
    fn publish(i: *Index, epoch: u64, generation: u64, complete: bool) bool {
        i.lock();
        defer i.unlock();
        if (!complete or epoch != i.epoch or epoch == std.math.maxInt(u64)) {
            i.uncertain();
            return false;
        }
        i.generation = generation;
        i.full_dirty = false;
        i.dirty_count = 0;
        i.state = .live;
        return true;
    }
    fn fail(i: *Index) void {
        i.lock();
        defer i.unlock();
        i.uncertain();
    }
    comptime {
        core.conforms(core.InvalidateFn(Index), Index.invalidate);
    }
};
fn within(path: []const u8, parent: []const u8) bool {
    return std.mem.eql(u8, parent, ".") or std.mem.eql(u8, path, parent) or
        (path.len > parent.len and path[parent.len] == '/' and std.mem.startsWith(u8, path, parent));
}

pub const Options = struct {
    /// Caller-supplied shared resource owner for scans and native operations.
    work_budget: *memory.Budget,
    dirty_limit: usize = 32,
    watch_limit: usize = 128,
    reconcile_passes: usize = 3,
    caps: fs.Caps = .{ .max_depth = 32, .path_cache_entries = 256, .path_cache_bytes = 32 * core.limits.KiB },
    trusted_excludes: fs.TrustedExcludes = .{},
    content_cache: ?*cache.Store = null,
};
/// Coverage scope/reasons borrow Runtime storage until its next live walk or
/// reconcile, or deinit. The caller copies them before admitting another call.
pub const LiveResult = struct { coverage: core.Coverage, report: fs.Report };
pub const ReconcileResult = struct { snapshot: Snapshot, passes: usize, files_seen: u64, complete: bool };
pub const TestHook = struct { context: *anyopaque, after_first_path: *const fn (*anyopaque) void };
/// Fixed address, trusted bound session. The host serializes actor operations;
/// Index.invalidate can run concurrently. Dependencies outlive all operations.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
    budget: *memory.Budget,
    control: core.Reservation,
    registry: *workspace.Registry,
    authorizer: *policy.Authorizer,
    context: core.SessionContext,
    boot: core.Uuid,
    options: Options,
    index: Index,
    backend: Native.Backend = .{},
    started: bool = false,
    operation: std.atomic.Mutex = .unlocked,
    reasons: [9][]const u8 = undefined,
    scope: [path_max]u8 = undefined,
    test_hook: if (builtin.is_test) ?TestHook else void = if (builtin.is_test) null else {},
    pub fn create(a: std.mem.Allocator, io: Io, budget: *memory.Budget, registry: *workspace.Registry, authorizer: *policy.Authorizer, context: core.SessionContext, options: Options) core.ReadError!*Runtime {
        if (options.watch_limit == 0 or options.watch_limit > 128 or options.reconcile_passes == 0 or options.reconcile_passes > 8 or
            options.dirty_limit == 0 or options.dirty_limit > max_dirty or options.caps.max_depth > core.limits.values.directory_max_depth or
            options.caps.path_cache_entries > 4096 or options.caps.path_cache_bytes > 256 * core.limits.KiB or
            options.caps.max_ignore_file_bytes > core.limits.values.max_ignore_file_bytes or options.caps.max_ignore_rules > core.limits.values.max_ignore_rules) return error.InvalidArgument;
        const boot = registry.bootNonce();
        _ = try validate(io, registry, authorizer, context, boot, .enumerate, .{ .bytes = "." });
        var reservation = try budget.reserve(context, .{ .scratch_bytes = @sizeOf(Runtime), .fds = 1 });
        errdefer budget.release(&reservation) catch unreachable;
        const r = try a.create(Runtime);
        budget.counters.recordAlloc(@sizeOf(Runtime));
        r.* = .{ .allocator = a, .io = io, .budget = budget, .control = reservation, .registry = registry, .authorizer = authorizer, .context = context, .boot = boot, .options = options, .index = try Index.init(io, context.bound_workspace, options.dirty_limit) };
        return r;
    }
    fn enter(r: *Runtime) core.ReadError!void {
        if (!r.operation.tryLock()) return error.Busy;
    }
    fn leave(r: *Runtime) void {
        r.operation.unlock();
    }
    fn authority(r: *Runtime, operation: core.Operation, path: core.RelativePath, cancel: core.Cancel) core.ReadError!workspace.Snapshot {
        try cancel.check();
        return validate(r.io, r.registry, r.authorizer, r.context, r.boot, operation, path) catch |err| {
            r.index.fail();
            return err;
        };
    }
    fn receive(context: *anyopaque, event: core.WatchEvent) void {
        const r: *Runtime = @ptrCast(@alignCast(context));
        _ = r.invalidate(r.context.bound_workspace, event) catch unreachable;
    }
    /// Trusted event ingress. The frozen I14 carries no session authority; this
    /// method only mutates the already bound workspace's dirty metadata.
    pub fn invalidate(r: *Runtime, id: core.WorkspaceId, event: core.WatchEvent) core.InvalidateError!core.IndexState {
        return r.index.invalidate(id, event);
    }
    /// Installs the root watch first; no initial index is published here.
    pub fn start(r: *Runtime, cancel: core.Cancel) core.ReadError!void {
        try r.enter();
        defer r.leave();
        if (r.started) return error.Busy;
        const snap = try r.authority(.enumerate, .{ .bytes = "." }, cancel);
        var grant = try r.options.work_budget.reserve(r.context, .{ .fds = 3, .cpu_permits = 1 });
        defer r.options.work_budget.release(&grant) catch unreachable;
        try r.backend.start(r.io, snap.root, .{ .context = r, .push = receive }, r.options.watch_limit);
        r.started = true;
        errdefer {
            r.backend.stop(r.io);
            r.started = false;
        }
        _ = try r.backend.refresh(r.io, snap.root, cancel);
        _ = try r.authority(.enumerate, .{ .bytes = "." }, cancel);
    }
    pub fn poll(r: *Runtime, cancel: core.Cancel) core.ReadError!Snapshot {
        try r.enter();
        defer r.leave();
        _ = try r.authority(.enumerate, .{ .bytes = "." }, cancel);
        if (!r.started) return error.Unsupported;
        var grant = try r.options.work_budget.reserve(r.context, .{ .cpu_permits = 1 });
        defer r.options.work_budget.release(&grant) catch unreachable;
        _ = r.backend.poll(r.io, cancel) catch |err| {
            r.index.fail();
            return err;
        };
        if (r.options.content_cache) |c| if (r.index.snapshot().state != .live) c.invalidateWorkspace(r.context.bound_workspace);
        _ = try r.authority(.enumerate, .{ .bytes = "." }, cancel);
        return r.index.snapshot();
    }
    /// Full-root rescans conservatively cover every coalesced dirty range. No
    /// path candidate cache is populated, and no atomic snapshot is claimed.
    pub fn reconcile(r: *Runtime, cancel: core.Cancel) core.ReadError!ReconcileResult {
        try r.enter();
        defer r.leave();
        if (!r.started) return error.Unsupported;
        errdefer r.index.fail();
        var passes: usize = 0;
        var seen: u64 = 0;
        while (passes < r.options.reconcile_passes) {
            passes += 1;
            const snap = try r.authority(.enumerate, .{ .bytes = "." }, cancel);
            var watch_grant = try r.options.work_budget.reserve(r.context, .{ .fds = 3, .cpu_permits = 1 });
            const covered = r.backend.refresh(r.io, snap.root, cancel) catch |err| {
                r.options.work_budget.release(&watch_grant) catch unreachable;
                return err;
            };
            _ = r.backend.poll(r.io, cancel) catch |err| {
                r.options.work_budget.release(&watch_grant) catch unreachable;
                return err;
            };
            r.options.work_budget.release(&watch_grant) catch unreachable;
            if (r.options.content_cache) |c| c.invalidateWorkspace(r.context.bound_workspace);
            const token = r.index.snapshot();
            var counter = ScanCounter{ .runtime = r };
            const cap = try r.authorizer.authorize(r.io, r.context, .enumerate, .{ .bytes = "." });
            const result = try r.walk(cap, .{ .limit = core.limits.values.max_file_results, .include_hidden = true }, .{ .context = &counter, .push_fn = ScanCounter.push }, cancel, false);
            seen = counter.seen;
            var poll_grant = try r.options.work_budget.reserve(r.context, .{ .cpu_permits = 1 });
            _ = r.backend.poll(r.io, cancel) catch |err| {
                r.options.work_budget.release(&poll_grant) catch unreachable;
                return err;
            };
            r.options.work_budget.release(&poll_grant) catch unreachable;
            _ = try r.authority(.enumerate, .{ .bytes = "." }, cancel);
            if (r.index.snapshot().epoch != token.epoch) continue;
            if (!result.report.complete or !covered or !r.backend.synchronized()) {
                r.index.fail();
                break;
            }
            const generation = r.registry.markChanged(r.context.bound_workspace) catch |err| return switch (err) {
                error.ResourceExhausted => error.ResourceExhausted,
                else => error.OutOfScope,
            };
            try cancel.check();
            if (r.index.publish(token.epoch, generation, true)) return .{ .snapshot = r.index.snapshot(), .passes = passes, .files_seen = seen, .complete = true };
        }
        r.index.fail();
        return .{ .snapshot = r.index.snapshot(), .passes = passes, .files_seen = seen, .complete = false };
    }
    const ScanCounter = struct {
        runtime: *Runtime,
        seen: u64 = 0,
        fn push(context: *anyopaque, _: core.RelativePath) core.SinkError!void {
            const c: *ScanCounter = @ptrCast(@alignCast(context));
            c.seen += 1;
            if (builtin.is_test) if (c.seen == 1) if (c.runtime.test_hook) |hook| hook.after_first_path(hook.context);
        }
    };
    /// Always live; stale watcher hints never determine files or search candidates.
    pub fn enumerateLive(r: *Runtime, cap: core.Capability, spec: core.FileSpec, sink: core.Sink(core.RelativePath), cancel: core.Cancel) core.ReadError!LiveResult {
        try r.enter();
        defer r.leave();
        return r.walk(cap, spec, sink, cancel, false);
    }
    pub fn searchCandidatesLive(r: *Runtime, cap: core.Capability, spec: core.FileSpec, sink: core.Sink(core.RelativePath), cancel: core.Cancel) core.ReadError!LiveResult {
        try r.enter();
        defer r.leave();
        return r.walk(cap, spec, sink, cancel, true);
    }
    fn walk(r: *Runtime, cap: core.Capability, spec: core.FileSpec, sink: core.Sink(core.RelativePath), cancel: core.Cancel, search: bool) core.ReadError!LiveResult {
        const op: core.Operation = if (search) .search else .enumerate;
        if (cap.operation != op or !cap.workspace_id.eql(r.context.bound_workspace) or !std.meta.eql(cap.task_id, r.context.bound_task) or !std.mem.eql(u8, &cap.policy_digest, &r.context.policy_digest) or cap.handle == .none) return error.OutOfScope;
        const snap = try r.authority(op, cap.path, cancel);
        var grant = try r.options.work_budget.reserve(r.context, .{ .scratch_bytes = r.options.caps.defaultBytes(), .fds = @intCast(r.options.caps.max_depth + 4), .cpu_permits = 1 });
        defer r.options.work_budget.release(&grant) catch unreachable;
        var a = memory.ReservedAllocator.init(r.allocator, &grant, r.options.work_budget.counters, null);
        var walker = try fs.Traverser.init(a.allocator(), snap.root, r.context.bound_workspace, r.options.caps);
        defer walker.deinit();
        walker.trusted_excludes = r.options.trusted_excludes;
        var coverage = if (search) try walker.enumerateSearchCandidates(r.io, cap, spec, sink, cancel) else try walker.enumerate(r.io, cap, spec, sink, cancel);
        _ = try r.authority(op, cap.path, cancel);
        try cancel.check();
        coverage.index_state = r.index.snapshot().state;
        // Coverage.reasons is backed by Traverser storage; callers retain only
        // static reason strings copied through this Runtime-owned array below.
        if (coverage.reasons.len > r.reasons.len or coverage.scope.len > r.scope.len) return error.ResourceExhausted;
        const count = coverage.reasons.len;
        @memcpy(r.reasons[0..count], coverage.reasons[0..count]);
        coverage.reasons = r.reasons[0..count];
        @memcpy(r.scope[0..coverage.scope.len], coverage.scope);
        coverage.scope = r.scope[0..coverage.scope.len];
        return .{ .coverage = coverage, .report = walker.report() };
    }
    /// Exclusive teardown: stop/join all callers and callback borrowers first.
    /// Busy is a misuse defense, not a concurrent destruction barrier.
    pub fn deinit(r: *Runtime) core.CacheError!void {
        if (!r.operation.tryLock()) return error.Busy;
        if (r.started) r.backend.stop(r.io);
        const a = r.allocator;
        const budget = r.budget;
        var reservation = r.control;
        a.destroy(r);
        budget.counters.recordFree(@sizeOf(Runtime));
        budget.release(&reservation) catch unreachable;
    }
    comptime {
        core.conforms(core.InvalidateFn(Runtime), Runtime.invalidate);
    }
};
fn validate(io: Io, registry: *workspace.Registry, authorizer: *policy.Authorizer, context: core.SessionContext, boot: core.Uuid, operation: core.Operation, path: core.RelativePath) core.ReadError!workspace.Snapshot {
    registry.validateSession(context, boot) catch return error.OutOfScope;
    const snap = registry.snapshot(context.bound_workspace) catch return error.OutOfScope;
    const root_id = try policy.paths.statHandle(authorizer.root.dir.handle);
    if (root_id.identity.device != snap.root_id.device or root_id.identity.inode != snap.root_id.inode or !authorizer.workspace_id.eql(context.bound_workspace) or !std.meta.eql(authorizer.task_id, context.bound_task) or !std.mem.eql(u8, &authorizer.policy.digest, &context.policy_digest)) return error.OutOfScope;
    _ = try authorizer.authorize(io, context, operation, path);
    return snap;
}
