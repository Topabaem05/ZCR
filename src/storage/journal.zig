//! Bounded per-operation append journals. Store and returned receipts live until
//! deinit; terminal entries are never evicted and cap pressure refuses new work.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const workspace = @import("zcr_workspace");
const Io = std.Io;
const A = std.mem.Allocator;
const E = core.JournalError;
pub const receipts = @import("receipts.zig");
pub const recovery = @import("recovery.zig");
pub const max_entries = 10_000;
pub const max_storage_bytes = 128 * 1024 * 1024;
pub const max_frames = 16;
// Reserve one bounded forensic suffix for each possible append sequence.
pub const operation_credit = (max_frames * 2) * receipts.max_frame_bytes;
pub const Namespace = struct {
    store_id: core.Uuid,
    workspace_id: core.WorkspaceId,
    security_domain: core.SecurityDomain,
    policy_digest: core.PolicyDigest,
    root_id: core.FileId,
    git_dir_id: core.FileId,
    common_dir_id: core.FileId,
    marker_id: core.FileId,
    marker_hash: ?core.Sha256,
    root_path: []const u8,
    git_path: []const u8,
    common_path: []const u8,
    head: []const u8,
    pub fn fromIdentity(id: *const workspace.identity.Identity, session: core.SessionContext, store_id: core.Uuid) Namespace {
        return .{ .store_id = store_id, .workspace_id = session.bound_workspace, .security_domain = session.security_domain, .policy_digest = session.policy_digest, .root_id = id.root_id, .git_dir_id = id.git_dir_id, .common_dir_id = id.common_dir_id, .marker_id = id.marker.id, .marker_hash = id.marker.hash, .root_path = id.root.canonical_path, .git_path = id.git.git_dir.?, .common_path = id.git.common_dir.?, .head = id.head[0..id.head_len] };
    }
    pub fn digest(self: Namespace) E!core.Sha256 {
        var buffer: [receipts.max_frame_bytes]u8 = undefined;
        return receipts.hash(try receipts.encode(Namespace, self, &buffer));
    }
};
pub const Caps = struct { entries: u32 = max_entries, storage_bytes: u64 = max_storage_bytes };
pub const Stage = enum { before_prepared, partial_prepared, partial_committed, partial_recovery, after_append };
pub const Fault = struct {
    context: ?*anyopaque = null,
    stage: ?*const fn (?*anyopaque, Stage) void = null,
    fail_write_state: ?core.JournalState = null,
    fail_sync_state: ?core.JournalState = null,
    short_writes: bool = false,
};
pub const Options = struct {
    allocator: A,
    io: Io,
    root: core.TrustedRoot,
    namespace: Namespace,
    budget: *memory.Budget,
    session: core.SessionContext,
    create: bool = false,
    caps: Caps = .{},
};
pub const Entry = struct {
    next: ?*Entry = null,
    credit: core.Reservation,
    name: [64:0]u8,
    file_id: core.FileId = .{ .device = 0, .inode = 0 },
    prepared: ?core.PreparedRecord = null,
    receipt: ?core.Receipt = null,
    state: core.JournalState = .uncertain,
    origin: receipts.Origin = .live,
    reason: @FieldType(receipts.Frame, "reason") = .ordinary,
    sequence: u32 = 0,
    digest: core.Sha256 = @splat(0),
    valid_bytes: u64 = 0,
    disk_bytes: u64 = 0,
    torn: bool = false,
    created_unix_ms: i64 = 0,
    key_buffer: [128]u8 = undefined,
    path_buffer: [4096]u8 = undefined,
    temp_buffer: [41:0]u8 = undefined,
    fn install(self: *Entry, f: receipts.Frame) void {
        var p = f.prepared;
        if (p.key.idempotency_key.ptr != &self.key_buffer) @memcpy(self.key_buffer[0..p.key.idempotency_key.len], p.key.idempotency_key);
        if (p.path.bytes.ptr != &self.path_buffer) @memcpy(self.path_buffer[0..p.path.bytes.len], p.path.bytes);
        if (p.publication.?.temp_name.ptr != &self.temp_buffer) @memcpy(self.temp_buffer[0..41], p.publication.?.temp_name);
        self.temp_buffer[41] = 0;
        p.key.idempotency_key = self.key_buffer[0..p.key.idempotency_key.len];
        p.path.bytes = self.path_buffer[0..p.path.bytes.len];
        p.publication.?.temp_name = &self.temp_buffer;
        self.prepared = p;
        self.receipt = f.receipt;
        if (self.receipt) |*r| r.idempotency_key = p.key.idempotency_key;
        self.state = f.state;
        self.origin = f.origin;
        self.reason = f.reason;
        self.sequence = f.sequence;
        self.created_unix_ms = f.created_unix_ms;
    }
};
pub const Store = struct {
    options: Options,
    namespace_digest: core.Sha256,
    root_id: core.FileId,
    reservation: core.Reservation,
    head: ?*Entry = null,
    count: u32 = 0,
    disk_bytes: u64 = 0,
    obligated_bytes: u64 = 0,
    mutex: Io.Mutex = .init,
    failed: bool = false,
    fault: if (builtin.is_test) ?*Fault else void = if (builtin.is_test) null else {},
    pub fn init(options: Options) E!Store {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.Unsupported;
        if (options.caps.entries == 0 or options.caps.entries > max_entries or options.caps.storage_bytes > max_storage_bytes or options.caps.storage_bytes < receipts.max_frame_bytes) return error.InvalidArgument;
        try validateNamespace(options.namespace);
        const path = options.root.canonical_path;
        if (!std.fs.path.isAbsolute(path) or inside(path, options.namespace.root_path) or inside(path, options.namespace.git_path) or inside(path, options.namespace.common_path)) return error.InvalidArgument;
        const meta = try metadata(options.root.dir.handle, true);
        if (meta.mode != 0o700 or meta.uid != std.c.geteuid()) return error.RecoveryRequired;
        try privateState(options.root.dir.handle);
        var credit = options.budget.reserve(options.session, .{ .parser_bytes = 192 * 1024, .fds = 4 }) catch return error.ResourceExhausted;
        errdefer options.budget.release(&credit) catch {};
        var self: Store = .{ .options = options, .namespace_digest = try options.namespace.digest(), .root_id = meta.id, .reservation = credit };
        errdefer self.freeEntries();
        try self.validateRoot();
        const header = self.openFile("namespace", false) catch |err| blk: {
            if (err != error.NotFound or !options.create) return err;
            // All caps and namespace checks precede creation. From here on any
            // uncertain write outcome is an integrity/filesystem error.
            const file = try self.createFile("namespace");
            errdefer file.close(options.io);
            var buffer: [receipts.max_frame_bytes]u8 = undefined;
            const bytes = try receipts.encode(Namespace, options.namespace, &buffer);
            try writeAt(file, options.io, bytes, 0, false);
            try sync(file.handle);
            try sync(options.root.dir.handle);
            break :blk file;
        };
        defer header.close(options.io);
        var bytes: [receipts.max_frame_bytes]u8 = undefined;
        const meta_header = try metadata(header.handle, false);
        if (meta_header.size > bytes.len) return error.RecoveryRequired;
        try readAt(header, options.io, bytes[0..@intCast(meta_header.size)], 0);
        if (!std.meta.eql(receipts.hash(bytes[0..@intCast(meta_header.size)]), self.namespace_digest)) return error.RecoveryRequired;
        self.disk_bytes = meta_header.size;
        try self.scan();
        return self;
    }
    pub fn deinit(self: *Store) void {
        self.freeEntries();
        self.options.budget.release(&self.reservation) catch unreachable;
    }
    fn freeEntries(self: *Store) void {
        var node = self.head;
        while (node) |entry| {
            node = entry.next;
            self.options.budget.release(&entry.credit) catch unreachable;
            self.options.allocator.destroy(entry);
        }
        self.head = null;
    }
    pub fn validateRoot(self: *Store) E!void {
        const m = try metadata(self.options.root.dir.handle, true);
        if (!std.meta.eql(m.id, self.root_id) or m.mode != 0o700 or m.uid != std.c.geteuid()) return error.RecoveryRequired;
        try privateState(self.options.root.dir.handle);
        const current = Io.Dir.openDirAbsolute(self.options.io, self.options.root.canonical_path, .{ .follow_symlinks = false, .iterate = true }) catch return error.RecoveryRequired;
        defer current.close(self.options.io);
        if (!std.meta.eql((try metadata(current.handle, true)).id, self.root_id)) return error.RecoveryRequired;
        var path: [4096]u8 = undefined;
        const len = current.realPath(self.options.io, &path) catch return error.IoFailure;
        if (!std.mem.eql(u8, path[0..len], self.options.root.canonical_path)) return error.RecoveryRequired;
    }
    fn openFile(self: *Store, name: [:0]const u8, writable: bool) E!Io.File {
        const expected = policy.paths.statAt(self.options.root.dir.handle, name) catch return error.RecoveryRequired;
        if (expected == null) return error.NotFound;
        if (expected.?.kind != .regular) return error.RecoveryRequired;
        const fd = std.posix.openatZ(self.options.root.dir.handle, name, .{ .ACCMODE = if (writable) .RDWR else .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return error.RecoveryRequired;
        const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(self.options.io);
        const meta = try metadata(fd, false);
        if (meta.mode != 0o600 or meta.uid != std.c.geteuid() or !sameId(meta.id, expected.?.identity)) return error.RecoveryRequired;
        try privateState(fd);
        return file;
    }
    fn createFile(self: *Store, name: [:0]const u8) E!Io.File {
        const fd = std.posix.openatZ(self.options.root.dir.handle, name, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0o600) catch return error.IoFailure;
        const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(self.options.io);
        const meta = try metadata(fd, false);
        const named = policy.paths.statAt(self.options.root.dir.handle, name) catch return error.RecoveryRequired;
        if (named == null or !sameId(meta.id, named.?.identity) or meta.mode != 0o600 or meta.uid != std.c.geteuid()) return error.RecoveryRequired;
        try privateState(fd);
        return file;
    }
    fn allocateEntry(self: *Store, name: [64]u8) E!*Entry {
        if (self.count >= self.options.caps.entries or self.obligated_bytes + operation_credit + receipts.max_frame_bytes > self.options.caps.storage_bytes) return error.ResourceExhausted;
        var credit = self.options.budget.reserve(self.options.session, .{ .journal_bytes = @sizeOf(Entry) }) catch return error.ResourceExhausted;
        errdefer self.options.budget.release(&credit) catch {};
        const entry = try self.options.allocator.create(Entry);
        entry.* = .{ .credit = credit, .name = undefined, .next = self.head };
        @memcpy(entry.name[0..64], &name);
        entry.name[64] = 0;
        self.head = entry;
        self.count += 1;
        self.obligated_bytes += operation_credit;
        return entry;
    }
    fn scan(self: *Store) E!void {
        var iterator = self.options.root.dir.iterate();
        var scanned: usize = 0;
        while (iterator.next(self.options.io) catch return error.IoFailure) |item| {
            if (std.mem.eql(u8, item.name, "namespace")) continue;
            scanned += 1;
            if (scanned > max_entries * (max_frames + 1)) return error.RecoveryRequired;
            const forensic = item.name.len == 72 and std.mem.eql(u8, item.name[64..70], ".tail-");
            if (forensic) {
                const sequence = std.fmt.parseInt(u8, item.name[70..72], 16) catch return error.RecoveryRequired;
                if (sequence == 0 or sequence > max_frames) return error.RecoveryRequired;
                for (item.name[70..72]) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.RecoveryRequired;
            }
            const name = if (forensic) item.name[0..64] else item.name;
            if (name.len != 64 or item.kind != .file) return error.RecoveryRequired;
            for (name) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.RecoveryRequired;
            var z: [73:0]u8 = undefined;
            @memcpy(z[0..item.name.len], item.name);
            z[item.name.len] = 0;
            const file = try self.openFile(z[0..item.name.len :0], false);
            defer file.close(self.options.io);
            const meta = try metadata(file.handle, false);
            if (meta.size > operation_credit or self.disk_bytes + meta.size > self.options.caps.storage_bytes) return error.RecoveryRequired;
            self.disk_bytes += meta.size;
            if (forensic) continue;
            const entry = try self.allocateEntry(name[0..64].*);
            entry.file_id = meta.id;
            entry.disk_bytes = meta.size;
            try self.load(entry, file);
        }
    }
    fn load(self: *Store, entry: *Entry, file: Io.File) E!void {
        const initial = try metadata(file.handle, false);
        var buffer: [receipts.max_frame_bytes]u8 = undefined;
        var parser: [128 * 1024]u8 = undefined;
        while (entry.valid_bytes < entry.disk_bytes) {
            const remaining = entry.disk_bytes - entry.valid_bytes;
            if (remaining < receipts.header_bytes) {
                entry.torn = true;
                break;
            }
            try readAt(file, self.options.io, buffer[0..receipts.header_bytes], entry.valid_bytes);
            const len = try receipts.length(buffer[0..receipts.header_bytes]);
            if (len > remaining) {
                entry.torn = true;
                break;
            }
            try readAt(file, self.options.io, buffer[0..len], entry.valid_bytes);
            var fba = std.heap.FixedBufferAllocator.init(&parser);
            const parsed = try receipts.decode(receipts.Frame, fba.allocator(), buffer[0..len]);
            defer parsed.deinit();
            const frame = parsed.value;
            self.validatePrepared(frame.prepared) catch return error.RecoveryRequired;
            if (!std.meta.eql(frame.store_id, self.options.namespace.store_id) or !std.meta.eql(frame.namespace_digest, self.namespace_digest) or frame.sequence != entry.sequence + 1 or frame.sequence > max_frames or !std.meta.eql(frame.previous, entry.digest) or !std.mem.eql(u8, &try receipts.keyName(frame.prepared.key), entry.name[0..64])) return error.RecoveryRequired;
            if (entry.prepared) |prior| {
                if (!try preparedEqual(prior, frame.prepared)) return error.RecoveryRequired;
                try validTransition(entry.state, frame.state);
                if (frame.created_unix_ms != entry.created_unix_ms) return error.RecoveryRequired;
                if (entry.receipt) |prior_receipt| {
                    const next_receipt = frame.receipt orelse return error.RecoveryRequired;
                    if (next_receipt.generation != prior_receipt.generation or next_receipt.applied != prior_receipt.applied or (prior_receipt.durable and !next_receipt.durable) or frame.origin != entry.origin) return error.RecoveryRequired;
                } else if (frame.origin == .recovered and frame.state != .applied) return error.RecoveryRequired;
            } else if (frame.state != .prepared or frame.sequence != 1 or frame.receipt != null) return error.RecoveryRequired;
            if (frame.receipt) |r| {
                checkReceipt(frame.prepared, r) catch return error.RecoveryRequired;
                if ((frame.state == .applied or frame.state == .committed) and !r.applied) return error.RecoveryRequired;
                if (frame.state == .aborted and (r.applied or r.error_code == null)) return error.RecoveryRequired;
                if (frame.state == .committed and (r.error_code != null or ((frame.prepared.publication.?.durability != .process) != r.durable))) return error.RecoveryRequired;
            } else if (frame.state != .prepared and frame.state != .uncertain) return error.RecoveryRequired;
            entry.install(frame);
            entry.digest = receipts.hash(buffer[0..len]);
            entry.valid_bytes += len;
        }
        if (entry.disk_bytes == 0) entry.torn = true;
        if (!initial.same(try metadata(file.handle, false))) return error.RecoveryRequired;
    }
    pub fn find(self: *Store, key: core.JournalKey) E!?*Entry {
        const name = try receipts.keyName(key);
        var node = self.head;
        while (node) |entry| : (node = entry.next) if (std.mem.eql(u8, &name, entry.name[0..64])) {
            if (entry.prepared) |p| if (!receipts.sameKey(key, p.key)) return error.RecoveryRequired;
            return entry;
        };
        return null;
    }
    fn validatePrepared(self: *Store, p: core.PreparedRecord) E!void {
        const ns = self.options.namespace;
        const publication = p.publication orelse return error.InvalidArgument;
        policy.paths.validate(p.path.bytes) catch return error.InvalidArgument;
        if (std.mem.eql(u8, p.path.bytes, ".") or !receipts.validKey(p.key.idempotency_key) or !receipts.validTemp(publication.temp_name) or p.generation == 0 or publication.fence == 0 or !publication.workspace_id.eql(ns.workspace_id) or !std.meta.eql(publication.root_id, ns.root_id) or p.key.security_domain.id != ns.security_domain.id or !std.meta.eql(p.key.workspace_incarnation, ns.workspace_id.incarnation) or (p.old_hash == null) != (publication.old_file_id == null)) return error.InvalidArgument;
        var parts = std.mem.splitScalar(u8, p.path.bytes, '/');
        while (parts.next()) |part| if (std.mem.eql(u8, part, ".git") or std.mem.startsWith(u8, part, ".zcr-tmp-")) return error.InvalidArgument;
    }
    fn stage(self: *Store, value: Stage) void {
        if (builtin.is_test) if (self.fault) |f| if (f.stage) |call| call(f.context, value);
    }
    pub fn append(self: *Store, entry: *Entry, state: core.JournalState, receipt: ?core.Receipt, origin: receipts.Origin, reason: @FieldType(receipts.Frame, "reason"), recovering: bool) E!void {
        if (entry.sequence >= max_frames or entry.torn) return error.RecoveryRequired;
        const p = entry.prepared orelse return error.RecoveryRequired;
        if (entry.sequence > 0) try validTransition(entry.state, state);
        if (receipt) |r| try checkReceipt(p, r);
        var buffer: [receipts.max_frame_bytes]u8 = undefined;
        const frame: receipts.Frame = .{ .store_id = self.options.namespace.store_id, .namespace_digest = self.namespace_digest, .sequence = entry.sequence + 1, .previous = entry.digest, .state = state, .prepared = p, .receipt = receipt, .origin = origin, .reason = reason, .created_unix_ms = entry.created_unix_ms };
        const bytes = receipts.encode(receipts.Frame, frame, &buffer) catch return error.RecoveryRequired;
        if (self.disk_bytes + bytes.len > self.options.caps.storage_bytes) return error.RecoveryRequired;
        try self.validateRoot();
        if (state == .prepared) self.stage(.before_prepared);
        const file = if (entry.sequence == 0) try self.createFile(&entry.name) else try self.openFile(&entry.name, true);
        defer file.close(self.options.io);
        const before = try metadata(file.handle, false);
        if (entry.sequence > 0 and (!std.meta.eql(before.id, entry.file_id) or before.size != entry.valid_bytes)) return error.RecoveryRequired;
        entry.file_id = before.id;
        errdefer {
            entry.torn = true;
            self.failed = true;
        }
        const split = receipts.header_bytes + (bytes.len - receipts.header_bytes - receipts.checksum_bytes) / 2;
        const short = if (builtin.is_test) if (self.fault) |f| f.short_writes else false else false;
        try writeAt(file, self.options.io, bytes[0..split], entry.valid_bytes, short);
        if (recovering) self.stage(.partial_recovery) else if (state == .prepared) self.stage(.partial_prepared) else if (state == .committed) self.stage(.partial_committed);
        if (builtin.is_test) if (self.fault) |f| if (f.fail_write_state == state) return error.IoFailure;
        try writeAt(file, self.options.io, bytes[split..], entry.valid_bytes + split, short);
        if (builtin.is_test) if (self.fault) |f| if (f.fail_sync_state == state) return error.DurabilityFailed;
        try sync(file.handle);
        if (entry.sequence == 0) try sync(self.options.root.dir.handle);
        const after = try metadata(file.handle, false);
        const named = policy.paths.statAt(self.options.root.dir.handle, &entry.name) catch return error.RecoveryRequired;
        if (!std.meta.eql(after.id, before.id) or after.size != entry.valid_bytes + bytes.len or named == null or !sameId(after.id, named.?.identity)) return error.RecoveryRequired;
        entry.install(frame);
        entry.digest = receipts.hash(bytes);
        entry.valid_bytes += bytes.len;
        entry.disk_bytes = entry.valid_bytes;
        self.disk_bytes += bytes.len;
        self.stage(.after_append);
    }
    /// Preserve a torn final suffix before removing it from the active chain.
    /// A complete corrupt frame never reaches this method.
    pub fn preserveTail(self: *Store, entry: *Entry) E!void {
        if (!entry.torn) return;
        if (entry.prepared == null) return error.RecoveryRequired;
        const file = try self.openFile(&entry.name, true);
        defer file.close(self.options.io);
        const meta = try metadata(file.handle, false);
        if (!std.meta.eql(meta.id, entry.file_id) or meta.size != entry.disk_bytes or meta.size - entry.valid_bytes >= receipts.max_frame_bytes) return error.RecoveryRequired;
        var suffix: [receipts.max_frame_bytes]u8 = undefined;
        const len: usize = @intCast(meta.size - entry.valid_bytes);
        try readAt(file, self.options.io, suffix[0..len], entry.valid_bytes);
        var name: [72:0]u8 = undefined;
        @memcpy(name[0..64], entry.name[0..64]);
        @memcpy(name[64..70], ".tail-");
        @memcpy(name[70..72], &std.fmt.bytesToHex([_]u8{@intCast(entry.sequence + 1)}, .lower));
        name[72] = 0;
        const backup = self.createFile(&name) catch |err| blk: {
            if (err != error.IoFailure) return err;
            const existing = try self.openFile(&name, false);
            errdefer existing.close(self.options.io);
            var old: [receipts.max_frame_bytes]u8 = undefined;
            if ((try metadata(existing.handle, false)).size != len) return error.RecoveryRequired;
            try readAt(existing, self.options.io, old[0..len], 0);
            if (!std.mem.eql(u8, old[0..len], suffix[0..len])) return error.RecoveryRequired;
            break :blk existing;
        };
        defer backup.close(self.options.io);
        if ((try metadata(backup.handle, false)).size == 0) {
            try writeAt(backup, self.options.io, suffix[0..len], 0, false);
        }
        // A previous recovery can die after writing the backup but before its
        // sync. Re-establish both persistence barriers even when bytes match.
        try sync(backup.handle);
        try sync(self.options.root.dir.handle);
        if (std.c.ftruncate(file.handle, @intCast(entry.valid_bytes)) != 0) return error.IoFailure;
        try sync(file.handle);
        entry.disk_bytes = entry.valid_bytes;
        entry.torn = false;
    }
};

/// One request, one full namespace/key/digest. No mutable last-request binding.
pub const Adapter = struct {
    store: *Store,
    key: core.JournalKey,
    expected_digest: core.Sha256,
    pub fn init(store: *Store, task: core.TaskId, key: []const u8, digest: core.Sha256) E!Adapter {
        if (!receipts.validKey(key)) return error.InvalidArgument;
        return .{ .store = store, .key = .{ .security_domain = store.options.namespace.security_domain, .workspace_incarnation = store.options.namespace.workspace_id.incarnation, .task_id = task, .idempotency_key = key }, .expected_digest = digest };
    }
    pub fn interface(self: *Adapter) core.JournalStore {
        return .{ .context = self, .vtable = &vtable };
    }
    pub const vtable: core.JournalStore.VTable = .{ .prepare = prepare, .record = record, .lookup = lookup, .transition = transition };
    fn get(context: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(context));
    }
    fn lookup(context: *anyopaque, key: core.JournalKey) E!core.JournalResult {
        const self = get(context);
        if (!receipts.sameKey(self.key, key)) return error.InvalidArgument;
        self.store.mutex.lockUncancelable(self.store.options.io);
        defer self.store.mutex.unlock(self.store.options.io);
        try self.store.validateRoot();
        if (try self.store.find(key)) |entry| {
            const p = entry.prepared orelse return error.RecoveryRequired;
            if (!std.meta.eql(p.op_digest, self.expected_digest)) return .{ .conflict = p.op_digest };
            if (entry.torn or entry.state == .uncertain) return error.RecoveryRequired;
            if (entry.state == .committed or entry.state == .aborted) return .{ .found = entry.receipt orelse return error.RecoveryRequired };
            return error.Busy;
        }
        if (self.store.failed) return error.RecoveryRequired;
        return .absent;
    }
    fn prepare(context: *anyopaque, p: core.PreparedRecord) E!core.JournalResult {
        const self = get(context);
        if (!receipts.sameKey(self.key, p.key) or !std.meta.eql(self.expected_digest, p.op_digest)) return error.InvalidArgument;
        try self.store.validatePrepared(p);
        self.store.mutex.lockUncancelable(self.store.options.io);
        defer self.store.mutex.unlock(self.store.options.io);
        if (self.store.failed) return error.RecoveryRequired;
        if (try self.store.find(p.key)) |entry| {
            const prior = entry.prepared orelse return error.RecoveryRequired;
            if (!std.meta.eql(prior.op_digest, p.op_digest)) return .{ .conflict = prior.op_digest };
            if (entry.torn or entry.state == .uncertain) return error.RecoveryRequired;
            if (entry.state == .committed or entry.state == .aborted) return .{ .found = entry.receipt.? };
            return error.Busy;
        }
        var pending = self.store.head;
        while (pending) |other| : (pending = other.next) {
            if (other.prepared) |prior| {
                if (std.mem.eql(u8, prior.path.bytes, p.path.bytes) and other.state != .committed and other.state != .aborted) return error.Busy;
            } else return error.RecoveryRequired;
        }
        // Allocation/admission failure is side-effect-free. Append errors after
        // exclusive creation are never relabeled Busy/resource/contract.
        const entry = try self.store.allocateEntry(try receipts.keyName(p.key));
        entry.install(.{ .store_id = self.store.options.namespace.store_id, .namespace_digest = self.store.namespace_digest, .sequence = 0, .previous = @splat(0), .state = .prepared, .prepared = p, .created_unix_ms = @intCast(@divTrunc(Io.Clock.real.now(self.store.options.io).nanoseconds, std.time.ns_per_ms)) });
        self.store.append(entry, .prepared, null, .live, .ordinary, false) catch |err| {
            self.store.failed = true;
            return persistenceError(err);
        };
        return .stored;
    }
    fn persist(self: *Adapter, receipt: core.Receipt, state: core.JournalState) E!core.JournalResult {
        if (!std.mem.eql(u8, receipt.idempotency_key, self.key.idempotency_key) or !std.meta.eql(receipt.op_digest, self.expected_digest)) return error.InvalidArgument;
        self.store.mutex.lockUncancelable(self.store.options.io);
        defer self.store.mutex.unlock(self.store.options.io);
        const entry = try self.store.find(self.key) orelse return error.InvalidArgument;
        try checkReceipt(entry.prepared orelse return error.RecoveryRequired, receipt);
        if (entry.receipt) |prior| if (prior.generation != receipt.generation or prior.applied != receipt.applied or (prior.durable and !receipt.durable)) return error.InvalidArgument;
        if (state == .committed and ((entry.prepared.?.publication.?.durability != .process) != receipt.durable)) return error.InvalidArgument;
        if (entry.state == state and entry.receipt != null and receiptEqual(entry.receipt.?, receipt)) return .stored;
        if (self.store.failed or entry.torn) return error.RecoveryRequired;
        try self.store.append(entry, state, receipt, .live, .ordinary, false);
        return .stored;
    }
    fn record(context: *anyopaque, receipt: core.Receipt) E!core.JournalResult {
        if (!receipt.applied) return error.InvalidArgument;

        return get(context).persist(receipt, if (receipt.error_code == null) .committed else .applied);
    }
    fn transition(context: *anyopaque, event: core.JournalTransition) E!core.JournalResult {
        return switch (event) {
            .applied => |r| if (r.applied) get(context).persist(r, .applied) else error.InvalidArgument,
            .aborted => |r| if (!r.applied and r.error_code != null) get(context).persist(r, .aborted) else error.InvalidArgument,
        };
    }
};
fn persistenceError(err: E) E {
    return switch (err) {
        error.OutOfMemory, error.ResourceExhausted, error.Busy, error.OutputBudgetExceeded, error.InvalidArgument, error.Unsupported, error.ManifestUnbound => error.RecoveryRequired,
        else => err,
    };
}
pub fn receiptEqual(a: core.Receipt, b: core.Receipt) bool {
    var aa = a;
    var bb = b;
    aa.idempotency_key = "";
    bb.idempotency_key = "";
    return std.meta.eql(aa, bb) and std.mem.eql(u8, a.idempotency_key, b.idempotency_key);
}
fn preparedEqual(a: core.PreparedRecord, b: core.PreparedRecord) E!bool {
    var ab: [receipts.max_frame_bytes]u8 = undefined;
    var bb: [receipts.max_frame_bytes]u8 = undefined;
    return std.mem.eql(u8, try receipts.encode(core.PreparedRecord, a, &ab), try receipts.encode(core.PreparedRecord, b, &bb));
}
fn checkReceipt(p: core.PreparedRecord, r: core.Receipt) E!void {
    if (!std.meta.eql(p.publication.?.receipt_id, r.id) or !std.mem.eql(u8, p.key.idempotency_key, r.idempotency_key) or !std.meta.eql(p.op_digest, r.op_digest) or !std.meta.eql(p.old_hash, r.old_hash) or r.new_hash == null or !std.meta.eql(p.new_hash, r.new_hash.?) or r.generation == 0 or (r.durable and !r.applied)) return error.InvalidArgument;
}
fn validTransition(from: core.JournalState, to: core.JournalState) E!void {
    const ok = switch (from) {
        .prepared => to == .applied or to == .aborted or to == .uncertain,
        .applied => to == .applied or to == .committed or to == .uncertain,
        .committed => to == .uncertain,
        .aborted => to == .uncertain,
        .uncertain => false,
    };
    if (!ok) return error.RecoveryRequired;
}
fn validateNamespace(n: Namespace) E!void {
    for ([_][]const u8{ n.root_path, n.git_path, n.common_path }) |path| if (!std.fs.path.isAbsolute(path) or path.len > 4096 or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArgument;
    if (n.head.len != 40 and n.head.len != 64) return error.InvalidArgument;
    for (n.head) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.InvalidArgument;
}
fn inside(path: []const u8, base: []const u8) bool {
    return std.mem.eql(u8, path, base) or (std.mem.startsWith(u8, path, base) and path.len > base.len and path[base.len] == '/');
}
fn sameId(a: core.FileId, b: policy.paths.Identity) bool {
    return a.device == b.device and a.inode == b.inode;
}
pub const Metadata = struct {
    id: core.FileId,
    size: u64,
    mode: u32,
    uid: u32,
    nlink: u64,
    mtime: i128,
    ctime: i128,
    pub fn same(a: Metadata, b: Metadata) bool {
        return std.meta.eql(a, b);
    }
};
const DarwinAcl = struct {
    // Public Darwin API: Libc sys/acl.h.
    extern "c" fn acl_get_fd_np(fd: c_int, kind: c_int) ?*anyopaque;
    extern "c" fn acl_free(acl: *anyopaque) c_int;
};
/// Store state is private by owner and mode. On Darwin an extended ACL can grant
/// another account access that the mode does not show, so any extended ACL on the
/// store root or a store file is treated as an outside change.
fn privateState(fd: std.posix.fd_t) E!void {
    if (builtin.os.tag != .macos) return;
    if (DarwinAcl.acl_get_fd_np(fd, 0x100)) |acl| { // ACL_TYPE_EXTENDED
        _ = DarwinAcl.acl_free(acl);
        return error.RecoveryRequired;
    }
    // Libc reports a file without an extended ACL as ENOENT.
    if (std.c.errno(@as(c_int, -1)) != .NOENT) return error.IoFailure;
}
pub fn metadata(fd: std.posix.fd_t, directory: bool) E!Metadata {
    const kind: u32 = if (directory) 0o040000 else 0o100000;
    if (builtin.os.tag == .macos) {
        // std.c selects fstat$INODE64 on Intel Darwin. The device id uses the same
        // mapping as policy.paths so journal ids compare with authorized identities.
        var s: std.c.Stat = undefined;
        if (std.c.fstat(fd, &s) != 0) return error.IoFailure;
        // BSD file flags (immutable, append-only, hidden, ...) are not state this
        // store creates, so any flag means the files were changed outside it.
        if (@as(u32, s.mode) & 0o170000 != kind or (!directory and s.nlink != 1) or s.mode & 0o7000 != 0 or s.flags != 0 or s.size < 0) return error.RecoveryRequired;
        const UnsignedDev = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(s.dev)));
        return .{ .id = .{ .device = @as(UnsignedDev, @bitCast(s.dev)), .inode = @intCast(s.ino) }, .size = @intCast(s.size), .mode = s.mode & 0o777, .uid = s.uid, .nlink = s.nlink, .mtime = @as(i128, s.mtimespec.sec) * std.time.ns_per_s + s.mtimespec.nsec, .ctime = @as(i128, s.ctimespec.sec) * std.time.ns_per_s + s.ctimespec.nsec };
    }
    if (builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;
    var s: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &s)) != .SUCCESS) return error.IoFailure;
    if (s.mode & 0o170000 != kind or (!directory and s.nlink != 1) or s.mode & 0o7000 != 0) return error.RecoveryRequired;
    return .{ .id = .{ .device = (@as(u64, s.dev_major) << 32) | s.dev_minor, .inode = s.ino }, .size = s.size, .mode = s.mode & 0o777, .uid = s.uid, .nlink = s.nlink, .mtime = @as(i128, s.mtime.sec) * std.time.ns_per_s + s.mtime.nsec, .ctime = @as(i128, s.ctime.sec) * std.time.ns_per_s + s.ctime.nsec };
}
/// Flushes a file or directory to stable storage. On Darwin `fsync` does not ask
/// the drive to flush its cache, so durable writes use `F_FULLFSYNC`; a filesystem
/// that refuses it is a durability failure, never a silent `fsync` fallback.
pub fn sync(fd: std.posix.fd_t) E!void {
    while (true) {
        const result = if (builtin.os.tag == .macos) std.c.fcntl(fd, std.c.F.FULLFSYNC) else std.c.fsync(fd);
        if (result != -1) return;
        if (std.c.errno(result) != .INTR) return error.DurabilityFailed;
    }
}
pub fn readAt(file: Io.File, io: Io, bytes: []u8, offset: u64) E!void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = file.readPositional(io, &.{bytes[at..]}, offset + at) catch return error.IoFailure;
        if (n == 0) return error.RecoveryRequired;
        at += n;
    }
}
fn writeAt(file: Io.File, io: Io, bytes: []const u8, offset: u64, short: bool) E!void {
    var at: usize = 0;
    while (at < bytes.len) {
        const end = if (short) @min(bytes.len, at + 7) else bytes.len;
        const n = file.writePositional(io, &.{bytes[at..end]}, offset + at) catch return error.IoFailure;
        if (n == 0) return error.IoFailure;
        at += n;
    }
}
