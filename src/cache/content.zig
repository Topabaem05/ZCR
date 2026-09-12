//! T13 immutable cache. Only content/domain keys are shared. Every hit revalidates
//! its bound session and hashes the current rooted file. Pins own immutable
//! storage until explicit unpin; no cache lock is held over filesystem I/O.
const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const workspace = @import("zcr_workspace");
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const lines = @import("lines.zig");
pub const association = @import("association.zig");
pub const AccessKind = enum { interactive, bulk_scan };
pub const AdmissionResult = enum { probation, admitted, shared, bypassed };
pub const max_entries = 32;
pub const max_associations = 64;
pub const max_pins = 128;
pub const max_probation = 64;
pub const verification_scratch_bytes = 16 * core.limits.KiB;
pub const Options = struct {
    /// Existing shared inflight budget, never an independently synthesized cap.
    verification_budget: *memory.Budget,
    max_entries: usize = 16,
    max_associations: usize = 32,
    max_pins: usize = 64,
    max_probation: usize = 32,
    max_file_bytes: u64 = 8 * core.limits.MiB,
};
pub const Stats = struct { content_bytes: u64 = 0, control_bytes: u64 = 0, entries: usize = 0, associations: usize = 0, pins: usize = 0, probation: usize = 0, active_calls: usize = 0 };
const ContentKey = struct { domain: core.SecurityDomain, hash: core.ContentHash };
const Content = struct {
    state: enum { empty, loading, ready } = .empty,
    key: ContentKey = undefined,
    block: []align(@alignOf(lines.Checkpoint)) u8 = undefined,
    bytes: []const u8 = undefined,
    checkpoints: []const lines.Checkpoint = undefined,
    reservation: core.Reservation = undefined,
    pins: usize = 0,
    touched: u64 = 0,
};
const Pin = struct { id: u64 = 0, owner: core.SessionContext = undefined, entry: usize = 0, association_slot: usize = 0 };
const Touch = struct { occupied: bool = false, key: ContentKey = undefined, touched: u64 = 0 };

pub const Store = struct {
    allocator: Allocator,
    io: Io,
    budget: *memory.Budget,
    funding: core.SessionContext,
    options: Options,
    control: core.Reservation,
    mutex: Io.Mutex = .init,
    contents: [max_entries]Content = @splat(.{}),
    associations: [max_associations]association.Entry = @splat(.{}),
    pins: [max_pins]Pin = @splat(.{}),
    probation: [max_probation]Touch = @splat(.{}),
    next_pin: u64 = 1,
    clock: u64 = 0,
    content_bytes: u64 = 0,
    active_calls: usize = 0,

    /// All fixed table capacity, paths, token slots and Store itself are reserved
    /// and allocated as one control object. Options may narrow the hard caps.
    pub fn create(a: Allocator, io: Io, budget: *memory.Budget, funding: core.SessionContext, options: Options) core.ReadError!*Store {
        if (options.max_entries == 0 or options.max_entries > max_entries or options.max_associations == 0 or options.max_associations > max_associations or
            options.max_pins == 0 or options.max_pins > max_pins or options.max_probation == 0 or options.max_probation > max_probation or
            options.max_file_bytes == 0 or options.max_file_bytes > 8 * core.limits.MiB) return error.InvalidArgument;
        var nonce: [8]u8 = undefined;
        io.randomSecure(&nonce) catch return error.IoFailure;
        var control = try budget.reserve(funding, .{ .scratch_bytes = @sizeOf(Store) });
        errdefer budget.release(&control) catch unreachable;
        const s = try a.create(Store);
        budget.counters.recordAlloc(@sizeOf(Store));
        s.* = .{ .allocator = a, .io = io, .budget = budget, .funding = funding, .options = options, .control = control, .next_pin = (std.mem.readInt(u64, &nonce, .little) >> 1) + 1 };
        return s;
    }
    fn lock(s: *Store) void {
        s.mutex.lockUncancelable(s.io);
    }
    fn unlock(s: *Store) void {
        s.mutex.unlock(s.io);
    }
    fn tick(s: *Store) u64 {
        s.clock +|= 1;
        return s.clock;
    }
    fn begin(s: *Store) core.CacheError!void {
        s.lock();
        defer s.unlock();
        if (s.active_calls == max_pins) return error.Busy;
        s.active_calls += 1;
    }
    fn end(s: *Store) void {
        s.lock();
        defer s.unlock();
        s.active_calls -= 1;
    }
    /// Exclusive teardown: stop new callers first. Busy leaves everything intact.
    pub fn deinit(s: *Store) core.CacheError!void {
        s.lock();
        if (s.active_calls != 0) {
            s.unlock();
            return error.Busy;
        }
        for (s.pins[0..s.options.max_pins]) |pin| if (pin.id != 0) {
            s.unlock();
            return error.Busy;
        };
        s.unlock();
        _ = s.evict(0);
        const a = s.allocator;
        const budget = s.budget;
        var control = s.control;
        a.destroy(s);
        budget.counters.recordFree(@sizeOf(Store));
        budget.release(&control) catch unreachable;
    }
    pub fn stats(s: *Store) Stats {
        s.lock();
        defer s.unlock();
        var result: Stats = .{ .content_bytes = s.content_bytes, .control_bytes = s.control.bytes, .active_calls = s.active_calls };
        for (s.contents[0..s.options.max_entries]) |e| if (e.state == .ready) {
            result.entries += 1;
        };
        for (s.associations[0..s.options.max_associations]) |e| if (e.occupied) {
            result.associations += 1;
        };
        for (s.pins[0..s.options.max_pins]) |p| if (p.id != 0) {
            result.pins += 1;
        };
        for (s.probation[0..s.options.max_probation]) |e| if (e.occupied) {
            result.probation += 1;
        };
        return result;
    }
    fn find(s: *Store, key: ContentKey) ?usize {
        for (s.contents[0..s.options.max_entries], 0..) |e, i| if (e.state != .empty and std.meta.eql(e.key, key)) return i;
        return null;
    }
    fn freeSlot(s: *Store) ?usize {
        for (s.contents[0..s.options.max_entries], 0..) |e, i| if (e.state == .empty) return i;
        return null;
    }
    /// Release only unpinned ready entries. Loading entries and pinned pointers
    /// survive pressure. Returns bytes actually freed, including checkpoints.
    pub fn evict(s: *Store, target_bytes: u64) u64 {
        var freed: u64 = 0;
        while (true) {
            s.lock();
            if (s.content_bytes <= target_bytes) {
                s.unlock();
                return freed;
            }
            var selected: ?usize = null;
            for (s.contents[0..s.options.max_entries], 0..) |e, i| {
                if (e.state != .ready or e.pins != 0) continue;
                if (selected == null or e.touched < s.contents[selected.?].touched) selected = i;
            }
            const i = selected orelse {
                s.unlock();
                return freed;
            };
            var old = s.contents[i];
            s.contents[i] = .{};
            s.content_bytes -= old.reservation.bytes;
            for (s.associations[0..s.options.max_associations]) |*a| {
                if (a.occupied and a.key.domain.id == old.key.domain.id and std.mem.eql(u8, &a.key.hash, &old.key.hash) and a.pins == 0) a.* = .{};
            }
            s.unlock();
            s.allocator.free(old.block);
            s.budget.counters.recordFree(old.reservation.bytes);
            freed += old.reservation.bytes;
            s.budget.release(&old.reservation) catch unreachable;
        }
    }
    /// Trusted invalidation discards mutable links, never outstanding pins.
    pub fn invalidateWorkspace(s: *Store, id: core.WorkspaceId) void {
        s.lock();
        defer s.unlock();
        for (s.associations[0..s.options.max_associations]) |*a| {
            if (!a.occupied or !a.key.workspace.eql(id)) continue;
            a.valid = false;
            if (a.pins == 0) a.* = .{};
        }
    }
    fn associate(s: *Store, key: association.Key, path: []const u8) core.CacheError!usize {
        var candidate: ?usize = null;
        for (s.associations[0..s.options.max_associations], 0..) |*a, i| {
            if (a.matches(key, path)) {
                a.touched = s.tick();
                return i;
            }
            if (a.occupied and a.key.workspace.eql(key.workspace) and a.key.generation != key.generation) {
                a.valid = false;
                if (a.pins == 0) a.* = .{};
            }
            if (a.pins != 0) continue;
            if (candidate == null or !a.occupied or a.touched < s.associations[candidate.?].touched) candidate = i;
        }
        const i = candidate orelse return error.ResourceExhausted;
        const a = &s.associations[i];
        a.* = .{ .occupied = true, .valid = true, .key = key, .path_len = path.len, .touched = s.tick() };
        @memcpy(a.path[0..path.len], path);
        return i;
    }
    /// A bounded metadata-only probation ring prevents first reads from filling
    /// the hot cache. No source bytes are retained until a second valid touch.
    fn secondTouch(s: *Store, key: ContentKey) bool {
        var candidate: usize = 0;
        for (s.probation[0..s.options.max_probation], 0..) |*touch, i| {
            if (touch.occupied and std.meta.eql(touch.key, key)) {
                touch.* = .{};
                return true;
            }
            if (!touch.occupied or touch.touched < s.probation[candidate].touched) candidate = i;
        }
        s.probation[candidate] = .{ .occupied = true, .key = key, .touched = s.tick() };
        return false;
    }
};

pub const Session = struct {
    store: *Store,
    registry: *workspace.Registry,
    authorizer: *policy.Authorizer,
    context: core.SessionContext,
    boot: core.Uuid,
    cancel: core.Cancel,

    /// Trusted launcher constructs this facade from an existing registry binding.
    /// Registry, Authorizer, cancellation storage and Store outlive all calls.
    pub fn init(s: *Store, r: *workspace.Registry, a: *policy.Authorizer, c: core.SessionContext, cancel: core.Cancel) core.ReadError!Session {
        var result: Session = .{ .store = s, .registry = r, .authorizer = a, .context = c, .boot = r.bootNonce(), .cancel = cancel };
        _ = try result.authority(null);
        return result;
    }
    fn authority(self: *Session, cap: ?core.Capability) core.ReadError!workspace.Snapshot {
        try self.cancel.check();
        self.registry.validateSession(self.context, self.boot) catch return error.OutOfScope;
        const snap = self.registry.snapshot(self.context.bound_workspace) catch return error.OutOfScope;
        const root_id = policy.paths.statHandle(self.authorizer.root.dir.handle) catch return error.OutOfScope;
        if (root_id.identity.device != snap.root_id.device or root_id.identity.inode != snap.root_id.inode or
            !self.authorizer.workspace_id.eql(self.context.bound_workspace) or !std.meta.eql(self.authorizer.task_id, self.context.bound_task) or
            !std.mem.eql(u8, &self.authorizer.policy.digest, &self.context.policy_digest)) return error.OutOfScope;
        if (cap) |c| {
            if (c.handle == .none or !c.workspace_id.eql(self.context.bound_workspace) or !std.meta.eql(c.task_id, self.context.bound_task) or
                !std.mem.eql(u8, &c.policy_digest, &self.context.policy_digest)) return error.OutOfScope;
            if (c.operation != .read and c.operation != .batch_read and c.operation != .search) return error.OutOfScope;
            _ = try self.authorizer.authorize(self.store.io, self.context, c.operation, c.path);
        }
        return snap;
    }
    const Verified = struct { key: association.Key, file: association.Fingerprint };
    fn verify(self: *Session, cap: core.Capability) core.ReadError!Verified {
        const s = self.store;
        const snap = try self.authority(cap);
        var reservation = try s.options.verification_budget.reserve(self.context, .{ .scratch_bytes = verification_scratch_bytes, .fds = 3, .cpu_permits = 1 });
        defer s.options.verification_budget.release(&reservation) catch unreachable;
        const scratch = try s.allocator.alloc(u8, verification_scratch_bytes);
        s.options.verification_budget.counters.recordAlloc(scratch.len);
        defer {
            s.allocator.free(scratch);
            s.options.verification_budget.counters.recordFree(verification_scratch_bytes);
        }
        const file = try association.verify(s.io, snap.root.dir, cap.path.bytes, s.options.max_file_bytes, scratch, self.cancel);
        const after = try self.authority(cap);
        if (after.generation != snap.generation) return error.VersionConflict;
        return .{ .file = file, .key = .{ .workspace = self.context.bound_workspace, .generation = snap.generation, .file_id = file.file_id, .domain = self.context.security_domain, .hash = file.hash } };
    }
    pub fn observe(self: *Session, cap: core.Capability, bytes: []const u8, version: core.FileVersion, kind: AccessKind) core.ReadError!AdmissionResult {
        const s = self.store;
        try s.begin();
        defer s.end();
        _ = try self.authority(cap);
        if (kind == .bulk_scan) return .bypassed;
        if (bytes.len > s.options.max_file_bytes or bytes.len != version.size or version.sha256 == null or !version.workspace_id.eql(self.context.bound_workspace)) return error.InvalidArgument;
        if (std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes)) return error.Unsupported;
        const verified = try self.verify(cap);
        if (!std.mem.eql(u8, &verified.file.hash, &version.sha256.?) or !std.meta.eql(verified.file.file_id, version.file_id) or verified.key.generation != version.generation) return error.VersionConflict;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var hashed: usize = 0;
        while (hashed < bytes.len) {
            try self.cancel.check();
            const end = @min(bytes.len, hashed + verification_scratch_bytes);
            hasher.update(bytes[hashed..end]);
            hashed = end;
        }
        const digest = hasher.finalResult();
        if (!std.mem.eql(u8, &digest, &verified.file.hash)) return error.VersionConflict;
        const key: ContentKey = .{ .domain = self.context.security_domain, .hash = digest };
        s.lock();
        if (s.find(key)) |i| {
            if (s.contents[i].state == .loading) {
                s.unlock();
                return error.Busy;
            }
            _ = s.associate(verified.key, cap.path.bytes) catch |err| {
                s.unlock();
                return err;
            };
            s.contents[i].touched = s.tick();
            s.unlock();
            return .shared;
        }
        if (!s.secondTouch(key)) {
            s.unlock();
            return .probation;
        }
        s.unlock();
        // Only eviction/lookup are serialized; allocation and content copying do
        // not hold the cache mutex. Loading slots prevent duplicate allocation.
        s.lock();
        if (s.find(key) != null) {
            s.unlock();
            return error.Busy;
        }
        var slot = s.freeSlot();
        s.unlock();
        if (slot == null) {
            _ = s.evict(0);
        }
        s.lock();
        slot = s.freeSlot();
        if (s.find(key) != null) {
            s.unlock();
            return error.Busy;
        }
        const index = slot orelse {
            s.unlock();
            return error.ResourceExhausted;
        };
        s.contents[index] = .{ .state = .loading, .key = key };
        s.unlock();
        var published = false;
        defer if (!published) {
            s.lock();
            s.contents[index] = .{};
            s.unlock();
        };
        const n = lines.count(bytes);
        const text_start = n * @sizeOf(lines.Checkpoint);
        const charge = @max(1, text_start + bytes.len);
        var reservation = s.budget.reserve(s.funding, .{ .scratch_bytes = charge }) catch |err| blk: {
            if (err != error.ResourceExhausted) return err;
            _ = s.evict(0);
            break :blk try s.budget.reserve(s.funding, .{ .scratch_bytes = charge });
        };
        errdefer s.budget.release(&reservation) catch unreachable;
        const block = try s.allocator.alignedAlloc(u8, .of(lines.Checkpoint), charge);
        s.budget.counters.recordAlloc(charge);
        errdefer {
            s.allocator.free(block);
            s.budget.counters.recordFree(charge);
        }
        const checkpoints = @as([*]lines.Checkpoint, @ptrCast(block.ptr))[0..n];
        const copied = block[text_start..][0..bytes.len];
        @memcpy(copied, bytes);
        lines.build(copied, checkpoints);
        try self.cancel.check();
        const final_authority = try self.authority(cap);
        if (final_authority.generation != verified.key.generation) return error.VersionConflict;
        s.lock();
        defer s.unlock();
        _ = try s.associate(verified.key, cap.path.bytes);
        s.contents[index] = .{ .state = .ready, .key = key, .block = block, .bytes = copied, .checkpoints = checkpoints, .reservation = reservation, .touched = s.tick() };
        s.content_bytes += charge;
        published = true;
        return .admitted;
    }
    /// I13 cannot represent cancellation, file or version errors. Its optimization
    /// wrapper fails closed to a miss; callers must recheck Cancel before fallback.
    /// Runtime dispatchers needing precise reasons should use cacheGetChecked.
    pub fn cacheGet(self: *Session, hash: core.ContentHash, cap: core.Capability, pin_budget: core.PinBudget) core.CacheError!?core.PinnedEntry {
        return self.cacheGetChecked(hash, cap, pin_budget) catch |err| return switch (err) {
            error.OutOfScope, error.PathEscape, error.OutOfMemory, error.ResourceExhausted, error.Busy, error.OutputBudgetExceeded => |e| e,
            else => null,
        };
    }
    pub fn cacheGetChecked(self: *Session, hash: core.ContentHash, cap: core.Capability, pin_budget: core.PinBudget) core.ReadError!?core.PinnedEntry {
        const s = self.store;
        try s.begin();
        defer s.end();
        const verified = try self.verify(cap);
        if (!std.mem.eql(u8, &verified.file.hash, &hash)) return null;
        s.lock();
        defer s.unlock();
        const i = s.find(.{ .domain = self.context.security_domain, .hash = hash }) orelse return null;
        const entry = &s.contents[i];
        if (entry.state != .ready) return null;
        var pinned: u64 = 0;
        var free: ?usize = null;
        for (s.pins[0..s.options.max_pins], 0..) |p, j| {
            if (p.id == 0) {
                if (free == null) free = j;
                continue;
            }
            if (std.meta.eql(p.owner, self.context)) pinned += s.contents[p.entry].reservation.bytes;
        }
        if (entry.reservation.bytes > pin_budget.max_pinned_bytes -| pinned) return error.ResourceExhausted;
        const pin_slot = free orelse return error.ResourceExhausted;
        if (s.next_pin == std.math.maxInt(u64)) return error.ResourceExhausted;
        const assoc = try s.associate(verified.key, cap.path.bytes);
        const id = s.next_pin;
        s.next_pin += 1;
        s.pins[pin_slot] = .{ .id = id, .owner = self.context, .entry = i, .association_slot = assoc };
        entry.pins += 1;
        entry.touched = s.tick();
        s.associations[assoc].pins += 1;
        return .{ .hash = hash, .bytes = entry.bytes, .pin_id = id };
    }
    fn pinSlot(self: *Session, pin: core.PinnedEntry) core.CacheError!usize {
        for (self.store.pins[0..self.store.options.max_pins], 0..) |p, i| {
            if (p.id == 0 or p.id != pin.pin_id or !std.meta.eql(p.owner, self.context)) continue;
            const entry = &self.store.contents[p.entry];
            if (!std.mem.eql(u8, &entry.key.hash, &pin.hash) or entry.bytes.ptr != pin.bytes.ptr or entry.bytes.len != pin.bytes.len) return error.OutOfScope;
            return i;
        }
        return error.OutOfScope;
    }
    /// Unpin remains available after session revocation/cancellation to drain
    /// existing lifetimes; it never grants a new pointer or authority.
    pub fn unpin(self: *Session, pin: core.PinnedEntry) core.CacheError!void {
        const s = self.store;
        s.lock();
        defer s.unlock();
        const i = try self.pinSlot(pin);
        const p = s.pins[i];
        s.contents[p.entry].pins -= 1;
        const assoc = &s.associations[p.association_slot];
        assoc.pins -= 1;
        if (!assoc.valid and assoc.pins == 0) assoc.* = .{};
        s.pins[i] = .{};
    }
    /// Borrow the immutable index for the lifetime of this pin. The holder must
    /// not unpin concurrently with using its bytes or checkpoints.
    pub fn lineIndex(self: *Session, pin: core.PinnedEntry) core.CacheError![]const lines.Checkpoint {
        const s = self.store;
        s.lock();
        defer s.unlock();
        const i = try self.pinSlot(pin);
        return s.contents[s.pins[i].entry].checkpoints;
    }
    comptime {
        core.conforms(core.CacheGetFn(Session), Session.cacheGet);
    }
};
