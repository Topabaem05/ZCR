//! Direct stdio MCP adapter (T08, I18; docs/08 §1–§3, §6, §8).
//!
//! `serveFrame` turns one framed record into one JSON-RPC record, or into no
//! record at all for a notification. The order is: frame limit, decode with the
//! parser limits (codec.zig), handshake state, then the tool.
//!
//! Handshake: only the `2025-11-25` baseline is accepted, and any other version
//! is refused by name instead of being imitated. `tools/list` answers from the
//! compiled-in contracts/tools.json, filtered to the enabled tools, so discovery
//! cannot drift from the contract; writes stay disabled until T12. `text_v1`
//! puts the logical response (T07 projection) in one text block and advertises
//! no output schema.
//!
//! A tool call takes a reservation (I02) before it allocates, registers itself in
//! the `Registry` so that `notifications/cancelled` can reach it, and runs the
//! I03-I06 implementations with that cancellation. A cancellation naming a
//! request of another session is counted and ignored. Request memory is one arena
//! bounded by `Caps.request_bytes`; the logical response and the JSON-RPC record
//! have their own fixed buffers, so nothing grows with the input.
//!
//! Errors: malformed JSON, a bad envelope and unknown methods are JSON-RPC
//! errors. A well-formed call whose arguments or execution fail is a tool result
//! with `isError` and a logical response carrying the wire code, never both.

const std = @import("std");
const core = @import("zcr_core");
const policy = @import("zcr_policy");
const memory = @import("zcr_memory");
const admission = @import("zcr_admission");
const fs_read = @import("zcr_fs_read");
const traverse = @import("zcr_fs_traverse");
const search = @import("zcr_search");
const batch = @import("zcr_batch");
const projection = @import("zcr_projection");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const WireCode = core.errors.WireCode;

pub const framing = @import("framing.zig");
pub const codec = @import("codec.zig");

/// The MCP revision this server negotiates (contracts/tools.json mcp_compatibility_baseline).
pub const protocol_version = "2025-11-25";
pub const server_name = "zcr";
/// The integrator owns the real build version (src/main.zig build_options); see handoff.
pub const server_version = "0.1.0-dev";
pub const output_profile = "text_v1";
/// contracts/tools.json, compiled in so discovery cannot drift from the contract.
pub const tools_json = @embedFile("tools_json");

pub const Tools = struct {
    read: bool = true,
    files: bool = true,
    search: bool = true,
    batch_read: bool = true,
    status: bool = true,
    health: bool = true,
    /// Writes stay disabled until T12 and host policy approval.
    patch: bool = false,
    create: bool = false,

    pub fn enabled(t: Tools, tool: codec.Tool) bool {
        return switch (tool) {
            .read => t.read,
            .files => t.files,
            .search => t.search,
            .batch_read => t.batch_read,
            .status => t.status,
            .health => t.health,
            .patch => t.patch,
            .create => t.create,
            .unknown => false,
        };
    }

    pub fn name(tool: codec.Tool) []const u8 {
        return switch (tool) {
            .read => "zcr_read",
            .files => "zcr_files",
            .search => "zcr_search",
            .batch_read => "zcr_batch_read",
            .patch => "zcr_patch",
            .create => "zcr_create",
            .status => "zcr_status",
            .health => "zcr_health",
            .unknown => "",
        };
    }

    /// Discovery order, matching contracts/tools.json.
    pub const order = [_]codec.Tool{ .read, .files, .search, .batch_read, .patch, .create, .status, .health };
};

pub const Caps = struct {
    /// Bytes one decoded request may use.
    request_bytes: usize = 1024 * 1024,
    /// Largest output budget a call may ask for; a larger request is capped.
    output_bytes: u64 = core.limits.values.default_output_bytes,
    /// Items read at once by a batch.
    batch_concurrency: u32 = 4,
    /// Paths and files one response may hold.
    max_paths: u32 = 10_000,
    max_search_files: u32 = 1_000,
};

pub const Report = struct {
    frames: u64 = 0,
    requests: u64 = 0,
    notifications: u64 = 0,
    faults: u64 = 0,
    tool_calls: u64 = 0,
    tool_errors: u64 = 0,
    cancelled: u64 = 0,
    /// Cancellations for a request id this session does not have in flight.
    cancel_ignored: u64 = 0,
    oversize_frames: u64 = 0,
    peak_request_bytes: u64 = 0,
};

/// In-flight requests of every connection, so a cancellation can reach the request
/// it names within the same session.
pub const Registry = struct {
    pub const max_inflight = core.limits.values.session_queue;

    mutex: Io.Mutex = .init,
    slots: [max_inflight]Slot = @splat(.{}),

    pub const Slot = struct {
        used: bool = false,
        session: core.SessionId = .{ .uuid = @splat(0) },
        id: codec.Id = .none,
        id_buf: [codec.max_id_bytes]u8 = undefined,
        cancelled: std.atomic.Value(bool) = .init(false),
    };

    /// Reserves a slot for one request; null when the session queue is full.
    fn open(r: *Registry, io: Io, session: core.SessionId, id: codec.Id) ?*Slot {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (&r.slots) |*slot| {
            if (slot.used) continue;
            slot.used = true;
            slot.session = session;
            slot.cancelled = .init(false);
            slot.id = switch (id) {
                .string => |text| blk: {
                    const kept = slot.id_buf[0..@min(text.len, slot.id_buf.len)];
                    @memcpy(kept, text[0..kept.len]);
                    break :blk .{ .string = kept };
                },
                else => id,
            };
            return slot;
        }
        return null;
    }

    fn close(r: *Registry, io: Io, slot: *Slot) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        slot.used = false;
        slot.id = .none;
    }

    /// Requests cancellation of one in-flight request of `session`.
    fn cancel(r: *Registry, io: Io, session: core.SessionId, id: codec.Id) bool {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (&r.slots) |*slot| {
            if (!slot.used) continue;
            if (!std.mem.eql(u8, &slot.session.uuid, &session.uuid)) continue;
            if (!codec.Id.eql(slot.id, id)) continue;
            slot.cancelled.store(true, .release);
            return true;
        }
        return false;
    }
};

pub const Dependencies = struct {
    authorizer: *policy.Authorizer,
    reader: *fs_read.Reader,
    traverser: *traverse.Traverser,
    searcher: *search.Searcher,
    batcher: *batch.Batcher,
    budget: *memory.Budget,
    admission: *admission.Admission,
    counters: *memory.accounting.Counters,
};

pub const Server = struct {
    allocator: Allocator,
    deps: Dependencies,
    session: core.SessionContext,
    caps: Caps,
    tools: Tools,
    registry: *Registry,
    initialized: bool = false,
    last: Report = .{},
    /// The logical response of one call.
    logical: []u8,
    /// The JSON-RPC record of one call.
    record: []u8,

    pub fn init(allocator: Allocator, deps: Dependencies, session: core.SessionContext, caps: Caps, tools: Tools, registry: *Registry) Allocator.Error!Server {
        const logical_bytes: usize = @intCast(caps.output_bytes + 128 * 1024);
        const logical = try allocator.alloc(u8, logical_bytes);
        errdefer allocator.free(logical);
        const record = try allocator.alloc(u8, codec.toolResultBytes(.{ .number = 0 }, logical_bytes));
        return .{
            .allocator = allocator,
            .deps = deps,
            .session = session,
            .caps = caps,
            .tools = tools,
            .registry = registry,
            .logical = logical,
            .record = record,
        };
    }

    pub fn deinit(self: *Server) void {
        self.allocator.free(self.record);
        self.allocator.free(self.logical);
    }

    pub fn report(self: *const Server) Report {
        return self.last;
    }

    /// Serves one framed record. The returned bytes are the JSON-RPC record to write,
    /// empty for a notification, and are valid until the next call.
    pub fn serveFrame(
        self: *Server,
        io: Io,
        connection: *core.Connection,
        frame: core.BoundedBytes,
    ) core.ServeError!core.EncodedToolResult {
        _ = connection;
        self.last.frames += 1;
        if (frame.bytes.len == 0 or frame.bytes.len > frame.limit or frame.bytes.len > framing.max_frame_bytes) {
            self.last.oversize_frames += 1;
            return self.fault(.{ .code = codec.rpc_invalid_request, .message = "frame is empty or larger than the frame limit" });
        }

        var reservation: core.Reservation = .{ .budget_id = self.deps.budget.id, .bytes = self.caps.request_bytes, .fd = 0, .cpu = 0, .output = 0 };
        var reserved = memory.ReservedAllocator.init(self.allocator, &reservation, self.deps.counters, null);
        var arena_state = std.heap.ArenaAllocator.init(reserved.allocator());
        defer {
            self.last.peak_request_bytes = @max(self.last.peak_request_bytes, reserved.liveBytes());
            arena_state.deinit();
        }
        const arena = arena_state.allocator();

        const decoded = try codec.decode(arena, frame.bytes);
        return switch (decoded) {
            .fault => |f| self.fault(f),
            .request => |request| self.dispatch(io, arena, request),
        };
    }

    comptime {
        core.conforms(core.ServeFrameFn(Server), Server.serveFrame);
    }

    fn fault(self: *Server, f: codec.Fault) core.ServeError!core.EncodedToolResult {
        self.last.faults += 1;
        const len = codec.encodeError(self.record, f, null) catch return error.ResourceExhausted;
        return .{ .bytes = self.record[0..len], .is_error = true };
    }

    fn dispatch(self: *Server, io: Io, arena: Allocator, request: codec.Request) core.ServeError!core.EncodedToolResult {
        switch (request.method) {
            .initialized => {
                self.last.notifications += 1;
                return .{ .bytes = self.record[0..0], .is_error = false };
            },
            .cancelled => {
                self.last.notifications += 1;
                if (!self.registry.cancel(io, self.session.session_id, request.cancel_id)) self.last.cancel_ignored += 1;
                return .{ .bytes = self.record[0..0], .is_error = false };
            },
            .initialize => {
                self.last.requests += 1;
                if (self.initialized) return self.fault(.{ .code = codec.rpc_invalid_request, .id = request.id, .message = "the session is already initialized" });
                if (!std.mem.eql(u8, request.protocol_version, protocol_version)) {
                    return self.fault(.{ .code = codec.rpc_invalid_params, .id = request.id, .message = "unsupported protocol version; this server speaks " ++ protocol_version });
                }
                self.initialized = true;
                const result = std.fmt.bufPrint(self.logical, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}}," ++
                    "\"serverInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}},\"instructions\":\"output profile {s}\"}}", .{ protocol_version, server_name, server_version, output_profile }) catch return error.ResourceExhausted;
                const len = codec.encodeResult(self.record, request.id, result) catch return error.ResourceExhausted;
                return .{ .bytes = self.record[0..len], .is_error = false };
            },
            .ping => {
                self.last.requests += 1;
                const len = codec.encodeResult(self.record, request.id, "{}") catch return error.ResourceExhausted;
                return .{ .bytes = self.record[0..len], .is_error = false };
            },
            .tools_list => {
                self.last.requests += 1;
                if (!self.initialized) return self.fault(.{ .code = codec.rpc_invalid_request, .id = request.id, .message = "initialize first" });
                const result = try self.toolList(arena);
                const len = codec.encodeResult(self.record, request.id, result) catch return error.ResourceExhausted;
                return .{ .bytes = self.record[0..len], .is_error = false };
            },
            .tools_call => {
                self.last.requests += 1;
                if (!self.initialized) return self.fault(.{ .code = codec.rpc_invalid_request, .id = request.id, .message = "initialize first" });
                return self.callTool(io, arena, request);
            },
            .unknown => return self.fault(.{ .code = codec.rpc_method_not_found, .id = request.id, .message = "unknown method" }),
        }
    }

    /// The enabled tools, taken from the contract so discovery matches it exactly.
    fn toolList(self: *Server, arena: Allocator) core.ServeError![]const u8 {
        // The contract is embedded and checked by `zig build verify-contracts`, so the
        // only reason this parse fails is the request arena running out.
        const contract = std.json.parseFromSliceLeaky(std.json.Value, arena, tools_json, .{}) catch return error.OutOfMemory;
        const all = (contract.object.get("tools") orelse return error.OutOfMemory).array.items;
        var len: usize = 0;
        const put = struct {
            fn raw(buf: []u8, at: *usize, bytes: []const u8) core.ServeError!void {
                if (buf.len - at.* < bytes.len) return error.ResourceExhausted;
                @memcpy(buf[at.*..][0..bytes.len], bytes);
                at.* += bytes.len;
            }
        }.raw;

        try put(self.logical, &len, "{\"tools\":[");
        var first = true;
        for (Tools.order) |tool| {
            if (!self.tools.enabled(tool)) continue;
            for (all) |entry| {
                const entry_name = (entry.object.get("name") orelse continue).string;
                if (!std.mem.eql(u8, entry_name, Tools.name(tool))) continue;
                var copy = entry;
                // text_v1 advertises no output schema (docs/08 §3).
                _ = copy.object.swapRemove("outputSchema");
                const text = std.json.Stringify.valueAlloc(arena, copy, .{}) catch return error.OutOfMemory;
                if (!first) try put(self.logical, &len, ",");
                first = false;
                try put(self.logical, &len, text);
            }
        }
        try put(self.logical, &len, "]}");
        return self.logical[0..len];
    }

    // ------------------------------------------------------------------ tools

    fn callTool(self: *Server, io: Io, arena: Allocator, request: codec.Request) core.ServeError!core.EncodedToolResult {
        self.last.tool_calls += 1;
        if (request.tool == .unknown or !self.tools.enabled(request.tool)) {
            return self.toolError(request, .E_UNSUPPORTED, "this build does not serve that tool");
        }
        if (request.argument_error) |message| return self.toolError(request, .E_INVALID_ARGUMENT, message);

        const slot = self.registry.open(io, self.session.session_id, request.id) orelse {
            return self.toolError(request, .E_BUSY, "too many requests in flight for this session");
        };
        defer self.registry.close(io, slot);

        const output_bytes = @min(request.output_bytes, self.caps.output_bytes);
        return self.run(io, arena, request, .{ .requested = &slot.cancelled }, output_bytes) catch |err| {
            const code = core.errors.wireCode(err);
            if (code == .E_CANCELLED) self.last.cancelled += 1;
            return self.toolError(request, code, @errorName(err));
        };
    }

    fn run(self: *Server, io: Io, arena: Allocator, request: codec.Request, cancel: core.Cancel, output_bytes: u64) core.errors.Error!core.EncodedToolResult {
        var id_buf: [24]u8 = undefined;
        const envelope = projection.Envelope{
            .request_id = requestId(request.id, &id_buf),
            .workspace_id = self.session.bound_workspace,
            .generation = self.deps.reader.generation,
        };
        return switch (request.args) {
            .read => |spec| self.runRead(io, request, envelope, spec, cancel, output_bytes),
            .files => |spec| self.runFiles(io, arena, request, envelope, spec, cancel, output_bytes),
            .search => |spec| self.runSearch(io, arena, request, envelope, spec, cancel, output_bytes),
            .batch_read => |args| self.runBatch(io, arena, request, envelope, args, cancel, output_bytes),
            .status => self.runStatus(request, envelope),
            .health => self.runHealth(request, envelope),
            .none => error.InvalidArgument,
        };
    }

    /// The JSON-RPC id as the logical `request_id`; ids are at most 128 bytes.
    fn requestId(id: codec.Id, buf: []u8) []const u8 {
        return switch (id) {
            .none => "0",
            .number => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "0",
            .string => |text| if (text.len == 0) "0" else text,
        };
    }

    fn reserve(self: *Server, cost: core.ResourceCost) core.errors.Error!core.Reservation {
        return self.deps.admission.reserve(self.session, cost);
    }

    fn release(self: *Server, reservation: *core.Reservation) void {
        self.deps.admission.release(self.session, reservation) catch {};
    }

    fn finish(self: *Server, request: codec.Request, response: projection.Response) core.errors.Error!core.EncodedToolResult {
        const len = codec.encodeToolResult(self.record, request.id, response.bytes, false) catch return error.ResourceExhausted;
        return .{ .bytes = self.record[0..len], .is_error = false };
    }

    fn project(self: *Server, envelope: projection.Envelope, data: projection.Data, status: core.ResultStatus, output_bytes: u64) core.errors.Error!projection.Response {
        return projection.success(self.logical, envelope, data, status, output_bytes) catch |err| switch (err) {
            error.OutputBudgetExceeded => error.OutputBudgetExceeded,
            error.InvalidArgument => error.InvalidArgument,
        };
    }

    fn runRead(self: *Server, io: Io, request: codec.Request, envelope: projection.Envelope, spec_in: core.ReadSpec, cancel: core.Cancel, output_bytes: u64) core.errors.Error!core.EncodedToolResult {
        var spec = spec_in;
        spec.output_bytes = output_bytes;
        const capability = try self.deps.authorizer.authorize(io, self.session, .read, spec.path);
        var cost = try admission.estimate(.{ .operation = .read, .frame_bytes = 4096, .output_bytes = output_bytes });
        // The read estimate does not include line records or arena growth (T04 handoff).
        cost.scratch_bytes += output_bytes + 64 * 1024;
        var reservation = try self.reserve(cost);
        defer self.release(&reservation);
        var reserved = memory.ReservedAllocator.init(self.allocator, &reservation, self.deps.counters, null);

        var owned = try self.deps.reader.readRange(io, reserved.allocator(), capability, spec, &reservation, cancel);
        defer owned.deinit();
        const response = try self.project(envelope, .{ .read = owned.value }, owned.value.status, output_bytes);
        return self.finish(request, response);
    }

    const PathSink = struct {
        arena: Allocator,
        paths: std.ArrayList(core.RelativePath) = .empty,
        limit: usize,
        truncated: bool = false,

        fn push(context: *anyopaque, item: core.RelativePath) core.SinkError!void {
            const self: *PathSink = @ptrCast(@alignCast(context));
            if (self.paths.items.len == self.limit) {
                self.truncated = true;
                return error.OutputBudgetExceeded;
            }
            const kept = self.arena.dupe(u8, item.bytes) catch return error.Busy;
            self.paths.append(self.arena, .{ .bytes = kept }) catch return error.Busy;
        }

        fn sink(self: *PathSink) core.Sink(core.RelativePath) {
            return .{ .context = self, .push_fn = push };
        }
    };

    fn runFiles(self: *Server, io: Io, arena: Allocator, request: codec.Request, envelope: projection.Envelope, spec: core.FileSpec, cancel: core.Cancel, output_bytes: u64) core.errors.Error!core.EncodedToolResult {
        const capability = try self.deps.authorizer.authorize(io, self.session, .enumerate, .{ .bytes = "." });
        var cost = try admission.estimate(.{ .operation = .enumerate, .frame_bytes = 4096, .output_bytes = output_bytes });
        cost.scratch_bytes += self.caps.request_bytes;
        var reservation = try self.reserve(cost);
        defer self.release(&reservation);

        var collector: PathSink = .{ .arena = arena, .limit = @min(spec.limit, self.caps.max_paths) };
        const coverage = self.deps.traverser.enumerate(io, capability, spec, collector.sink(), cancel) catch |err| switch (err) {
            error.OutputBudgetExceeded => if (collector.truncated) core.Coverage{ .scope = ".", .skipped = 0, .index_state = .live } else return err,
            else => |e| return e,
        };
        const walk = self.deps.traverser.report();
        const status: core.ResultStatus = .{
            .complete = walk.complete and !collector.truncated,
            .truncated = walk.truncated or collector.truncated,
            .consistency = .checked_live,
            .coverage = coverage,
        };
        const response = try self.project(envelope, .{ .files = .{ .paths = collector.paths.items, .order = spec.order } }, status, output_bytes);
        return self.finish(request, response);
    }

    const FileSink = struct {
        arena: Allocator,
        files: std.ArrayList(core.SearchFileResult) = .empty,
        limit: usize,
        truncated: bool = false,

        fn push(context: *anyopaque, item: core.SearchFileResult) core.SinkError!void {
            const self: *FileSink = @ptrCast(@alignCast(context));
            if (self.files.items.len == self.limit) {
                self.truncated = true;
                return error.OutputBudgetExceeded;
            }
            const path = self.arena.dupe(u8, item.path.bytes) catch return error.Busy;
            const matches = self.arena.dupe(core.SearchMatch, item.matches) catch return error.Busy;
            const context_lines = self.arena.alloc(core.Line, item.context.len) catch return error.Busy;
            for (item.context, context_lines) |line, *copy| {
                copy.* = .{ .number = line.number, .span = line.span, .text = self.arena.dupe(u8, line.text) catch return error.Busy };
            }
            self.files.append(self.arena, .{ .path = .{ .bytes = path }, .matches = matches, .context = context_lines, .version = item.version }) catch return error.Busy;
        }

        fn sink(self: *FileSink) core.Sink(core.SearchFileResult) {
            return .{ .context = self, .push_fn = push };
        }
    };

    fn runSearch(self: *Server, io: Io, arena: Allocator, request: codec.Request, envelope: projection.Envelope, spec: core.SearchSpec, cancel: core.Cancel, output_bytes: u64) core.errors.Error!core.EncodedToolResult {
        const capability = try self.deps.authorizer.authorize(io, self.session, .search, .{ .bytes = "." });
        var cost = try admission.estimate(.{ .operation = .search, .frame_bytes = 4096, .output_bytes = output_bytes });
        cost.scratch_bytes += self.caps.request_bytes;
        var reservation = try self.reserve(cost);
        defer self.release(&reservation);

        self.deps.searcher.output_bytes = @min(output_bytes, self.deps.searcher.caps.output_bytes);
        var collector: FileSink = .{ .arena = arena, .limit = self.caps.max_search_files };
        const coverage = self.deps.searcher.search(io, capability, spec, collector.sink(), cancel) catch |err| switch (err) {
            error.OutputBudgetExceeded => if (collector.truncated) core.Coverage{ .scope = ".", .skipped = 0, .index_state = .live } else return err,
            else => |e| return e,
        };
        const found = self.deps.searcher.report();
        const status: core.ResultStatus = .{
            .complete = found.complete and !collector.truncated,
            .truncated = found.truncated or collector.truncated,
            .consistency = .checked_live,
            .coverage = coverage,
        };
        const response = try self.project(envelope, .{ .search = .{ .files = collector.files.items, .order = spec.order } }, status, output_bytes);
        return self.finish(request, response);
    }

    fn runBatch(self: *Server, io: Io, arena: Allocator, request: codec.Request, envelope: projection.Envelope, args: codec.BatchArgs, cancel: core.Cancel, output_bytes: u64) core.errors.Error!core.EncodedToolResult {
        const items = try arena.dupe(core.BatchReadItem, args.items);
        for (items) |*item| item.spec.output_bytes = output_bytes;
        const cost = batch.plannedCost(items, output_bytes, self.caps.batch_concurrency) catch return error.InvalidArgument;
        var reservation = try self.reserve(cost);
        defer self.release(&reservation);
        var reserved = memory.ReservedAllocator.init(self.allocator, &reservation, self.deps.counters, null);

        self.deps.batcher.cancel = cancel;
        var owned = try self.deps.batcher.batchRead(io, reserved.allocator(), self.session, items, &reservation);
        defer owned.deinit();
        const response = try self.project(envelope, .{ .batch_read = owned.value }, owned.value.status, output_bytes);
        return self.finish(request, response);
    }

    fn runStatus(self: *Server, request: codec.Request, envelope: projection.Envelope) core.errors.Error!core.EncodedToolResult {
        const task_hex = std.fmt.bytesToHex(self.session.bound_task.uuid, .lower);
        var data_buf: [512]u8 = undefined;
        const data = std.fmt.bufPrint(&data_buf, "{{\"task_id\":\"{s}\",\"index_state\":\"live\",\"write_mode\":\"read_only\",\"receipt\":null}}", .{&task_hex}) catch return error.ResourceExhausted;
        return self.finishRaw(request, envelope, data);
    }

    fn runHealth(self: *Server, request: codec.Request, envelope: projection.Envelope) core.errors.Error!core.EncodedToolResult {
        const caps = self.deps.budget.caps;
        const used = self.deps.budget.usage();
        var data_buf: [1024]u8 = undefined;
        const data = std.fmt.bufPrint(&data_buf, "{{\"build_version\":\"{s}\",\"backend\":\"scalar\",\"capabilities\":{{" ++
            "\"read\":{},\"files\":{},\"search\":{},\"batch_read\":{},\"patch\":{},\"create\":{},\"status\":{},\"health\":{}}}," ++
            "\"tracked_limit_bytes\":{d},\"tracked_live_bytes\":{d},\"pressure\":\"normal\",\"usable_cpu_permits\":{d}}}", .{
            server_version,
            self.tools.read,
            self.tools.files,
            self.tools.search,
            self.tools.batch_read,
            self.tools.patch,
            self.tools.create,
            self.tools.status,
            self.tools.health,
            caps.bytes,
            used.bytes,
            @max(@as(u32, 1), @as(u32, caps.cpu)),
        }) catch return error.ResourceExhausted;
        return self.finishRaw(request, envelope, data);
    }

    /// Wraps data the projection does not encode (status, health) in the same envelope.
    fn finishRaw(self: *Server, request: codec.Request, envelope: projection.Envelope, data: []const u8) core.errors.Error!core.EncodedToolResult {
        const len = codec.encodeEnvelope(self.logical, envelope.request_id, envelope.workspace_id, envelope.generation, data) catch return error.ResourceExhausted;
        const record_len = codec.encodeToolResult(self.record, request.id, self.logical[0..len], false) catch return error.ResourceExhausted;
        return .{ .bytes = self.record[0..record_len], .is_error = false };
    }

    fn toolError(self: *Server, request: codec.Request, code: WireCode, message: []const u8) core.ServeError!core.EncodedToolResult {
        self.last.tool_errors += 1;
        var id_buf: [24]u8 = undefined;
        const envelope = projection.Envelope{
            .request_id = requestId(request.id, &id_buf),
            .workspace_id = self.session.bound_workspace,
            .generation = self.deps.reader.generation,
        };
        const info: core.errors.ErrorInfo = .{ .code = code, .message = message, .retryable = core.errors.defaultRetryable(code) };
        const response = projection.failure(self.logical, envelope, info) catch return error.ResourceExhausted;
        const len = codec.encodeToolResult(self.record, request.id, response.bytes, true) catch return error.ResourceExhausted;
        return .{ .bytes = self.record[0..len], .is_error = true };
    }
};
