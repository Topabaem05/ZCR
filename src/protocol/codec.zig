//! JSON-RPC decoding with parser limits, and MCP response encoding (T08; docs/08 §6, §8).
//!
//! S02 stub: the API the tests use, with no behaviour yet.

const std = @import("std");
const core = @import("zcr_core");
const Allocator = std.mem.Allocator;

pub const max_depth = core.limits.values.json_max_depth;
pub const max_method_bytes = 128;
pub const max_id_bytes = 128;
pub const jsonrpc_version = "2.0";

/// JSON-RPC error codes used by this server.
pub const rpc_parse_error: i32 = -32700;
pub const rpc_invalid_request: i32 = -32600;
pub const rpc_method_not_found: i32 = -32601;
pub const rpc_invalid_params: i32 = -32602;

pub const Id = union(enum) {
    none,
    number: i64,
    string: []const u8,

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .none => b == .none,
            .number => |x| b == .number and b.number == x,
            .string => |x| b == .string and std.mem.eql(u8, b.string, x),
        };
    }
};

pub const Method = enum { initialize, initialized, tools_list, tools_call, ping, cancelled, unknown };

pub const Tool = enum { read, files, search, batch_read, patch, create, status, health, unknown };

pub const Args = union(enum) {
    none,
    read: core.ReadSpec,
    files: core.FileSpec,
    search: core.SearchSpec,
    batch_read: struct { items: []const core.BatchReadItem, output_bytes: u64, deadline_ms: u32 },
    status: struct { receipt_id: ?[]const u8, output_bytes: u64, deadline_ms: u32 },
    health: struct { output_bytes: u64, deadline_ms: u32 },
};

pub const Request = struct {
    id: Id = .none,
    method: Method = .unknown,
    method_name: []const u8 = "",
    /// `initialize`
    protocol_version: []const u8 = "",
    /// `tools/call`
    tool: Tool = .unknown,
    tool_name: []const u8 = "",
    args: Args = .none,
    /// Tool arguments that break the input schema; the caller answers with a tool error.
    argument_error: ?[]const u8 = null,
    /// `notifications/cancelled`
    cancel_id: Id = .none,
};

pub const Fault = struct { code: i32, id: Id = .none, message: []const u8 };

pub const Decoded = union(enum) { request: Request, fault: Fault };

/// Decodes one JSON-RPC record. Depth, duplicate keys, unknown fields, number ranges
/// and string lengths are checked before anything large is allocated.
pub fn decode(arena: Allocator, bytes: []const u8) Allocator.Error!Decoded {
    _ = arena;
    _ = bytes;
    return .{ .fault = .{ .code = rpc_parse_error, .message = "not implemented" } };
}

/// `{"jsonrpc":"2.0","id":...,"result":<result>}`
pub fn encodeResult(out: []u8, id: Id, result: []const u8) error{NoSpace}!usize {
    _ = out;
    _ = id;
    _ = result;
    return error.NoSpace;
}

/// A `tools/call` result: one text block with the logical response, plus `isError`.
pub fn encodeToolResult(out: []u8, id: Id, text: []const u8, is_error: bool) error{NoSpace}!usize {
    _ = out;
    _ = id;
    _ = text;
    _ = is_error;
    return error.NoSpace;
}

/// `{"jsonrpc":"2.0","id":...,"error":{"code":...,"message":...,"data":...}}`
pub fn encodeError(out: []u8, fault: Fault, data: ?[]const u8) error{NoSpace}!usize {
    _ = out;
    _ = fault;
    _ = data;
    return error.NoSpace;
}

/// Bytes `encodeToolResult` needs for a text of `text_len` bytes.
pub fn toolResultBytes(id: Id, text_len: usize) usize {
    _ = id;
    _ = text_len;
    return 0;
}
