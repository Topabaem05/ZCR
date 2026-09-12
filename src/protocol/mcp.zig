//! Direct stdio MCP adapter (T08, I18; docs/08 §1–§3, §6, §8).
//!
//! S02 stub: the API the tests use, with no behaviour yet.

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

pub const framing = @import("framing.zig");
pub const codec = @import("codec.zig");

/// The MCP revision this server negotiates (contracts/tools.json mcp_compatibility_baseline).
pub const protocol_version = "2025-11-25";
pub const server_name = "zcr";
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
};

pub const Caps = struct {
    /// Bytes of one decoded request arena and of the response buffer.
    request_bytes: usize = 1024 * 1024,
    response_bytes: usize = 3 * 1024 * 1024,
    output_bytes: u64 = core.limits.values.default_output_bytes,
    search: search.Caps = .{},
    batch: batch.Caps = .{},
};

pub const Report = struct {
    frames: u64 = 0,
    requests: u64 = 0,
    notifications: u64 = 0,
    faults: u64 = 0,
    tool_calls: u64 = 0,
    tool_errors: u64 = 0,
    cancelled: u64 = 0,
    /// Cancellations for a request id this session does not have.
    cancel_ignored: u64 = 0,
    oversize_frames: u64 = 0,
    peak_request_bytes: u64 = 0,
};

/// In-flight requests of every connection, so a cancellation can reach the request
/// it names within the same session.
pub const Registry = struct {
    pub const max_inflight = core.limits.values.session_queue;

    mutex: Io.Mutex = .init,
    slots: [max_inflight]?Slot = @splat(null),

    pub const Slot = struct {
        session: core.SessionId,
        id: codec.Id,
        id_buf: [codec.max_id_bytes]u8 = undefined,
        cancelled: std.atomic.Value(bool) = .init(false),
    };
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

    pub fn init(allocator: Allocator, deps: Dependencies, session: core.SessionContext, caps: Caps, tools: Tools, registry: *Registry) Allocator.Error!Server {
        return .{
            .allocator = allocator,
            .deps = deps,
            .session = session,
            .caps = caps,
            .tools = tools,
            .registry = registry,
        };
    }

    pub fn deinit(self: *Server) void {
        _ = self;
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
        _ = self;
        _ = io;
        _ = connection;
        _ = frame;
        return error.Unsupported;
    }

    comptime {
        core.conforms(core.ServeFrameFn(Server), Server.serveFrame);
    }
};
