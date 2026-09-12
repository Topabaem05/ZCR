//! Explicit current-user UDS broker. All grants, roots, tokens and policies are
//! host inputs. One borrowed Budget, Executor and Store own group resources.
const std = @import("std");
const core = @import("zcr_core");
const memory = @import("zcr_memory");
const policy = @import("zcr_policy");
const workspace = @import("zcr_workspace");
const cache = @import("zcr_cache");
const executor = @import("zcr_executor");
const mcp = @import("zcr_mcp");
pub const auth = @import("auth.zig");
pub const bridge = @import("bridge.zig");
pub const max_sessions = 16;
pub const max_group_bytes = 128 * core.limits.MiB;
pub const Grant = struct {
    token: auth.Token,
    host_ceiling: core.Policy,
    config: mcp.Config,
    /// Same domain, workspace, task, authorizer and shared Store as config.
    cache_session: ?*cache.Session = null,
};
pub const Config = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    grants: []const Grant,
    budget: *memory.Budget,
    executor: *executor.Executor,
    store: *cache.Store,
    registry: *workspace.Registry,
    /// Lower than I18's 16MiB hard cap; charged before accepting each peer.
    frame_bytes: usize = 64 * 1024,
    handshake_ms: u32 = 5000,
};
pub const Stats = struct { connected: u32, authenticated: u32, refused: u64, completed: u64, backlog_bytes: u64, peak_backlog_bytes: u64 };
const Session = struct {
    server: *Server,
    fd: std.c.fd_t = -1,
    grant: ?usize = null,
    protocol: mcp.Server = undefined,
    input: []u8 = &.{},
    used: usize = 0,
    consumed: usize = 0,
    raw_len: usize = 0,
    raw: []const u8 = "",
    active_id: [2048]u8 = undefined,
    active_id_len: usize = 0,
    buffered_cancellations: BufferedCancellations = .{},
    control_backing: [control_bytes]u8 = undefined,
    control_output: []const u8 = "",
    control_at: usize = 0,
    input_eof: bool = false,
    handshake_acked: bool = false,
    connection_credit: core.Reservation = undefined,
    frame_credit: core.Reservation = undefined,
    allocation: memory.ReservedAllocator = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    has_frame: bool = false,
    // The worker publishes its last access with release; owner drains before reuse.
    job_state: std.atomic.Value(u8) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    closing: bool = false,
    output: []const u8 = "",
    output_at: usize = 0,
    output_counted: bool = false,
    emergency: [256]u8 = undefined,
    accepted_ns: i96 = 0,
};
pub const Server = struct {
    config: Config,
    listener: std.c.fd_t,
    parent: std.Io.Dir,
    endpoint: core.FileId,
    control: core.Reservation,
    sessions: [max_sessions]Session = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    connected: std.atomic.Value(u32) = .init(0),
    authenticated: std.atomic.Value(u32) = .init(0),
    refused: std.atomic.Value(u64) = .init(0),
    completed: std.atomic.Value(u64) = .init(0),
    backlog: std.atomic.Value(u64) = .init(0),
    peak_backlog: std.atomic.Value(u64) = .init(0),
    next_request: u64 = 1,
    /// Config/grants and all borrowed authority/cache/executor objects outlive
    /// serve and deinit. The allocator must be executor's concurrent allocator.
    pub fn create(config: Config) !*Server {
        if (config.grants.len == 0 or config.grants.len > max_sessions or config.frame_bytes < 1024 or config.frame_bytes > mcp.framing.max_frame_bytes or config.handshake_ms == 0 or config.handshake_ms > 5000 or
            config.budget.caps.bytes > max_group_bytes or config.budget.caps.output_bytes > 16 * core.limits.MiB or config.budget.caps.cpu != config.executor.options.cpu_permits or config.executor.budget != config.budget or config.store.budget != config.budget or config.store.options.verification_budget != config.budget or config.allocator.ptr != config.executor.allocator.ptr or config.allocator.vtable != config.executor.allocator.vtable) return error.InvalidArgument;
        for (config.grants, 0..) |g, i| {
            try auth.withinCeiling(g.config.authorizer.policy, g.host_ceiling);
            try auth.verify(g.token, g.token, g.config.session.security_domain, g.config.session.security_domain, 0, 0);
            if (g.config.budget != config.budget or g.config.validate_authority == null) return error.InvalidArgument;
            try config.registry.validateSession(g.config.session, config.registry.bootNonce());
            const snap = try config.registry.snapshot(g.config.session.bound_workspace);
            const rooted = try policy.paths.statHandle(g.config.authorizer.root.dir.handle);
            if (rooted.identity.device != snap.root_id.device or rooted.identity.inode != snap.root_id.inode) return error.OutOfScope;
            _ = try mcp.Server.init(g.config);
            if (g.cache_session) |s| if (s.store != config.store or s.registry != config.registry or s.authorizer != g.config.authorizer or !std.meta.eql(s.context, g.config.session)) return error.OutOfScope;
            for (config.grants[0..i]) |prior| if (std.crypto.timing_safe.eql(auth.Token, prior.token, g.token) or std.meta.eql(prior.config.session.session_id, g.config.session.session_id)) return error.InvalidArgument;
        }
        // Approved bridge storage is charged before clients launch/connect, not
        // only after the socket handshake. Unused grants retain their credit.
        var control = try config.budget.reserve(config.grants[0].config.session, .{ .scratch_bytes = @sizeOf(Server) + config.grants.len * bridge.charged_bytes, .parser_bytes = 64 * 1024, .output_bytes = max_sessions * (control_output_bytes + 256), .fds = @intCast(2 + config.grants.len * 3) });
        errdefer config.budget.release(&control) catch unreachable;
        const parent = try auth.privateParent(config.allocator, config.io, config.socket_path);
        errdefer parent.close(config.io);
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.IoFailure;
        errdefer _ = std.c.close(fd);
        try auth.configureSocket(fd);
        var address = try auth.address(config.socket_path);
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.AddressInUse;
        const entry = (try auth.entryAt(parent.handle, std.fs.path.basename(config.socket_path))) orelse return error.IoFailure;
        const endpoint: core.FileId = .{ .device = entry.identity.device, .inode = entry.identity.inode };
        var bound = true;
        errdefer if (bound) removeOwnedEndpoint(parent, config.io, config.socket_path, endpoint);
        var socket_path: [108:0]u8 = @splat(0);
        @memcpy(socket_path[0..config.socket_path.len], config.socket_path);
        if (std.c.chmod(&socket_path, 0o600) != 0 or std.c.listen(fd, max_sessions) != 0) return error.IoFailure;
        const final = (try auth.entryAt(parent.handle, std.fs.path.basename(config.socket_path))) orelse return error.IoFailure;
        if (final.identity.device != endpoint.device or final.identity.inode != endpoint.inode) return error.OutOfScope;
        const s = try config.allocator.create(Server);
        config.budget.counters.recordAlloc(@sizeOf(Server));
        // Do not materialize a whole Server literal on the caller stack: the
        // funded per-session control backing deliberately lives on this heap.
        s.config = config;
        s.listener = fd;
        s.parent = parent;
        s.endpoint = endpoint;
        s.control = control;
        s.stopping = .init(false);
        s.running = .init(false);
        s.connected = .init(0);
        s.authenticated = .init(0);
        s.refused = .init(0);
        s.completed = .init(0);
        s.backlog = .init(0);
        s.peak_backlog = .init(0);
        s.next_request = 1;
        for (&s.sessions) |*slot| slot.* = .{ .server = s };
        bound = false;
        return s;
    }
    pub fn snapshot(s: *Server) Stats {
        return .{ .connected = s.connected.load(.acquire), .authenticated = s.authenticated.load(.acquire), .refused = s.refused.load(.acquire), .completed = s.completed.load(.acquire), .backlog_bytes = s.backlog.load(.acquire), .peak_backlog_bytes = s.peak_backlog.load(.acquire) };
    }
    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
    }
    pub fn deinit(s: *Server) !void {
        if (s.running.load(.acquire) or s.connected.load(.acquire) != 0) return error.Busy;
        _ = std.c.close(s.listener);
        removeOwnedEndpoint(s.parent, s.config.io, s.config.socket_path, s.endpoint);
        s.parent.close(s.config.io);
        const a = s.config.allocator;
        const budget = s.config.budget;
        var credit = s.control;
        a.destroy(s);
        budget.counters.recordFree(@sizeOf(Server));
        budget.release(&credit) catch unreachable;
    }
    /// One nonblocking transport owner; filesystem callbacks use the existing
    /// global executor. No registry/global mutex spans socket I/O or flushing.
    pub fn serve(s: *Server) !void {
        if (s.running.swap(true, .acq_rel)) return error.Busy;
        defer s.running.store(false, .release);
        defer {
            for (&s.sessions) |*slot| if (slot.fd >= 0) {
                slot.closing = true;
                slot.cancel.store(true, .release);
            };
            s.config.executor.waitIdle() catch unreachable;
            for (&s.sessions) |*slot| if (slot.fd >= 0) s.closeSession(slot);
        }
        while (!s.stopping.load(.acquire)) {
            for (&s.sessions) |*slot| if (slot.fd >= 0) {
                if (slot.job_state.load(.acquire) == 2) {
                    slot.job_state.store(0, .release);
                    _ = s.completed.fetchAdd(1, .monotonic);
                    s.noteBacklog(slot.output.len);
                    slot.output_counted = true;
                    if (slot.output.len == 0) s.finishFrame(slot);
                }
                if (slot.closing and slot.job_state.load(.acquire) == 0) {
                    s.closeSession(slot);
                    continue;
                }
                if (slot.grant == null and now(s.config.io) - slot.accepted_ns >= @as(i96, s.config.handshake_ms) * std.time.ns_per_ms) {
                    s.closeSession(slot);
                    continue;
                }
                if (slot.grant != null and slot.handshake_acked) s.processControls(slot);
                if (slot.grant != null and slot.handshake_acked and slot.job_state.load(.acquire) == 0 and slot.output.len == 0 and slot.used != 0) s.dispatchBuffered(slot);
                if (slot.input_eof and slot.job_state.load(.acquire) == 0 and slot.output.len == 0 and slot.control_output.len == 0) {
                    if (slot.used == 0 or std.mem.indexOfScalar(u8, slot.input[0..slot.used], '\n') == null) s.closeSession(slot);
                }
            };
            var pollfds: [max_sessions + 1]std.c.pollfd = undefined;
            pollfds[0] = .{ .fd = s.listener, .events = std.c.POLL.IN, .revents = 0 };
            for (&s.sessions, 1..) |*slot, i| {
                var events: i16 = if (!slot.input_eof and slot.used < slot.input.len) std.c.POLL.IN else 0;
                if (slot.control_output.len != 0 or (slot.job_state.load(.acquire) == 0 and slot.output.len != 0)) events |= std.c.POLL.OUT;
                pollfds[i] = .{ .fd = slot.fd, .events = events, .revents = 0 };
            }
            const rc = std.c.poll(&pollfds, pollfds.len, 10);
            if (rc < 0) {
                if (std.posix.errno(rc) == .INTR) continue;
                return error.IoFailure;
            }
            if (pollfds[0].revents & std.c.POLL.IN != 0) s.acceptOne();
            for (&s.sessions, 1..) |*slot, i| {
                if (slot.fd < 0) continue;
                const events = pollfds[i].revents;
                if (events & (std.c.POLL.ERR | std.c.POLL.NVAL) != 0) {
                    slot.closing = true;
                    slot.cancel.store(true, .release);
                    continue;
                }
                if (events & std.c.POLL.OUT != 0) s.flush(slot);
                if (events & (std.c.POLL.IN | std.c.POLL.HUP) != 0 and !slot.input_eof and slot.used < slot.input.len) s.read(slot);
                if (events & std.c.POLL.HUP != 0) {
                    const probe = auth.send(slot.fd, "");
                    if (probe < 0 and !auth.wouldBlock(probe)) {
                        slot.closing = true;
                        slot.cancel.store(true, .release);
                    }
                }
            }
        }
    }
    fn acceptOne(s: *Server) void {
        const fd = std.c.accept(s.listener, null, null);
        if (fd < 0) return;
        auth.configureSocket(fd) catch {
            _ = std.c.close(fd);
            return;
        };
        const peer = auth.peerUid(fd) catch {
            s.refuse(fd);
            return;
        };
        if (peer != std.c.geteuid()) {
            s.refuse(fd);
            return;
        }
        var free: ?*Session = null;
        for (&s.sessions) |*slot| if (slot.fd < 0) {
            free = slot;
            break;
        };
        const slot = free orelse {
            s.refuse(fd);
            return;
        };
        var credit = s.config.budget.reserve(s.config.grants[0].config.session, .{ .input_bytes = s.config.frame_bytes + 1, .fds = 1 }) catch {
            s.refuse(fd);
            return;
        };
        const input = s.config.allocator.alloc(u8, s.config.frame_bytes + 1) catch {
            s.config.budget.release(&credit) catch unreachable;
            s.refuse(fd);
            return;
        };
        s.config.budget.counters.recordAlloc(input.len);
        slot.* = .{ .server = s, .fd = fd, .input = input, .connection_credit = credit, .accepted_ns = now(s.config.io) };
        _ = s.connected.fetchAdd(1, .monotonic);
    }
    fn refuse(s: *Server, fd: std.c.fd_t) void {
        _ = s.refused.fetchAdd(1, .monotonic);
        _ = auth.send(fd, "{\"error\":\"E_AUTH_OR_CAPACITY\"}\n");
        _ = std.c.close(fd);
    }
    fn read(s: *Server, slot: *Session) void {
        const limit = if (slot.grant == null) @min(slot.input.len, 256) else slot.input.len;
        if (slot.used == limit) {
            slot.closing = true;
            slot.cancel.store(true, .release);
            return;
        }
        const n = std.c.recv(slot.fd, slot.input[slot.used..limit].ptr, @min(4096, limit - slot.used), 0);
        if (n < 0) {
            if (auth.wouldBlock(n)) return;
            slot.closing = true;
            slot.cancel.store(true, .release);
            return;
        }
        if (n == 0) {
            slot.input_eof = true;
            return;
        }
        slot.used += @intCast(n);
        if (slot.grant == null) s.dispatchBuffered(slot) else if (slot.handshake_acked) {
            s.processControls(slot);
            if (slot.job_state.load(.acquire) == 0 and slot.output.len == 0) s.dispatchBuffered(slot);
        }
        if (slot.used == limit and std.mem.indexOfScalar(u8, slot.input[0..slot.used], '\n') == null) {
            slot.closing = true;
            slot.cancel.store(true, .release);
        }
    }
    /// At most three buffered ordinary records plus one submitted job per
    /// connection: 16 * 4 = 64 globally, below the 16-per-session hard cap.
    /// Scan control records even behind queued ordinary frames.
    fn processControls(s: *Server, slot: *Session) void {
        var at: usize = 0;
        var queued: usize = 0;
        while (at < slot.used) {
            const end = at + (std.mem.indexOfScalar(u8, slot.input[at..slot.used], '\n') orelse break);
            const raw = slot.input[at..end];
            if (controlKind(raw)) |kind| {
                if (kind == .cancel) {
                    if (slot.active_id_len != 0 and slot.job_state.load(.acquire) != 0 and cancelMatches(raw, slot.active_id[0..slot.active_id_len])) slot.cancel.store(true, .release);
                    slot.buffered_cancellations.observe(slot.input[0..at], raw) catch {
                        slot.closing = true;
                        slot.cancel.store(true, .release);
                        return;
                    };
                    removeInput(slot, at, end + 1);
                    continue;
                }
                if (slot.control_output.len == 0) {
                    slot.control_output = respondControl(&slot.protocol, &slot.control_backing, raw, .{ .requested = &s.stopping }) catch "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Control resource limit\"}}\n";
                    slot.control_at = 0;
                    s.noteBacklog(slot.control_output.len);
                    removeInput(slot, at, end + 1);
                    continue;
                }
            }
            queued += 1;
            if (queued > 3) {
                slot.closing = true;
                slot.cancel.store(true, .release);
                return;
            }
            at = end + 1;
        }
    }
    fn dispatchBuffered(s: *Server, slot: *Session) void {
        const end = std.mem.indexOfScalar(u8, slot.input[0..slot.used], '\n') orelse return;
        if (slot.grant != null and controlKind(slot.input[0..end]) != null) return;
        slot.raw_len = end;
        slot.consumed = end + 1;
        if (slot.grant == null) {
            s.authenticate(slot) catch {
                _ = s.refused.fetchAdd(1, .monotonic);
                slot.closing = true;
                return;
            };
            slot.output = "{\"zcr_broker\":1,\"authenticated\":true,\"writes\":false}\n";
            s.noteBacklog(slot.output.len);
            slot.output_counted = true;
            return;
        }
        const g = &s.config.grants[slot.grant.?];
        const already_cancelled = slot.buffered_cancellations.contains(0);
        const output_limit = @min(mcp.max_backlog_bytes - control_output_bytes, g.config.output_bytes + 2048);
        slot.frame_credit = s.config.budget.reserve(g.config.session, .{ .input_bytes = end, .parser_bytes = 65536 + end * 6, .scratch_bytes = 4 * core.limits.MiB, .output_bytes = output_limit }) catch {
            consumeInput(slot);
            s.errorResponse(slot);
            return;
        };
        slot.allocation = memory.ReservedAllocator.init(s.config.allocator, &slot.frame_credit, s.config.budget.counters, null);
        slot.arena = .init(slot.allocation.allocator());
        slot.has_frame = true;
        slot.raw = slot.arena.allocator().dupe(u8, slot.input[0..end]) catch {
            consumeInput(slot);
            s.finishAllocation(slot);
            s.errorResponse(slot);
            return;
        };
        slot.active_id_len = 0;
        if (mcp.codec.rawRequestId(slot.raw) catch null) |id| if (id.len <= slot.active_id.len) {
            @memcpy(slot.active_id[0..id.len], id);
            slot.active_id_len = id.len;
        };
        consumeInput(slot);
        submitPreparedFrame(.{
            .executor = s.config.executor,
            .budget = s.config.budget,
            .session = g.config.session,
            .saved_cancelled = already_cancelled,
            .cancel = &slot.cancel,
            .next_request = &s.next_request,
            .callback = runFrame,
            .userdata = slot,
            .protocol = &slot.protocol,
            .allocator = slot.arena.allocator(),
            .raw = slot.raw,
            .frame_limit = s.config.frame_bytes,
            .output_limit = slot.frame_credit.output,
            .job_state = &slot.job_state,
            .output = &slot.output,
        }) catch {
            s.finishAllocation(slot);
            s.errorResponse(slot);
            return;
        };
    }
    fn authenticate(s: *Server, slot: *Session) !void {
        var backing: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        const Hello = struct { zcr_broker: u8, token: []const u8, domain: u64 };
        const hello = try std.json.parseFromSlice(Hello, fba.allocator(), slot.input[0..slot.raw_len], .{ .allocate = .alloc_if_needed });
        defer hello.deinit();
        if (hello.value.zcr_broker != 1 or hello.value.token.len != 64) return error.OutOfScope;
        var supplied: auth.Token = undefined;
        _ = std.fmt.hexToBytes(&supplied, hello.value.token) catch return error.OutOfScope;
        var found: ?usize = null;
        const peer = try auth.peerUid(slot.fd);
        for (s.config.grants, 0..) |g, i| if (auth.verify(g.token, supplied, g.config.session.security_domain, .{ .id = hello.value.domain }, std.c.geteuid(), peer)) {
            found = i;
        } else |_| {};
        const index = found orelse return error.OutOfScope;
        for (&s.sessions) |*other| if (other != slot and other.fd >= 0 and other.grant == index) return error.Busy;
        const g = &s.config.grants[index];
        try s.config.registry.validateSession(g.config.session, s.config.registry.bootNonce());
        var protocol_config = g.config;
        protocol_config.max_batch_concurrency = 1;
        protocol_config.backend = .broker;
        protocol_config.cache_session = g.cache_session;
        slot.protocol = try mcp.Server.init(protocol_config);
        slot.grant = index;
        _ = s.authenticated.fetchAdd(1, .monotonic);
    }
    fn runFrame(job: *core.JobEnvelope) void {
        const slot: *Session = @ptrCast(@alignCast(job.userdata.?));
        const s = slot.server;
        var context: mcp.Server.FrameContext = .{ .allocator = slot.arena.allocator(), .cancel = job.cancel.withTimeout(s.config.io, 5000) };
        var connection: core.Connection = .{ .context = &context };
        const result = slot.protocol.serveFrame(s.config.io, &connection, .{ .bytes = slot.raw, .limit = s.config.frame_bytes }) catch {
            slot.output = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Resource exhausted\"}}\n";
            slot.job_state.store(2, .release);
            return;
        };
        if (result.bytes.len != 0) {
            if (result.bytes.len + 1 > slot.frame_credit.output) slot.output = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Output budget exceeded\"}}\n" else slot.output = std.fmt.allocPrint(slot.arena.allocator(), "{s}\n", .{result.bytes}) catch "{\"error\":\"E_RESOURCE_EXHAUSTED\"}\n";
        } else slot.output = "";
        slot.job_state.store(2, .release);
    }
    fn errorResponse(s: *Server, slot: *Session) void {
        slot.output = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Resource exhausted\"}}\n";
        s.noteBacklog(slot.output.len);
        slot.output_counted = true;
    }
    fn noteBacklog(s: *Server, bytes: usize) void {
        const current = s.backlog.fetchAdd(bytes, .monotonic) + bytes;
        var old = s.peak_backlog.load(.monotonic);
        while (current > old) {
            old = s.peak_backlog.cmpxchgWeak(old, current, .monotonic, .monotonic) orelse break;
        }
    }
    fn flush(s: *Server, slot: *Session) void {
        const is_control = slot.control_output.len != 0 and slot.output_at == 0;
        const bytes = if (is_control) slot.control_output else slot.output;
        const offset = if (is_control) slot.control_at else slot.output_at;
        const n = auth.send(slot.fd, bytes[offset..@min(bytes.len, offset + 4096)]);
        if (n <= 0) {
            if (n < 0 and auth.wouldBlock(n)) return;
            slot.closing = true;
            slot.cancel.store(true, .release);
            return;
        }
        if (is_control) {
            slot.control_at += @intCast(n);
            if (slot.control_at == bytes.len) {
                _ = s.backlog.fetchSub(bytes.len, .monotonic);
                slot.control_output = "";
                slot.control_at = 0;
            }
        } else {
            slot.output_at += @intCast(n);
            if (slot.output_at == bytes.len) {
                _ = s.backlog.fetchSub(bytes.len, .monotonic);
                slot.output_counted = false;
                slot.output = "";
                slot.output_at = 0;
                s.finishFrame(slot);
                slot.handshake_acked = true;
            }
        }
    }
    fn finishAllocation(s: *Server, slot: *Session) void {
        if (slot.has_frame) {
            finishPreparedFrame(s.config.budget, &slot.arena, &slot.frame_credit, &slot.has_frame) catch unreachable;
            slot.raw = "";
            slot.active_id_len = 0;
        }
    }
    fn finishFrame(s: *Server, slot: *Session) void {
        s.finishAllocation(slot);
        consumeInput(slot);
    }
    fn closeSession(s: *Server, slot: *Session) void {
        _ = std.c.close(slot.fd);
        if (slot.output_counted) _ = s.backlog.fetchSub(slot.output.len, .monotonic);
        if (slot.control_output.len != 0) _ = s.backlog.fetchSub(slot.control_output.len, .monotonic);
        s.finishAllocation(slot);
        if (slot.grant) |i| {
            _ = s.authenticated.fetchSub(1, .monotonic);
            s.config.registry.unbindSession(s.config.grants[i].config.session.session_id, s.config.registry.bootNonce()) catch {};
        }
        s.config.allocator.free(slot.input);
        s.config.budget.counters.recordFree(slot.input.len);
        s.config.budget.release(&slot.connection_credit) catch unreachable;
        slot.* = .{ .server = s };
        _ = s.connected.fetchSub(1, .monotonic);
    }
};
fn now(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn removeOwnedEndpoint(parent: std.Io.Dir, io: std.Io, path: []const u8, expected: core.FileId) void {
    const entry = (auth.entryAt(parent.handle, std.fs.path.basename(path)) catch return) orelse return;
    if (entry.identity.device == expected.device and entry.identity.inode == expected.inode) parent.deleteFile(io, std.fs.path.basename(path)) catch {};
}

pub const control_bytes = 512 * 1024;
pub const control_output_bytes = 64 * 1024;
pub const BufferedCancellations = struct {
    offsets: [3]?usize = @splat(null),
    pub fn observe(self: *@This(), preceding: []const u8, notification: []const u8) !void {
        var start: usize = 0;
        while (start < preceding.len) {
            const end = start + (std.mem.indexOfScalar(u8, preceding[start..], '\n') orelse break);
            const raw = preceding[start..end];
            if (controlKind(raw) == null) if (mcp.codec.rawRequestId(raw) catch null) |id| {
                if (cancelMatches(notification, id) and !self.contains(start)) {
                    var stored = false;
                    for (&self.offsets) |*item| if (item.* == null) {
                        item.* = start;
                        stored = true;
                        break;
                    };
                    if (!stored) return error.ResourceExhausted;
                }
            };
            start = end + 1;
        }
    }
    pub fn contains(self: *const @This(), offset: usize) bool {
        for (self.offsets) |item| if (item != null and item.? == offset) return true;
        return false;
    }
    pub fn remove(self: *@This(), start: usize, end: usize) void {
        for (&self.offsets) |*item| if (item.*) |offset| {
            if (offset >= end) item.* = offset - (end - start) else if (offset >= start) item.* = null;
        };
    }
};
pub fn frameJobCost() core.ResourceCost {
    return .{ .scratch_bytes = @sizeOf(core.JobEnvelope), .fds = 1 };
}
const ControlKind = enum { cancel, other };
fn controlKind(raw: []const u8) ?ControlKind {
    if (raw.len > 8192) return null;
    var backing: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const parsed = mcp.codec.parse(fba.allocator(), raw) catch return null;
    defer parsed.deinit();
    const envelope = mcp.codec.envelope(parsed.value) catch return null;
    if (std.mem.eql(u8, envelope.method, "notifications/cancelled") and envelope.id == null) return .cancel;
    for ([_][]const u8{ "initialize", "notifications/initialized", "ping", "tools/list" }) |method| if (std.mem.eql(u8, envelope.method, method)) return .other;
    if (std.mem.eql(u8, envelope.method, "tools/call")) {
        const params = envelope.params orelse return null;
        if (params != .object) return null;
        const name = params.object.get("name") orelse return null;
        if (name == .string and (std.mem.eql(u8, name.string, "zcr_health") or std.mem.eql(u8, name.string, "zcr_status"))) return .other;
    }
    return null;
}
pub fn cancelMatches(raw: []const u8, active_id: []const u8) bool {
    if (raw.len > 8192 or active_id.len > 2048) return false;
    var backing: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const parsed = mcp.codec.parse(fba.allocator(), raw) catch return false;
    defer parsed.deinit();
    const envelope = mcp.codec.envelope(parsed.value) catch return false;
    if (envelope.id != null or !std.mem.eql(u8, envelope.method, "notifications/cancelled")) return false;
    const params = envelope.params orelse return false;
    if (params != .object) return false;
    var keys = params.object.iterator();
    while (keys.next()) |entry| if (!std.mem.eql(u8, entry.key_ptr.*, "requestId") and !std.mem.eql(u8, entry.key_ptr.*, "reason") and !std.mem.eql(u8, entry.key_ptr.*, "_meta")) return false;
    if (params.object.get("reason")) |reason| if (reason != .string) return false;
    const id = mcp.codec.requestId(params.object.get("requestId") orelse return false) catch return false;
    const active = std.json.parseFromSlice(std.json.Value, fba.allocator(), active_id, .{ .parse_numbers = false }) catch return false;
    defer active.deinit();
    const candidate = mcp.codec.requestId(active.value) catch return false;
    return id.eql(candidate);
}
/// Uses only caller-retained control backing/output credit, even if ordinary
/// group admission is exhausted. No ordinary tool executes through this path.
pub fn respondControl(protocol: *mcp.Server, backing: []u8, raw: []const u8, cancel: core.Cancel) ![]const u8 {
    if (controlKind(raw) == null or backing.len < control_bytes) return error.InvalidArgument;
    var fba = std.heap.FixedBufferAllocator.init(backing[0..control_bytes]);
    const response = (try protocol.respond(fba.allocator(), raw, cancel)) orelse return "";
    if (response.len + 1 > control_output_bytes) return error.OutputBudgetExceeded;
    return std.fmt.allocPrint(fba.allocator(), "{s}\n", .{response});
}
/// Deterministic response boundary for a frame cancelled before Executor.submit
/// can transfer ownership to a worker.
pub fn cancelledSubmissionResponse(protocol: *mcp.Server, allocator: std.mem.Allocator, raw: []const u8, frame_limit: usize, output_limit: u64) ![]const u8 {
    var requested = std.atomic.Value(bool).init(true);
    var context: mcp.Server.FrameContext = .{ .allocator = allocator, .cancel = .{ .requested = &requested } };
    var connection: core.Connection = .{ .context = &context };
    const result = try protocol.serveFrame(protocol.config.io, &connection, .{ .bytes = raw, .limit = frame_limit });
    if (result.bytes.len == 0) return "";
    if (result.bytes.len + 1 > output_limit) return error.OutputBudgetExceeded;
    return std.fmt.allocPrint(allocator, "{s}\n", .{result.bytes});
}
pub const PreparedFrame = struct {
    executor: *executor.Executor,
    budget: *memory.Budget,
    session: core.SessionContext,
    saved_cancelled: bool,
    cancel: *std.atomic.Value(bool),
    next_request: *u64,
    callback: *const fn (*core.JobEnvelope) void,
    userdata: ?*anyopaque,
    protocol: *mcp.Server,
    allocator: std.mem.Allocator,
    raw: []const u8,
    frame_limit: usize,
    output_limit: u64,
    job_state: *std.atomic.Value(u8),
    output: *[]const u8,
};
/// The production saved-cancellation -> Executor.submit -> completion boundary.
/// The executor owns accepted jobs; every rejected job remains owned here.
pub fn submitPreparedFrame(frame: PreparedFrame) !void {
    var envelope_credit = try frame.budget.reserve(frame.session, frameJobCost());
    const job = frame.executor.allocator.create(core.JobEnvelope) catch |err| {
        frame.budget.release(&envelope_credit) catch unreachable;
        return err;
    };
    frame.cancel.store(frame.saved_cancelled, .release);
    job.* = .{ .request_id = frame.next_request.*, .context = frame.session, .cancel = .{ .requested = frame.cancel }, .scratch_reservation = envelope_credit, .callback = frame.callback, .qos_intent = .fg_short, .userdata = frame.userdata };
    frame.next_request.* +|= 1;
    frame.job_state.store(1, .release);
    _ = frame.executor.submit(job) catch |err| {
        frame.executor.allocator.destroy(job);
        frame.budget.release(&envelope_credit) catch unreachable;
        frame.job_state.store(0, .release);
        if (err == error.Cancelled) {
            frame.output.* = try cancelledSubmissionResponse(frame.protocol, frame.allocator, frame.raw, frame.frame_limit, frame.output_limit);
            frame.job_state.store(2, .release);
            return;
        }
        return err;
    };
}
/// Shared by normal broker completion and the deterministic transport seam.
pub fn finishPreparedFrame(budget: *memory.Budget, arena: *std.heap.ArenaAllocator, credit: *core.Reservation, has_frame: *bool) error{InvariantViolation}!void {
    if (!has_frame.*) return;
    arena.deinit();
    try budget.release(credit);
    has_frame.* = false;
}
fn removeInput(slot: *Session, start: usize, end: usize) void {
    slot.buffered_cancellations.remove(start, end);
    std.mem.copyForwards(u8, slot.input[start..], slot.input[end..slot.used]);
    slot.used -= end - start;
}
fn consumeInput(slot: *Session) void {
    removeInput(slot, 0, slot.consumed);
    slot.consumed = 0;
}
