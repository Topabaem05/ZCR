const std = @import("std");
pub const core = @import("zcr_core");
pub const policy = @import("zcr_policy");
pub const memory = @import("zcr_memory");
pub const workspace = @import("zcr_workspace");
pub const storage = @import("zcr_storage");
pub const edit = @import("zcr_fs_edit");
pub const io = std.testing.io;
pub const A = std.testing.allocator;
pub const approved: core.Policy = .{ .digest = @splat(9), .state = .active, .read_paths = &.{.{ .bytes = "." }}, .write_paths = &.{.{ .bytes = "." }}, .immutable_paths = &.{}, .operations = &.{ .read, .patch, .create }, .max_changed_files = 32 };
pub const task: core.TaskContext = .{ .task_id = .{ .uuid = @splat(4) }, .base_commit = "0123456789012345678901234567890123456789", .scope_digest = approved.digest, .fence = 1, .expires_at_unix_ms = std.math.maxInt(i64) };
pub var transcript: ?std.Io.File = null;
pub const key = "crash-operation";
pub const size = 768 * 1024;
pub fn content(a: std.mem.Allocator, new: bool) ![]u8 {
    const bytes = try a.alloc(u8, size);
    @memset(bytes, if (new) 'N' else 'O');
    return bytes;
}
pub const Manifest = struct { role: enum { writer, recovery }, point: u8, create: bool, root: []const u8, state: []const u8, namespace: ?storage.Namespace = null, kill_recovery: bool = false, history: bool = false };
pub const Hello = struct { store_root_id: core.FileId, namespace: storage.Namespace, current: core.WorkspaceId, boot: core.Uuid };
pub const Ack = struct { point: u8, store: core.Uuid, receipt_id: ?core.ReceiptId, prepared: ?core.PreparedRecord, digest: core.Sha256 };
pub const Result = struct { committed: u64, aborted: u64, uncertain: u64, receipt: ?core.Receipt, origin: ?storage.receipts.Origin, sequence: u32 };
pub const HistoryResult = struct { committed: u64, aborted: u64, uncertain: u64, receipts: [2]core.Receipt, sequences: [2]u32 };
pub fn send(fd: std.posix.fd_t, comptime T: type, value: T) !void {
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(buf[4..]);
    try std.json.Stringify.value(value, .{}, &w);
    std.mem.writeInt(u32, buf[0..4], @intCast(w.end), .little);
    var at: usize = 0;
    while (at < w.end + 4) {
        const n = std.c.write(fd, buf[at .. w.end + 4].ptr, w.end + 4 - at);
        if (n <= 0) return error.ProtocolWrite;
        at += @intCast(n);
    }
}
fn read(fd: std.posix.fd_t, bytes: []u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 30_000) != 1) return error.ProtocolTimeout;
        const n = std.c.read(fd, bytes[at..].ptr, bytes.len - at);
        if (n <= 0) return error.ProtocolClosed;
        at += @intCast(n);
    }
}
pub fn receive(fd: std.posix.fd_t, comptime T: type, a: std.mem.Allocator) !std.json.Parsed(T) {
    var buf: [64 * 1024]u8 = undefined;
    try read(fd, buf[0..4]);
    const len = std.mem.readInt(u32, buf[0..4], .little);
    if (len == 0 or len > buf.len - 4) return error.ProtocolLength;
    try read(fd, buf[4..][0..len]);
    if (transcript) |file| {
        var at: usize = 0;
        while (at < len + 4) {
            const n = std.c.write(file.handle, buf[at..].ptr, len + 4 - at);
            if (n <= 0) return error.TranscriptWrite;
            at += @intCast(n);
        }
    }
    return std.json.parseFromSlice(T, a, buf[4..][0..len], .{ .allocate = .alloc_always });
}
pub fn git(a: std.mem.Allocator, root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "/usr/bin/git", "-C", root });
    try argv.appendSlice(a, args);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    const result = try std.process.run(a, io, .{ .argv = argv.items, .environ_map = &env });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}
pub const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    root: core.TrustedRoot,
    state: core.TrustedRoot,
    registry: workspace.Registry,
    identity: workspace.identity.Identity,
    session: core.SessionContext,
    authorizer: policy.Authorizer,
    counters: memory.accounting.Counters = .{},
    allocations: memory.accounting.Counters = .{},
    budget: memory.Budget,
    reservation: core.Reservation,
    reserved: memory.ReservedAllocator,
    store: storage.Store,
    adapter: storage.Adapter,
    cancel: std.atomic.Value(bool) = .init(false),
    old: []u8,
    new: []u8,
    create: bool,
    lease: ?core.WriterLease = null,
    pub fn init(root_path: []const u8, state_path: []const u8, create: bool, namespace: ?storage.Namespace) !*Fixture {
        const self = try A.create(Fixture);
        errdefer A.destroy(self);
        self.* = .{ .arena = .init(A), .root = undefined, .state = undefined, .registry = undefined, .identity = undefined, .session = undefined, .authorizer = undefined, .budget = undefined, .reservation = undefined, .reserved = undefined, .store = undefined, .adapter = undefined, .old = undefined, .new = undefined, .create = create };
        // Every step that succeeds is undone if a later one fails, so a refused
        // store (for example on an unsupported platform) leaks nothing.
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.root = .{ .dir = try std.Io.Dir.openDirAbsolute(io, root_path, .{}), .canonical_path = root_path };
        errdefer self.root.dir.close(io);
        self.state = .{ .dir = try std.Io.Dir.openDirAbsolute(io, state_path, .{ .iterate = true }), .canonical_path = state_path };
        errdefer self.state.dir.close(io);
        self.registry = try workspace.Registry.init(a, io, .{ .git_executable = "/usr/bin/git" });
        errdefer self.registry.deinit() catch {};
        const id = try self.registry.registerWorkspace(io, self.root, approved);
        self.session = .{ .session_id = .{ .uuid = @splat(7) }, .security_domain = .{ .id = 1 }, .policy_digest = approved.digest, .bound_workspace = id, .bound_task = task.task_id, .capability_handle = @enumFromInt(1) };
        try self.registry.bindSession(self.session, task, self.registry.bootNonce());
        const snapshot = try self.registry.snapshot(id);
        self.identity = try workspace.identity.discover(a, io, "/usr/bin/git", self.root);
        errdefer self.identity.deinit(io);
        self.authorizer = try policy.Authorizer.init(a, io, snapshot.root, id, task.task_id, approved, snapshot.git);
        self.budget = memory.Budget.init(1, .{ .bytes = 96 * core.limits.MiB, .fds = 64, .cpu = 1, .output_bytes = 8 * core.limits.MiB }, &self.counters);
        self.reservation = try self.budget.reserve(self.session, .{ .scratch_bytes = 24 * core.limits.MiB, .fds = 12 });
        errdefer self.budget.release(&self.reservation) catch {};
        self.reserved = memory.ReservedAllocator.init(A, &self.reservation, &self.allocations, null);
        self.old = try content(a, false);
        self.new = try content(a, true);
        const ns = namespace orelse storage.Namespace.fromIdentity(&self.identity, self.session, @splat(12));
        self.store = try storage.Store.init(.{ .allocator = a, .io = io, .root = self.state, .namespace = ns, .budget = &self.budget, .session = self.session, .create = namespace == null });
        errdefer self.store.deinit();
        self.adapter = try storage.Adapter.init(&self.store, task.task_id, key, self.digest());
        return self;
    }
    pub fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.budget.release(&self.reservation) catch unreachable;
        self.identity.deinit(io);
        self.registry.deinit() catch unreachable;
        self.state.dir.close(io);
        self.root.dir.close(io);
        self.arena.deinit();
        A.destroy(self);
    }
    pub fn digest(self: *Fixture) core.Sha256 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        field(&h, if (self.create) "zcr/write-operation/1/create" else "zcr/write-operation/1/patch");
        field(&h, "file.txt");
        if (!self.create) h.update(&storage.receipts.hash(self.old));
        number(&h, @intFromEnum(core.Durability.durable));
        if (!self.create) {
            number(&h, 1);
            number(&h, 0);
            number(&h, size);
        }
        field(&h, self.new);
        return h.finalResult();
    }
    pub fn run(self: *Fixture, fault: ?*edit.Fault) !core.Receipt {
        return self.runKey(key, fault);
    }
    pub fn runKey(self: *Fixture, operation_key: []const u8, fault: ?*edit.Fault) !core.Receipt {
        try self.registry.setManagedWrite(self.session.bound_workspace, true);
        var lease = self.lease orelse try self.registry.acquireWriter(task, self.session.bound_workspace);
        self.lease = lease;
        var editor = edit.Editor.init(.{ .allocator = self.reserved.allocator(), .reservation = &self.reservation, .registry = &self.registry, .authorizer = &self.authorizer, .session = self.session, .journal = self.adapter.interface(), .cancel = .{ .requested = &self.cancel } });
        editor.fault = fault;
        const cap = try self.authorizer.authorize(io, self.session, if (self.create) .create else .patch, .{ .bytes = "file.txt" });
        if (self.create) return editor.createFile(io, cap, &lease, .{ .path = .{ .bytes = "file.txt" }, .content = self.new, .idempotency_key = operation_key, .durability = .durable });
        return editor.applyPatch(io, cap, &lease, .{ .path = .{ .bytes = "file.txt" }, .expected_sha256 = storage.receipts.hash(self.old), .replacements = &.{.{ .span = .{ .start = 0, .end = size }, .text = self.new }}, .idempotency_key = operation_key, .durability = .durable });
    }
};
fn number(h: *std.crypto.hash.sha2.Sha256, n: u64) void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, n, .little);
    h.update(&b);
}
fn field(h: *std.crypto.hash.sha2.Sha256, b: []const u8) void {
    number(h, b.len);
    h.update(b);
}
