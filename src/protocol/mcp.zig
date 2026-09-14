//! Policy-bound direct stdio MCP 2025-11-25. Source data is emitted only in
//! compact text_v1 protocol records; no logs or executable workspace settings.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const cache = @import("zcr_cache");
const fs_read = @import("zcr_fs_read");
const traverse = @import("zcr_fs_traverse");
const search = @import("zcr_search");
const batch = @import("zcr_batch_read");
const projection = @import("zcr_projection");
pub const codec = @import("codec.zig");
pub const framing = @import("framing.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Object = std.json.ObjectMap;
const MiB = 1024 * 1024;
pub const protocol_version = "2025-11-25";
pub const max_backlog_bytes = 2 * MiB;
pub const max_pending_requests = 16;
pub fn supportedVersion(version: []const u8) bool {
    return std.mem.eql(u8, version, protocol_version);
}

pub const Config = struct {
    allocator: Allocator,
    io: std.Io,
    authorizer: *policy.Authorizer,
    session: core.SessionContext,
    generation: u64 = 0,
    budget: *memory.Budget,
    /// Host-owned facade; copied for each request and retained until all requests drain.
    cache_session: ?*cache.Session = null,
    /// Trusted contracts/tools.json; lifetime includes Server's lifetime.
    tools_json: []const u8,
    version: []const u8 = "0.1.0",
    /// Lowering these limits grants no new authority.
    output_bytes: u64 = core.limits.values.max_output_bytes,
    max_search_file_bytes: u64 = core.limits.values.default_search_file_bytes,
    /// Host execution policy; may only narrow the direct adapter's two workers.
    max_batch_concurrency: u32 = 2,
    backend: enum { direct_stdio, broker } = .direct_stdio,
    /// Caller-owned trusted handles, retained until every request has drained.
    trusted_excludes: traverse.TrustedExcludes = .{},
    authority_context: ?*anyopaque = null,
    validate_authority: ?*const fn (?*anyopaque) core.AuthorizeError!void = null,
    /// Optional deterministic lifecycle fault hook; never called under a lock.
    retirement_context: ?*anyopaque = null,
    before_tool_release: ?*const fn (?*anyopaque) void = null,
    /// Optional deterministic deadline hook: called once for each request the
    /// watcher expires, after its cancellation flag is set; never called under a lock.
    deadline_context: ?*anyopaque = null,
    after_deadline_cancel: ?*const fn (?*anyopaque) void = null,
};

pub const Server = struct {
    config: Config,
    phase: std.atomic.Value(u8) = .init(0),
    sequence: std.atomic.Value(u64) = .init(1),
    pub fn init(config: Config) !Server {
        if (config.budget.caps.cpu == 0 or config.output_bytes < 1024 or config.output_bytes > core.limits.values.max_output_bytes or
            config.max_search_file_bytes == 0 or config.max_search_file_bytes > core.limits.values.max_search_file_bytes or
            config.max_batch_concurrency == 0 or config.max_batch_concurrency > 2) return error.InvalidArgument;
        if (!config.session.bound_workspace.eql(config.authorizer.workspace_id) or
            !std.mem.eql(u8, &config.session.bound_task.uuid, &config.authorizer.task_id.uuid) or
            !std.mem.eql(u8, &config.session.policy_digest, &config.authorizer.policy.digest)) return error.OutOfScope;
        if (config.cache_session) |bound| {
            if (!std.meta.eql(bound.context, config.session) or bound.authorizer != config.authorizer or
                bound.store.budget != config.budget or bound.store.options.verification_budget != config.budget) return error.OutOfScope;
            _ = try bound.currentGeneration();
        }
        return .{ .config = config };
    }

    pub fn enabled(self: *const Server, name: core.ToolName) bool {
        if (name == .zcr_patch or name == .zcr_create) return false;
        if (self.config.authorizer.policy.state != .active) return false;
        for (self.config.authorizer.policy.operations) |op| if (op == name.operation()) return true;
        return false;
    }

    /// Shared cache bytes are reclaimable request capacity. Retry the identical
    /// whole reservation once after evicting only eligible unpinned entries.
    fn reserveRequest(self: *Server, cost: core.ResourceCost) core.ReserveError!core.Reservation {
        return self.config.budget.reserve(self.config.session, cost) catch |err| {
            if (err != error.ResourceExhausted or !self.config.budget.reclaimableMemoryPressure(cost)) return err;
            const bound = self.config.cache_session orelse return err;
            _ = bound.store.evict(0);
            return self.config.budget.reserve(self.config.session, cost);
        };
    }

    /// Synchronous bounded-frame adapter. `allocator` must have a reservation
    /// covering input decoding and encoded output. Returned bytes live there.
    /// Cancellation is request-specific; stdio additionally binds a deadline.
    pub fn respond(self: *Server, allocator: Allocator, raw: []const u8, cancel: core.Cancel) !?[]const u8 {
        if (self.phase.load(.acquire) == 2) if (try self.argumentFailure(allocator, raw)) |response| return response;
        var parsed = codec.parse(allocator, raw) catch |err| return try rpcError(allocator, .null, if (err == error.ResourceExhausted or err == error.OutOfMemory) -32000 else -32700, if (err == error.ResourceExhausted or err == error.OutOfMemory) "Parser resource limit" else "Parse error");
        defer parsed.deinit();
        const root = asObject(parsed.value) catch return try rpcError(allocator, .null, -32600, "Invalid Request");
        const id = root.get("id") orelse .null;
        if (root.contains("id") and !validId(id)) return try rpcError(allocator, .null, -32600, "Invalid Request");
        const has_id = root.contains("id");
        fields(root, &.{ "jsonrpc", "id", "method", "params" }) catch return try rpcError(allocator, id, -32600, "Invalid Request");
        if (!strEq(root.get("jsonrpc") orelse .null, "2.0")) return try rpcError(allocator, id, -32600, "Invalid Request");
        const method = string(root.get("method") orelse .null) catch return try rpcError(allocator, id, -32600, "Invalid Request");
        const params = asObject(root.get("params") orelse .{ .object = .empty }) catch return if (has_id) try rpcError(allocator, id, -32602, "Invalid params") else null;
        if (std.mem.eql(u8, method, "initialize")) {
            if (!has_id) return null;
            fields(params, &.{ "protocolVersion", "capabilities", "clientInfo", "_meta" }) catch return try rpcError(allocator, id, -32602, "Invalid params");
            if (self.phase.load(.acquire) != 0) return try rpcError(allocator, id, -32600, "Already initialized");
            if (!strEq(params.get("protocolVersion") orelse .null, protocol_version)) return try rpcError(allocator, id, -32602, "Unsupported protocol version");
            _ = asObject(params.get("capabilities") orelse .null) catch return try rpcError(allocator, id, -32602, "Invalid capabilities");
            const info = asObject(params.get("clientInfo") orelse .null) catch return try rpcError(allocator, id, -32602, "Invalid clientInfo");
            _ = string(info.get("name") orelse .null) catch return try rpcError(allocator, id, -32602, "Invalid clientInfo");
            _ = string(info.get("version") orelse .null) catch return try rpcError(allocator, id, -32602, "Invalid clientInfo");
            self.phase.store(1, .release);
            return try rpcResult(allocator, id, .{ .protocolVersion = protocol_version, .capabilities = .{ .tools = .{ .listChanged = false } }, .serverInfo = .{ .name = "zcr", .version = self.config.version } });
        }
        if (std.mem.eql(u8, method, "notifications/initialized")) {
            if (has_id) return try rpcError(allocator, id, -32600, "Expected notification");
            fields(params, &.{"_meta"}) catch return null;
            if (self.phase.load(.acquire) == 1) self.phase.store(2, .release);
            return null;
        }
        if (std.mem.eql(u8, method, "notifications/cancelled")) return if (has_id) try rpcError(allocator, id, -32600, "Expected notification") else null; // session dispatcher owns the request map
        if (!has_id) return null;
        if (std.mem.eql(u8, method, "ping")) {
            fields(params, &.{"_meta"}) catch return try rpcError(allocator, id, -32602, "Invalid params");
            return try rpcResult(allocator, id, .{});
        }
        if (self.phase.load(.acquire) != 2) return try rpcError(allocator, id, -32600, "Session not initialized");
        if (std.mem.eql(u8, method, "tools/list")) {
            fields(params, &.{"_meta"}) catch return try rpcError(allocator, id, -32602, "Invalid params");
            var catalog = try std.json.parseFromSlice(Value, allocator, self.config.tools_json, .{});
            defer catalog.deinit();
            var enabled_tools: std.ArrayList(Value) = .empty;
            defer enabled_tools.deinit(allocator);
            for (catalog.value.object.get("tools").?.array.items) |tool| {
                const name = std.meta.stringToEnum(core.ToolName, tool.object.get("name").?.string) orelse continue;
                if (self.enabled(name)) try enabled_tools.append(allocator, tool);
            }
            return try rpcResult(allocator, id, .{ .tools = enabled_tools.items });
        }
        if (!std.mem.eql(u8, method, "tools/call")) return try rpcError(allocator, id, -32601, "Method not found");
        fields(params, &.{ "name", "arguments", "_meta" }) catch return try rpcError(allocator, id, -32602, "Invalid params");
        const name = string(params.get("name") orelse .null) catch return try rpcError(allocator, id, -32602, "Invalid tool name");
        const args = asObject(params.get("arguments") orelse .{ .object = .empty }) catch return try rpcError(allocator, id, -32602, "Invalid tool arguments");
        var request_buf: [64]u8 = undefined;
        const request_id = try std.fmt.bufPrint(&request_buf, "mcp-{d}", .{self.sequence.fetchAdd(1, .monotonic)});
        const envelope: projection.Envelope = .{ .request_id = request_id, .workspace_id = self.config.session.bound_workspace, .generation = self.config.generation };
        const tool = std.meta.stringToEnum(core.ToolName, name) orelse return try toolFailure(allocator, id, envelope, error.Unsupported);
        if (!self.enabled(tool)) return try toolFailure(allocator, id, envelope, error.Unsupported);
        const started = std.Io.Clock.Timestamp.now(self.config.io, .awake);
        const result = self.execute(allocator, tool, args, envelope, cancel) catch |err| return try toolFailure(allocator, id, envelope, mapError(err));
        // A task may expire or a trusted binding may change while I/O is in flight.
        if (self.config.validate_authority) |validate| validate(self.config.authority_context) catch |err| return try toolFailure(allocator, id, envelope, err);
        const elapsed = started.untilNow(self.config.io).raw.toMilliseconds();
        const deadline_ms = uint(args, "deadline_ms", 5000, 1, 60000) catch 5000;
        if (elapsed >= deadline_ms) return try toolFailure(allocator, id, envelope, error.DeadlineExceeded);
        cancel.check() catch |err| return try toolFailure(allocator, id, envelope, err);
        const encoded = try toolResult(allocator, id, result.bytes, !result.ok);
        const output_bytes = try uint(args, "output_bytes", 262144, 1024, self.config.output_bytes);
        // Output content includes the complete text block and JSON escaping.
        const content_json = try json(allocator, .{ .content = .{.{ .type = "text", .text = result.bytes }}, .isError = !result.ok });
        defer allocator.free(content_json);
        const content_size = content_json.len;
        if (content_size > output_bytes or encoded.len > max_backlog_bytes) return try toolFailure(allocator, id, envelope, error.OutputBudgetExceeded);
        return encoded;
    }

    /// Reject unsupported argument shapes before allocating their JSON DOM.
    /// Only the already-bounded RPC id is decoded on this error path.
    fn argumentFailure(self: *Server, allocator: Allocator, raw: []const u8) !?[]const u8 {
        codec.preflight(raw) catch return null;
        if (codec.toolName(raw)) |name| {
            const tool = std.meta.stringToEnum(core.ToolName, name) orelse return null;
            if (!self.enabled(tool)) return null;
        }
        codec.preflightToolArguments(raw) catch |err| {
            if (err != error.InvalidArgument and err != error.UnknownField) return null;
            const id_raw = (try codec.rawRequestId(raw)) orelse return null;
            var id = try std.json.parseFromSlice(Value, allocator, id_raw, .{ .parse_numbers = false });
            defer id.deinit();
            var request_buf: [64]u8 = undefined;
            const request_id = try std.fmt.bufPrint(&request_buf, "mcp-{d}", .{self.sequence.fetchAdd(1, .monotonic)});
            return try toolFailure(allocator, id.value, .{ .request_id = request_id, .workspace_id = self.config.session.bound_workspace, .generation = self.config.generation }, error.InvalidArgument);
        };
        return null;
    }

    fn execute(self: *Server, output_allocator: Allocator, tool: core.ToolName, args: Object, envelope: projection.Envelope, cancel: core.Cancel) !projection.Response {
        try validateArgs(tool, args);
        if (self.config.validate_authority) |validate| try validate(self.config.authority_context);
        const output_bytes = try uint(args, "output_bytes", 262144, 1024, self.config.output_bytes);
        const deadline_ms: u32 = @intCast(try uint(args, "deadline_ms", 5000, 1, 60000));
        try cancel.check();
        var control_arena = std.heap.ArenaAllocator.init(output_allocator);
        defer control_arena.deinit();
        const control = control_arena.allocator();
        if (tool == .zcr_health or tool == .zcr_status) {
            _ = try self.config.authorizer.authorize(self.config.io, self.config.session, tool.operation(), .{ .bytes = "." });
            if (tool == .zcr_status) {
                if (args.contains("receipt_id")) return error.Unsupported;
                return try diagnostic(output_allocator, envelope, try json(control, .{ .task_id = std.fmt.bytesToHex(self.config.session.bound_task.uuid, .lower), .index_state = "live", .write_mode = "read_only", .receipt = @as(?u8, null) }));
            }
            const usage = self.config.budget.usage();
            return try diagnostic(output_allocator, envelope, try json(control, .{ .build_version = self.config.version, .backend = @tagName(self.config.backend), .capabilities = .{
                .read = self.enabled(.zcr_read),
                .enumerate = self.enabled(.zcr_files),
                .search = self.enabled(.zcr_search),
                .batch_read = self.enabled(.zcr_batch_read),
                .status = self.enabled(.zcr_status),
                .health = self.enabled(.zcr_health),
                .patch = false,
                .create = false,
            }, .tracked_limit_bytes = self.config.budget.caps.bytes, .tracked_live_bytes = usage.bytes, .pressure = "unknown", .usable_cpu_permits = self.config.budget.caps.cpu }));
        }
        var items: [32]core.BatchReadItem = undefined;
        var item_count: usize = 0;
        if (tool == .zcr_batch_read) {
            const values = args.get("items").?.array.items;
            item_count = values.len;
            for (values, 0..) |value, i| items[i] = .{ .item_id = try textField(value.object, "item_id", null, 64), .spec = try readSpec(value.object, output_bytes, deadline_ms) };
        }
        // Reserve every live directory frame and transient file/parent handle.
        // Resource profiles may lower traversal depth; engines report that limit.
        const traversal_caps: traverse.Caps = .{ .max_depth = @min(core.limits.values.directory_max_depth, self.config.budget.caps.fds -| 6) };
        const traversal_fds: u16 = @intCast(traversal_caps.max_depth + 4);
        const batch_workers: u32 = @min(self.config.max_batch_concurrency, self.config.budget.caps.cpu);
        var cost: core.ResourceCost = switch (tool) {
            .zcr_read => blk: {
                const spec = try readSpec(args, output_bytes, deadline_ms);
                break :blk .{ .scratch_bytes = batch.jobBytes(output_bytes, spec.lines.count, spec.path.bytes.len) + 65536, .output_bytes = output_bytes, .fds = 3 };
            },
            .zcr_batch_read => try batch.plannedCost(items[0..item_count], output_bytes, batch_workers),
            .zcr_files => .{ .scratch_bytes = traversal_caps.defaultBytes() + 3 * (2 * output_bytes + 65536), .output_bytes = output_bytes, .fds = traversal_fds },
            .zcr_search => .{ .scratch_bytes = search.Caps.defaultBytes(.{ .output_bytes = output_bytes, .traverse = traversal_caps }) + 3 * (2 * output_bytes + 65536), .output_bytes = output_bytes, .fds = traversal_fds },
            else => unreachable,
        };
        cost.cpu_permits = @intCast(if (tool == .zcr_batch_read) batch_workers else 1);
        if (tool == .zcr_batch_read) cost.fds += 4;
        var reservation = try self.reserveRequest(cost);
        defer self.config.budget.release(&reservation) catch unreachable;
        var reserved = memory.ReservedAllocator.init(self.config.allocator, &reservation, self.config.budget.counters, null);
        var arena = std.heap.ArenaAllocator.init(reserved.allocator());
        defer arena.deinit();
        const a = arena.allocator();
        var status: core.ResultStatus = .{ .complete = true, .truncated = false, .consistency = .checked_live, .coverage = .{ .scope = "requested_files", .skipped = 0, .index_state = .live } };
        const output = try output_allocator.alloc(u8, @intCast(projection.bufferBytes(envelope, status, output_bytes) + 8192));
        var reader = fs_read.Reader.init(self.config.authorizer.root, self.config.session.bound_workspace, self.config.generation);
        switch (tool) {
            .zcr_read => {
                const spec = try readSpec(args, output_bytes, deadline_ms);
                const capability = try self.config.authorizer.authorize(self.config.io, self.config.session, .read, spec.path);
                var request_cache: ?cache.Session = if (self.config.cache_session) |bound| try bound.forRequest(self.config.budget, &reservation, &reserved, cancel.withTimeout(self.config.io, deadline_ms)) else null;
                if (request_cache) |*bound| reader.cache_session = bound;
                var result = try reader.readRange(self.config.io, reserved.allocator(), capability, spec, &reservation, cancel);
                defer result.deinit();
                var actual_envelope = envelope;
                actual_envelope.generation = result.value.version.generation;
                actual_envelope.cache = if (request_cache != null) reader.cache_result else null;
                return try projection.success(output, actual_envelope, .{ .read = result.value }, result.value.status, output_bytes);
            },
            .zcr_batch_read => {
                var batcher = batch.Batcher.init(self.config.authorizer, &reader, .{ .max_concurrency = batch_workers }, cancel);
                var result = try batcher.batchRead(self.config.io, reserved.allocator(), self.config.session, items[0..item_count], &reservation);
                defer result.deinit();
                return try projection.success(output, envelope, .{ .batch_read = result.value }, result.value.status, output_bytes);
            },
            .zcr_files => {
                var engine = try traverse.Traverser.init(reserved.allocator(), self.config.authorizer.root, self.config.session.bound_workspace, traversal_caps);
                defer engine.deinit();
                engine.trusted_excludes = self.config.trusted_excludes;
                var collector: Files = .{ .allocator = a, .server = self, .limit = output_bytes };
                const capability = try self.rootCapability(.enumerate);
                const spec = try fileSpec(args);
                status.coverage = engine.enumerate(self.config.io, capability, spec, .{ .context = &collector, .push_fn = Files.push }, cancel) catch |err| return collector.failure orelse err;
                status.complete = engine.report().complete;
                status.truncated = engine.report().truncated;
                return try projection.success(output, envelope, .{ .files = .{ .paths = collector.paths.items, .order = if (engine.report().order_fallback) .discovery else spec.order } }, status, output_bytes);
            },
            .zcr_search => {
                const caps: search.Caps = .{ .output_bytes = output_bytes, .traverse = traversal_caps };
                var engine = try search.Searcher.init(reserved.allocator(), self.config.authorizer.root, self.config.session.bound_workspace, self.config.generation, caps);
                defer engine.deinit();
                engine.traverser.trusted_excludes = self.config.trusted_excludes;
                var collector: Hits = .{ .allocator = a, .server = self, .limit = output_bytes };
                const capability = try self.rootCapability(.search);
                const spec = try searchSpec(args, self.config.max_search_file_bytes);
                status.coverage = engine.search(self.config.io, capability, spec, .{ .context = &collector, .push_fn = Hits.push }, cancel) catch |err| return collector.failure orelse err;
                status.complete = engine.report().complete;
                status.truncated = engine.report().truncated;
                return try projection.success(output, envelope, .{ .search = .{ .files = collector.files.items, .order = if (engine.report().traversal.order_fallback) .discovery else spec.order } }, status, output_bytes);
            },
            else => return error.Unsupported,
        }
    }

    fn rootCapability(self: *Server, op: core.Operation) !core.Capability {
        // The engines enforce Capability.path as their traversal start. Enumerate
        // each approved scope independently would need overlap/dedup semantics;
        // a common approved root is required for these whole-workspace tools.
        return try self.config.authorizer.authorize(self.config.io, self.config.session, op, .{ .bytes = "." });
    }

    pub const FrameContext = struct { allocator: Allocator, cancel: core.Cancel };
    pub fn serveFrame(self: *Server, _: std.Io, connection: *core.Connection, frame: core.BoundedBytes) core.ServeError!core.EncodedToolResult {
        if (frame.bytes.len > frame.limit or frame.limit > framing.max_frame_bytes) return error.InvalidArgument;
        const context: *FrameContext = @ptrCast(@alignCast(connection.context));
        const bytes = (self.respond(context.allocator, frame.bytes, context.cancel) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.IoFailure,
        }) orelse "";
        return .{ .bytes = bytes, .is_error = std.mem.indexOf(u8, bytes, "\"isError\":true") != null or std.mem.indexOf(u8, bytes, "\"error\":{") != null };
    }
    comptime {
        core.conforms(core.ServeFrameFn(Server), Server.serveFrame);
    }

    /// Starts bounded workers, a deadline watcher, and one stdout writer.
    pub fn serve(self: *Server, input: std.Io.File, output: std.Io.File) !void {
        var transport: Transport = .{ .server = self, .writer = .{ .io = self.config.io, .output = output } };
        try transport.run(input);
    }
};

fn asObject(value: Value) !Object {
    return if (value == .object) value.object else error.InvalidArgument;
}
fn string(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidArgument;
}
fn strEq(value: Value, expected: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, expected);
}
fn validId(value: Value) bool {
    return switch (value) {
        .string => |s| s.len <= 256,
        .integer => true,
        .number_string => |s| blk: {
            _ = std.fmt.parseInt(i64, s, 10) catch break :blk false;
            break :blk true;
        },
        else => false,
    };
}
fn fields(object: Object, names: []const []const u8) !void {
    for (object.keys()) |key| {
        for (names) |name| {
            if (std.mem.eql(u8, key, name)) break;
        } else return error.InvalidArgument;
    }
}
fn uint(object: Object, key: []const u8, default: u64, min: u64, max: u64) !u64 {
    const value = object.get(key) orelse return std.math.clamp(default, min, max);
    const n = codec.asUnsigned(value, max) catch return error.InvalidArgument;
    if (n < min or n > max) return error.InvalidArgument;
    return n;
}
fn textField(object: Object, key: []const u8, default: ?[]const u8, max: usize) ![]const u8 {
    const text = if (object.get(key)) |value| try string(value) else default orelse return error.InvalidArgument;
    if (text.len == 0 or text.len > max or !std.unicode.utf8ValidateSlice(text)) return error.InvalidArgument;
    return text;
}
fn boolean(object: Object, key: []const u8) !bool {
    const value = object.get(key) orelse return false;
    return if (value == .bool) value.bool else error.InvalidArgument;
}
fn consistency(object: Object) !core.RequestConsistency {
    return std.meta.stringToEnum(core.RequestConsistency, try textField(object, "consistency", "checked_live", 64)) orelse error.InvalidArgument;
}
fn order(object: Object) !core.Order {
    return std.meta.stringToEnum(core.Order, try textField(object, "order", "discovery", 64)) orelse error.InvalidArgument;
}
fn readSpec(object: Object, output: u64, deadline: u32) !core.ReadSpec {
    return .{ .path = try core.RelativePath.init(try textField(object, "path", null, 4096)), .lines = try core.LineRange.init(@intCast(try uint(object, "start_line", 1, 1, std.math.maxInt(u32))), @intCast(try uint(object, "line_count", 200, 1, 5000))), .write_intent = try boolean(object, "write_intent"), .consistency = try consistency(object), .output_bytes = output, .deadline_ms = deadline };
}
fn fileSpec(object: Object) !core.FileSpec {
    return .{ .glob = try textField(object, "glob", "**/*", 4096), .limit = @intCast(try uint(object, "limit", 1000, 1, 10000)), .include_hidden = try boolean(object, "include_hidden"), .order = try order(object), .consistency = try consistency(object), .max_stale_ms = @intCast(try uint(object, "max_stale_ms", 0, 0, 60000)) };
}
fn searchSpec(object: Object, max_file: u64) !core.SearchSpec {
    return .{ .literal = try textField(object, "literal", null, 4096), .glob = try textField(object, "glob", "**/*", 4096), .context_lines = @intCast(try uint(object, "context_lines", 2, 0, 20)), .limit = @intCast(try uint(object, "limit", 100, 1, 1000)), .max_file_bytes = try uint(object, "max_file_bytes", @min(max_file, core.limits.values.default_search_file_bytes), 1, max_file), .include_hidden = try boolean(object, "include_hidden"), .order = try order(object), .consistency = try consistency(object), .max_stale_ms = @intCast(try uint(object, "max_stale_ms", 0, 0, 60000)) };
}
fn validateArgs(tool: core.ToolName, args: Object) !void {
    switch (tool) {
        .zcr_read => {
            try fields(args, &.{ "path", "start_line", "line_count", "write_intent", "consistency", "output_bytes", "deadline_ms" });
            _ = try readSpec(args, 262144, 5000);
        },
        .zcr_files => {
            try fields(args, &.{ "glob", "limit", "include_hidden", "order", "consistency", "max_stale_ms", "output_bytes", "deadline_ms" });
            _ = try fileSpec(args);
        },
        .zcr_search => {
            try fields(args, &.{ "literal", "glob", "context_lines", "limit", "max_file_bytes", "include_hidden", "order", "consistency", "max_stale_ms", "output_bytes", "deadline_ms" });
            _ = try searchSpec(args, core.limits.values.max_search_file_bytes);
        },
        .zcr_batch_read => {
            try fields(args, &.{ "items", "output_bytes", "deadline_ms" });
            const values = args.get("items") orelse return error.InvalidArgument;
            if (values != .array or values.array.items.len == 0 or values.array.items.len > 32) return error.InvalidArgument;
            for (values.array.items, 0..) |value, i| {
                const item = try asObject(value);
                try fields(item, &.{ "item_id", "path", "start_line", "line_count", "write_intent", "consistency" });
                const id = try textField(item, "item_id", null, 64);
                _ = try readSpec(item, 262144, 5000);
                for (values.array.items[0..i]) |prior| {
                    if (strEq(prior.object.get("item_id").?, id)) return error.InvalidArgument;
                }
            }
        },
        .zcr_status => {
            try fields(args, &.{ "receipt_id", "output_bytes", "deadline_ms" });
            if (args.contains("receipt_id")) _ = try textField(args, "receipt_id", null, 128);
        },
        .zcr_health => try fields(args, &.{ "output_bytes", "deadline_ms" }),
        else => return error.Unsupported,
    }
    _ = try uint(args, "output_bytes", 262144, 1024, core.limits.values.max_output_bytes);
    _ = try uint(args, "deadline_ms", 5000, 1, 60000);
}
fn json(allocator: Allocator, value: anytype) ![]const u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}
fn rpcResult(a: Allocator, id: Value, result: anytype) ![]const u8 {
    return try json(a, .{ .jsonrpc = "2.0", .id = id, .result = result });
}
fn rpcError(a: Allocator, id: Value, code: i32, message: []const u8) ![]const u8 {
    return try json(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
}
fn toolResult(a: Allocator, id: Value, logical: []const u8, failed: bool) ![]const u8 {
    return try rpcResult(a, id, .{ .content = .{.{ .type = "text", .text = logical }}, .isError = failed });
}
fn toolFailure(a: Allocator, id: Value, envelope: projection.Envelope, err: core.errors.Error) ![]const u8 {
    const code = core.errors.wireCode(err);
    const info: core.errors.ErrorInfo = .{ .code = code, .message = @errorName(err), .retryable = core.errors.defaultRetryable(code) };
    const buffer = try a.alloc(u8, @intCast(projection.failureBufferBytes(envelope, info)));
    const result = try projection.failure(buffer, envelope, info);
    return try toolResult(a, id, result.bytes, true);
}
fn mapError(err: anyerror) core.errors.Error {
    inline for (@typeInfo(core.errors.Error).error_set.?) |entry| {
        if (std.mem.eql(u8, @errorName(err), entry.name)) return @field(core.errors.Error, entry.name);
    }
    return error.IoFailure;
}
fn diagnostic(a: Allocator, envelope: projection.Envelope, data: []const u8) !projection.Response {
    var parsed = try std.json.parseFromSlice(Value, a, data, .{});
    defer parsed.deinit();
    const bytes = try json(a, .{ .schema_version = "zcr/1", .request_id = envelope.request_id, .workspace_id = try std.fmt.allocPrint(a, "{s}:{s}", .{ std.fmt.bytesToHex(envelope.workspace_id.?.registry_uuid, .lower), std.fmt.bytesToHex(envelope.workspace_id.?.incarnation, .lower) }), .generation = envelope.generation, .ok = true, .complete = true, .truncated = false, .consistency = "not_applicable", .coverage = .{ .scope = "session", .skipped = 0, .index_state = "not_applicable" }, .data = parsed.value, .@"error" = @as(?u8, null), .meta = .{ .returned_bytes = data.len } });
    return .{ .bytes = bytes, .returned_bytes = data.len, .ok = true, .complete = true, .truncated = false, .omitted = 0 };
}
const Files = struct {
    allocator: Allocator,
    server: *Server,
    limit: u64,
    used: u64 = 0,
    paths: std.ArrayList(core.RelativePath) = .empty,
    failure: ?core.ReadError = null,
    fn push(context: *anyopaque, path: core.RelativePath) core.SinkError!void {
        const self: *Files = @ptrCast(@alignCast(context));
        _ = self.server.config.authorizer.authorize(self.server.config.io, self.server.config.session, .enumerate, path) catch |err| {
            if (err == error.OutOfScope) return;
            self.failure = err;
            return error.Cancelled;
        };
        if (self.used + path.bytes.len + 16 > self.limit) return error.OutputBudgetExceeded;
        const copy = self.allocator.dupe(u8, path.bytes) catch return error.OutputBudgetExceeded;
        self.paths.append(self.allocator, .{ .bytes = copy }) catch return error.OutputBudgetExceeded;
        self.used += path.bytes.len + 16;
    }
};
const Hits = struct {
    allocator: Allocator,
    server: *Server,
    limit: u64,
    used: u64 = 0,
    files: std.ArrayList(core.SearchFileResult) = .empty,
    failure: ?core.ReadError = null,
    fn push(context: *anyopaque, item: core.SearchFileResult) core.SinkError!void {
        const self: *Hits = @ptrCast(@alignCast(context));
        _ = self.server.config.authorizer.authorize(self.server.config.io, self.server.config.session, .search, item.path) catch |err| {
            if (err == error.OutOfScope) return;
            self.failure = err;
            return error.Cancelled;
        };
        var need: u64 = item.path.bytes.len + item.matches.len * @sizeOf(core.SearchMatch) + item.context.len * @sizeOf(core.Line);
        for (item.context) |line| need += line.text.len;
        if (self.used + need > self.limit) return error.OutputBudgetExceeded;
        const path = self.allocator.dupe(u8, item.path.bytes) catch return error.OutputBudgetExceeded;
        const matches = self.allocator.dupe(core.SearchMatch, item.matches) catch return error.OutputBudgetExceeded;
        const lines = self.allocator.dupe(core.Line, item.context) catch return error.OutputBudgetExceeded;
        for (lines) |*line| line.text = self.allocator.dupe(u8, line.text) catch return error.OutputBudgetExceeded;
        self.files.append(self.allocator, .{ .path = .{ .bytes = path }, .matches = matches, .context = lines, .version = item.version }) catch return error.OutputBudgetExceeded;
        self.used += need;
    }
};

const Slot = struct {
    state: enum { free, building, queued, running, ready, writing, retiring } = .free,
    control: bool = false,
    control_backing: []u8 = "",
    control_allocator: std.heap.FixedBufferAllocator = undefined,
    reservation: core.Reservation = undefined,
    reserved: memory.ReservedAllocator = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    raw: []const u8 = "",
    id: Value = .null,
    deadline: i128 = 0,
    output_limit: usize = 262144 + 2048,
    output_credit: usize = 0,
    cancel: std.atomic.Value(bool) = .init(false),
    expired: std.atomic.Value(bool) = .init(false),
    response: []const u8 = "",
    emergency: [8192]u8 = undefined,
    logical_id_buf: [64]u8 = undefined,
    logical_id: []const u8 = "",
};
const Transport = struct {
    const control_slot_bytes = 512 * 1024;
    server: *Server,
    writer: framing.RecordWriter,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    slots: [max_pending_requests + 4]Slot = @splat(.{}),
    input_done: bool = false,
    failed: bool = false,
    worker_done: bool = false,
    finished: std.atomic.Value(bool) = .init(false),
    backlog: usize = 0,

    fn now(t: *Transport) i128 {
        return std.Io.Clock.now(.awake, t.server.config.io).nanoseconds;
    }
    fn run(t: *Transport, input: std.Io.File) !void {
        const config = t.server.config;
        var credit = try config.budget.reserve(config.session, .{ .input_bytes = framing.max_frame_bytes, .parser_bytes = 2 * MiB, .scratch_bytes = @sizeOf(Transport) + 4 * control_slot_bytes, .output_bytes = 64 * 1024, .fds = 2 });
        defer config.budget.release(&credit) catch unreachable;
        var allocation = memory.ReservedAllocator.init(config.allocator, &credit, config.budget.counters, null);
        const buffer = try allocation.allocator().alloc(u8, framing.max_frame_bytes);
        defer allocation.allocator().free(buffer);
        const decode_buffer = try allocation.allocator().alloc(u8, 2 * MiB);
        defer allocation.allocator().free(decode_buffer);
        const control_pool = try allocation.allocator().alloc(u8, 4 * control_slot_bytes);
        defer allocation.allocator().free(control_pool);
        for (t.slots[max_pending_requests..], 0..) |*slot, i| slot.control_backing = control_pool[i * control_slot_bytes ..][0..control_slot_bytes];
        var decoder = framing.Decoder.init(buffer);
        const worker = try std.Thread.spawn(.{}, work, .{t});
        const writer = std.Thread.spawn(.{}, write, .{t}) catch |err| {
            t.mutex.lockUncancelable(config.io);
            t.input_done = true;
            t.changed.broadcast(config.io);
            t.mutex.unlock(config.io);
            worker.join();
            return err;
        };
        const watcher = std.Thread.spawn(.{}, deadlines, .{t}) catch |err| {
            t.mutex.lockUncancelable(config.io);
            t.failed = true;
            t.input_done = true;
            t.changed.broadcast(config.io);
            t.mutex.unlock(config.io);
            worker.join();
            writer.join();
            return err;
        };
        var input_error: ?anyerror = null;
        var chunk: [8192]u8 = undefined;
        reading: while (true) {
            const count = t.readInput(input, &chunk) catch |err| {
                if (err != error.EndOfStream) input_error = err;
                break;
            };
            if (count == 0) break;
            for (chunk[0..count]) |byte| switch (decoder.push(byte)) {
                .none => {},
                .oversized => t.dispatch("", decode_buffer) catch |err| {
                    input_error = err;
                    break :reading;
                },
                .frame => |raw| t.dispatch(raw, decode_buffer) catch |err| {
                    input_error = err;
                    break :reading;
                },
            };
        }
        decoder.finish() catch {
            t.dispatch("", decode_buffer) catch {};
        };
        t.mutex.lockUncancelable(config.io);
        t.input_done = true;
        t.changed.broadcast(config.io);
        t.mutex.unlock(config.io);
        worker.join();
        writer.join();
        t.finished.store(true, .release);
        watcher.join();
        // No arena or request flag dies until every child and output is drained.
        for (&t.slots) |*slot| if (slot.state != .free) t.release(slot);
        if (input_error) |err| return err;
        if (t.failed) return error.IoFailure;
    }

    /// This transport is the exclusive reader of its stdio handle. Readiness
    /// polling makes output failure observable even if the peer leaves stdin
    /// open. No global lock is held during poll or the subsequent read.
    fn readInput(t: *Transport, input: std.Io.File, bytes: []u8) !usize {
        if (comptime builtin.os.tag == .windows) return error.Unsupported;
        const io = t.server.config.io;
        while (true) {
            t.mutex.lockUncancelable(io);
            const failed = t.failed;
            t.mutex.unlock(io);
            if (failed) return error.IoFailure;
            var fds = [_]std.c.pollfd{.{ .fd = input.handle, .events = std.c.POLL.IN, .revents = 0 }};
            const ready = std.c.poll(&fds, 1, 20);
            if (ready < 0) {
                if (std.posix.errno(ready) == .INTR) continue;
                return error.IoFailure;
            }
            if (ready == 0) continue;
            if (fds[0].revents & std.c.POLL.NVAL != 0) return error.IoFailure;
            return try input.readStreaming(io, &.{bytes});
        }
    }

    fn dispatch(t: *Transport, raw: []const u8, scratch: []u8) !void {
        const io = t.server.config.io;
        var fba = std.heap.FixedBufferAllocator.init(scratch);
        if (t.server.phase.load(.acquire) == 2) if (try t.server.argumentFailure(fba.allocator(), raw)) |response| {
            const slot = try t.acquire(true, 0);
            slot.response = try slot.arena.allocator().dupe(u8, response);
            t.publish(slot);
            return;
        };
        var parsed = codec.parse(fba.allocator(), raw) catch |err| {
            const slot = try t.acquire(true, 0);
            slot.response = try rpcError(slot.arena.allocator(), .null, if (err == error.ResourceExhausted or err == error.OutOfMemory) -32000 else -32700, if (err == error.ResourceExhausted or err == error.OutOfMemory) "Parser resource limit" else "Parse error");
            t.publish(slot);
            return;
        };
        defer parsed.deinit();
        const root = if (parsed.value == .object) parsed.value.object else Object.empty;
        const method = if (root.get("method")) |value| if (value == .string) value.string else "" else "";
        const envelope = codec.envelope(parsed.value) catch null;
        if (std.mem.eql(u8, method, "notifications/cancelled") and envelope != null and envelope.?.id == null) {
            const params = asObject(root.get("params") orelse .null) catch return;
            fields(params, &.{ "requestId", "reason", "_meta" }) catch return;
            const id = codec.requestId(params.get("requestId") orelse .null) catch return;
            if (params.get("reason")) |reason| {
                _ = string(reason) catch return;
            }
            t.mutex.lockUncancelable(io);
            defer t.mutex.unlock(io);
            for (&t.slots) |*slot| {
                if (slot.state != .queued and slot.state != .running) continue;
                const candidate = codec.requestId(slot.id) catch continue;
                if (candidate.eql(id)) slot.cancel.store(true, .release);
            }
            t.changed.broadcast(io);
            return;
        }
        var diagnostic_call = false;
        if (root.get("params")) |params| if (params == .object) {
            if (params.object.get("name")) |name| diagnostic_call = strEq(name, "zcr_health") or strEq(name, "zcr_status");
        };
        const is_tool = std.mem.eql(u8, method, "tools/call") and !diagnostic_call and envelope != null and envelope.?.id != null and t.server.phase.load(.acquire) == 2;
        const slot = t.acquire(!is_tool, raw.len) catch |err| {
            if (is_tool) {
                const control = try t.acquire(true, 0);
                const id = root.get("id") orelse .null;
                var request_id_buf: [64]u8 = undefined;
                const request_id = try std.fmt.bufPrint(&request_id_buf, "mcp-{d}", .{t.server.sequence.fetchAdd(1, .monotonic)});
                control.response = try toolFailure(control.arena.allocator(), id, .{ .request_id = request_id, .workspace_id = t.server.config.session.bound_workspace, .generation = t.server.config.generation }, mapError(err));
                t.publish(control);
                return;
            }
            return err;
        };
        errdefer t.release(slot);
        slot.raw = if (is_tool) try slot.arena.allocator().dupe(u8, raw) else "";
        // The map owns id strings independently of the reusable frame buffer.
        slot.id = root.get("id") orelse .null;
        if (slot.id == .string) slot.id = .{ .string = try slot.arena.allocator().dupe(u8, slot.id.string) };
        if (slot.id == .number_string) slot.id = .{ .number_string = try slot.arena.allocator().dupe(u8, slot.id.number_string) };
        if (is_tool) {
            var deadline: u64 = 5000;
            if (root.get("params")) |params| if (params == .object) {
                if (params.object.get("arguments")) |args| if (args == .object) {
                    deadline = uint(args.object, "deadline_ms", 5000, 1, 60000) catch 5000;
                    const output_bytes = uint(args.object, "output_bytes", 262144, 1024, t.server.config.output_bytes) catch 262144;
                    slot.output_limit = @min(@as(usize, @intCast(output_bytes)) + 2048, max_backlog_bytes - 64 * 1024);
                };
            };
            t.mutex.lockUncancelable(io);
            const id = codec.requestId(slot.id) catch unreachable;
            for (&t.slots) |*other| {
                if (other == slot or (other.state != .queued and other.state != .running and other.state != .ready and other.state != .writing)) continue;
                const other_id = codec.requestId(other.id) catch continue;
                if (id.eql(other_id)) {
                    t.mutex.unlock(io);
                    slot.response = try rpcError(slot.arena.allocator(), slot.id, -32600, "Duplicate active request id");
                    t.publish(slot);
                    return;
                }
            }
            slot.deadline = t.now() + @as(i128, deadline) * std.time.ns_per_ms;
            slot.state = .queued;
            t.changed.broadcast(io);
            t.mutex.unlock(io);
        } else {
            slot.response = (t.server.respond(slot.arena.allocator(), raw, .{ .requested = &slot.cancel }) catch |err| blk: {
                var emergency = std.heap.FixedBufferAllocator.init(&slot.emergency);
                break :blk try rpcError(emergency.allocator(), slot.id, if (err == error.OutOfMemory) -32000 else -32603, "Control response resource limit");
            }) orelse {
                t.release(slot);
                return;
            };
            t.publish(slot);
        }
    }

    fn acquire(t: *Transport, control: bool, raw_len: usize) !*Slot {
        const io = t.server.config.io;
        t.mutex.lockUncancelable(io);
        if (t.failed) {
            t.mutex.unlock(io);
            return error.IoFailure;
        }
        const candidates = if (control) t.slots[max_pending_requests..] else t.slots[0..max_pending_requests];
        const slot = for (candidates) |*candidate| {
            if (candidate.state == .free) {
                candidate.state = .building;
                break candidate;
            }
        } else {
            t.mutex.unlock(io);
            return error.Busy;
        };
        t.mutex.unlock(io);
        errdefer {
            t.mutex.lockUncancelable(io);
            slot.state = .free;
            t.mutex.unlock(io);
        }
        slot.control = control;
        if (control) {
            // Credits and backing bytes were acquired at connection startup;
            // pressure from ordinary admitted work cannot consume this lane.
            slot.control_allocator = std.heap.FixedBufferAllocator.init(slot.control_backing);
            slot.arena = std.heap.ArenaAllocator.init(slot.control_allocator.allocator());
        } else {
            slot.reservation = try t.server.reserveRequest(.{ .input_bytes = raw_len, .parser_bytes = 65536 + raw_len * 6, .scratch_bytes = 4 * MiB });
            slot.reserved = memory.ReservedAllocator.init(t.server.config.allocator, &slot.reservation, t.server.config.budget.counters, null);
            slot.arena = std.heap.ArenaAllocator.init(slot.reserved.allocator());
        }
        slot.cancel.store(false, .release);
        slot.expired.store(false, .release);
        slot.control = control;
        slot.id = .null;
        slot.deadline = 0;
        slot.output_credit = 0;
        slot.output_limit = 262144 + 2048;
        slot.response = "";
        slot.logical_id = try std.fmt.bufPrint(&slot.logical_id_buf, "transport-{d}", .{t.server.sequence.fetchAdd(1, .monotonic)});
        return slot;
    }
    fn release(t: *Transport, slot: *Slot) void {
        const io = t.server.config.io;
        // Remove all reader-visible references before their arena can die.
        // Retiring remains unavailable to acquire until cleanup is complete.
        t.mutex.lockUncancelable(io);
        slot.state = .retiring;
        slot.id = .null;
        slot.raw = "";
        slot.response = "";
        t.mutex.unlock(io);
        if (!slot.control) if (t.server.config.before_tool_release) |hook| hook(t.server.config.retirement_context);
        slot.arena.deinit();
        if (!slot.control) t.server.config.budget.release(&slot.reservation) catch unreachable;
        t.mutex.lockUncancelable(io);
        slot.state = .free;
        t.changed.broadcast(io);
        t.mutex.unlock(io);
    }
    fn publish(t: *Transport, slot: *Slot) void {
        const io = t.server.config.io;
        t.mutex.lockUncancelable(io);
        defer t.mutex.unlock(io);
        const limit: usize = if (slot.control) max_backlog_bytes else max_backlog_bytes - 64 * 1024;
        // At most one tool worker can own an unpublished response. Its reserved
        // memory stays live while the record writer applies backpressure.
        if (slot.output_credit > 0) {
            std.debug.assert(slot.response.len <= slot.output_credit);
            t.backlog -= slot.output_credit;
            slot.output_credit = 0;
        }
        while (!t.failed and t.backlog + slot.response.len > limit) t.changed.waitUncancelable(io, &t.mutex);
        if (t.failed) return;
        t.backlog += slot.response.len;
        slot.state = .ready;
        t.changed.broadcast(io);
    }
    fn work(t: *Transport) void {
        const io = t.server.config.io;
        while (true) {
            t.mutex.lockUncancelable(io);
            const slot = blk: while (true) {
                if (t.failed) break :blk null;
                for (&t.slots) |*candidate| if (candidate.state == .queued) {
                    candidate.state = .running;
                    break :blk candidate;
                };
                if (t.input_done) break :blk null;
                t.changed.waitUncancelable(io, &t.mutex);
            };
            t.mutex.unlock(io);
            const job = slot orelse break;
            t.mutex.lockUncancelable(io);
            while (!t.failed and t.backlog + job.output_limit > max_backlog_bytes - 64 * 1024) t.changed.waitUncancelable(io, &t.mutex);
            if (t.failed) {
                t.mutex.unlock(io);
                break;
            }
            job.output_credit = job.output_limit;
            t.backlog += job.output_credit;
            t.mutex.unlock(io);
            job.response = (t.server.respond(job.arena.allocator(), job.raw, .{ .requested = &job.cancel }) catch null) orelse blk: {
                var fba = std.heap.FixedBufferAllocator.init(&job.emergency);
                break :blk toolFailure(fba.allocator(), job.id, .{ .request_id = job.logical_id, .workspace_id = t.server.config.session.bound_workspace, .generation = t.server.config.generation }, error.ResourceExhausted) catch unreachable;
            };
            if (job.expired.load(.acquire)) {
                var fba = std.heap.FixedBufferAllocator.init(&job.emergency);
                job.response = toolFailure(fba.allocator(), job.id, .{ .request_id = job.logical_id, .workspace_id = t.server.config.session.bound_workspace, .generation = t.server.config.generation }, error.DeadlineExceeded) catch job.response;
            }
            if (job.response.len > job.output_credit) {
                var fba = std.heap.FixedBufferAllocator.init(&job.emergency);
                job.response = toolFailure(fba.allocator(), job.id, .{ .request_id = job.logical_id, .workspace_id = t.server.config.session.bound_workspace, .generation = t.server.config.generation }, error.OutputBudgetExceeded) catch job.response;
            }
            t.publish(job);
        }
        t.mutex.lockUncancelable(io);
        t.worker_done = true;
        t.changed.broadcast(io);
        t.mutex.unlock(io);
    }
    fn write(t: *Transport) void {
        const io = t.server.config.io;
        while (true) {
            t.mutex.lockUncancelable(io);
            const slot = blk: while (true) {
                if (t.failed) break :blk null;
                for (&t.slots) |*candidate| if (candidate.state == .ready) {
                    candidate.state = .writing;
                    break :blk candidate;
                };
                if (t.input_done and t.worker_done) break :blk null;
                t.changed.waitUncancelable(io, &t.mutex);
            };
            t.mutex.unlock(io);
            const job = slot orelse break;
            t.writer.write(job.response) catch {
                t.mutex.lockUncancelable(io);
                t.failed = true;
                for (&t.slots) |*candidate| candidate.cancel.store(true, .release);
                t.changed.broadcast(io);
                t.mutex.unlock(io);
                break;
            };
            t.mutex.lockUncancelable(io);
            t.backlog -= job.response.len;
            t.changed.broadcast(io);
            t.mutex.unlock(io);
            t.release(job);
        }
    }
    fn deadlines(t: *Transport) void {
        const io = t.server.config.io;
        while (!t.finished.load(.acquire)) {
            t.mutex.lockUncancelable(io);
            const current = t.now();
            var cancelled: usize = 0;
            for (&t.slots) |*slot| if ((slot.state == .queued or slot.state == .running) and slot.deadline > 0 and current >= slot.deadline and !slot.cancel.load(.acquire)) {
                slot.expired.store(true, .release);
                slot.cancel.store(true, .release);
                cancelled += 1;
            };
            t.mutex.unlock(io);
            if (t.server.config.after_deadline_cancel) |hook| for (0..cancelled) |_| hook(t.server.config.deadline_context);
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch return;
        }
    }
};
