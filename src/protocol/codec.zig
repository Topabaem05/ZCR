//! JSON-RPC decoding with parser limits, and MCP response encoding (T08; docs/08 §6, §8).
//!
//! Decoding is strict and bounded, in this order: UTF-8, nesting depth (counted
//! over the raw bytes before the parser runs), then one pass over the record.
//! Duplicate members, a missing or wrong `jsonrpc`, a non-string method, an id
//! that is not a number, string or null, and over-long methods and ids are
//! JSON-RPC errors. Unknown methods are `-32601`. Tool arguments are decoded
//! against contracts/tools.json: unknown fields, wrong types, numbers outside
//! their schema range and missing required fields become `argument_error`, which
//! the server reports as a tool error with `E_INVALID_ARGUMENT` rather than a
//! JSON-RPC error, because the request itself was well formed.
//!
//! Everything a request needs lives in the caller's arena; encoding writes into a
//! caller-owned buffer and never allocates.

const std = @import("std");
const core = @import("zcr_core");
const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;

pub const max_depth = core.limits.values.json_max_depth;
pub const max_method_bytes = 128;
pub const max_id_bytes = 128;
pub const max_string_bytes = core.limits.values.path_max_utf8_bytes;
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

pub const BatchArgs = struct { items: []const core.BatchReadItem, output_bytes: u64, deadline_ms: u32 };
pub const StatusArgs = struct { receipt_id: ?[]const u8, output_bytes: u64, deadline_ms: u32 };
pub const HealthArgs = struct { output_bytes: u64, deadline_ms: u32 };

pub const Args = union(enum) {
    none,
    read: core.ReadSpec,
    files: core.FileSpec,
    search: core.SearchSpec,
    batch_read: BatchArgs,
    status: StatusArgs,
    health: HealthArgs,
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
    /// Output budget the tool asks for; every tool carries one (docs/08 §2).
    output_bytes: u64 = core.limits.values.default_output_bytes,
    deadline_ms: u32 = core.limits.values.default_deadline_ms,
    /// Tool arguments that break the input schema; the caller answers with a tool error.
    argument_error: ?[]const u8 = null,
    /// `notifications/cancelled`
    cancel_id: Id = .none,
};

pub const Fault = struct { code: i32, id: Id = .none, message: []const u8 };

pub const Decoded = union(enum) { request: Request, fault: Fault };

const Error = error{ Parse, Invalid, Params, OutOfMemory };

/// Decodes one JSON-RPC record.
pub fn decode(arena: Allocator, bytes: []const u8) Allocator.Error!Decoded {
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return .{ .fault = .{ .code = rpc_parse_error, .message = "frame is not valid UTF-8" } };
    }
    if (depthOf(bytes) > max_depth) {
        return .{ .fault = .{ .code = rpc_invalid_request, .message = "JSON nesting is deeper than the parser limit" } };
    }

    var state: State = .{ .arena = arena };
    const request = decodeRecord(&state, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse => return .{ .fault = .{ .code = rpc_parse_error, .id = state.id, .message = state.message orelse "record is not valid JSON" } },
        error.Invalid => return .{ .fault = .{ .code = rpc_invalid_request, .id = state.id, .message = state.message orelse "not a valid JSON-RPC request" } },
        error.Params => return .{ .fault = .{ .code = rpc_invalid_params, .id = state.id, .message = state.message orelse "invalid params" } },
    };
    if (request.method == .unknown) {
        return .{ .fault = .{ .code = rpc_method_not_found, .id = request.id, .message = "unknown method" } };
    }
    return .{ .request = request };
}

/// Largest `{`/`[` nesting outside strings. Counted before the parser allocates.
fn depthOf(bytes: []const u8) u32 {
    var depth: u32 = 0;
    var max: u32 = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                max = @max(max, depth);
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return max;
}

const State = struct {
    arena: Allocator,
    id: Id = .none,
    message: ?[]const u8 = null,

    fn fail(s: *State, err: Error, message: []const u8) Error {
        if (s.message == null) s.message = message;
        return err;
    }
};

fn nextToken(scanner: *Scanner, arena: Allocator) Error!std.json.Token {
    return scanner.nextAllocMax(arena, .alloc_if_needed, max_string_bytes) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Parse,
    };
}

fn tokenString(token: std.json.Token) ?[]const u8 {
    return switch (token) {
        .string, .allocated_string => |s| s,
        else => null,
    };
}

fn tokenNumber(token: std.json.Token) ?[]const u8 {
    return switch (token) {
        .number, .allocated_number => |s| s,
        else => null,
    };
}

/// Reads one value and returns its raw bytes, so it can be decoded once the method is known.
fn rawValue(scanner: *Scanner, bytes: []const u8) Error![]const u8 {
    const start = scanner.cursor;
    scanner.skipValue() catch return error.Parse;
    // The cursor sits after the key, so the slice still carries the member separator.
    var raw = std.mem.trim(u8, bytes[start..scanner.cursor], " \t\r\n");
    if (raw.len > 0 and raw[0] == ':') raw = std.mem.trim(u8, raw[1..], " \t\r\n");
    if (raw.len == 0) return error.Parse;
    return raw;
}

fn decodeRecord(s: *State, bytes: []const u8) Error!Request {
    var scanner = Scanner.initCompleteInput(s.arena, bytes);
    defer scanner.deinit();
    if (try nextToken(&scanner, s.arena) != .object_begin) return s.fail(error.Parse, "record is not a JSON object");

    var request: Request = .{};
    var version: []const u8 = "";
    var params: ?[]const u8 = null;
    var seen: struct { jsonrpc: bool = false, id: bool = false, method: bool = false, params: bool = false } = .{};

    while (true) {
        const token = try nextToken(&scanner, s.arena);
        if (token == .object_end) break;
        const key = tokenString(token) orelse return s.fail(error.Parse, "object key is not a string");
        if (std.mem.eql(u8, key, "jsonrpc")) {
            if (seen.jsonrpc) return s.fail(error.Invalid, "duplicate member");
            seen.jsonrpc = true;
            version = tokenString(try nextToken(&scanner, s.arena)) orelse return s.fail(error.Invalid, "jsonrpc is not a string");
        } else if (std.mem.eql(u8, key, "id")) {
            if (seen.id) return s.fail(error.Invalid, "duplicate member");
            seen.id = true;
            const value = try nextToken(&scanner, s.arena);
            request.id = switch (value) {
                .null => .none,
                .number, .allocated_number => |raw| .{ .number = std.fmt.parseInt(i64, raw, 10) catch return s.fail(error.Invalid, "id is not an integer") },
                .string, .allocated_string => |text| blk: {
                    if (text.len > max_id_bytes) return s.fail(error.Invalid, "id is too long");
                    break :blk .{ .string = text };
                },
                else => return s.fail(error.Invalid, "id must be a number, string or null"),
            };
            s.id = request.id;
        } else if (std.mem.eql(u8, key, "method")) {
            if (seen.method) return s.fail(error.Invalid, "duplicate member");
            seen.method = true;
            const name = tokenString(try nextToken(&scanner, s.arena)) orelse return s.fail(error.Invalid, "method is not a string");
            if (name.len > max_method_bytes) return s.fail(error.Invalid, "method is too long");
            request.method_name = name;
        } else if (std.mem.eql(u8, key, "params")) {
            if (seen.params) return s.fail(error.Invalid, "duplicate member");
            seen.params = true;
            params = try rawValue(&scanner, bytes);
        } else {
            scanner.skipValue() catch return error.Parse;
        }
    }
    if (try nextToken(&scanner, s.arena) != .end_of_document) return s.fail(error.Parse, "trailing bytes after the record");

    if (!seen.jsonrpc or !std.mem.eql(u8, version, jsonrpc_version)) return s.fail(error.Invalid, "jsonrpc must be \"2.0\"");
    if (!seen.method) return s.fail(error.Invalid, "method is missing");

    request.method = methodOf(request.method_name);
    if (request.method == .unknown) return request;
    if (isNotification(request.method)) {
        if (request.id != .none) return s.fail(error.Invalid, "a notification cannot carry an id");
    } else if (request.id == .none) {
        return s.fail(error.Invalid, "a request needs an id");
    }

    switch (request.method) {
        .initialize => try decodeInitialize(s, &request, params orelse return s.fail(error.Params, "initialize needs params")),
        .tools_call => try decodeToolCall(s, &request, params orelse return s.fail(error.Params, "tools/call needs params")),
        .cancelled => try decodeCancelled(s, &request, params orelse return s.fail(error.Params, "notifications/cancelled needs params")),
        .tools_list, .ping, .initialized, .unknown => {},
    }
    return request;
}

fn methodOf(name: []const u8) Method {
    const table = .{
        .{ "initialize", Method.initialize },
        .{ "notifications/initialized", Method.initialized },
        .{ "tools/list", Method.tools_list },
        .{ "tools/call", Method.tools_call },
        .{ "ping", Method.ping },
        .{ "notifications/cancelled", Method.cancelled },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, name, row[0])) return row[1];
    }
    return .unknown;
}

fn isNotification(method: Method) bool {
    return method == .initialized or method == .cancelled;
}

fn decodeInitialize(s: *State, request: *Request, params: []const u8) Error!void {
    var scanner = Scanner.initCompleteInput(s.arena, params);
    defer scanner.deinit();
    if (try nextToken(&scanner, s.arena) != .object_begin) return s.fail(error.Params, "params must be an object");
    var seen_version = false;
    while (true) {
        const token = try nextToken(&scanner, s.arena);
        if (token == .object_end) break;
        const key = tokenString(token) orelse return s.fail(error.Params, "object key is not a string");
        if (std.mem.eql(u8, key, "protocolVersion")) {
            if (seen_version) return s.fail(error.Invalid, "duplicate member");
            seen_version = true;
            request.protocol_version = tokenString(try nextToken(&scanner, s.arena)) orelse return s.fail(error.Params, "protocolVersion is not a string");
        } else {
            scanner.skipValue() catch return error.Parse;
        }
    }
    if (!seen_version) return s.fail(error.Params, "protocolVersion is missing");
}

fn decodeCancelled(s: *State, request: *Request, params: []const u8) Error!void {
    var scanner = Scanner.initCompleteInput(s.arena, params);
    defer scanner.deinit();
    if (try nextToken(&scanner, s.arena) != .object_begin) return s.fail(error.Params, "params must be an object");
    var seen_id = false;
    while (true) {
        const token = try nextToken(&scanner, s.arena);
        if (token == .object_end) break;
        const key = tokenString(token) orelse return s.fail(error.Params, "object key is not a string");
        if (std.mem.eql(u8, key, "requestId")) {
            if (seen_id) return s.fail(error.Invalid, "duplicate member");
            seen_id = true;
            const value = try nextToken(&scanner, s.arena);
            request.cancel_id = switch (value) {
                .number, .allocated_number => |raw| .{ .number = std.fmt.parseInt(i64, raw, 10) catch return s.fail(error.Params, "requestId is not an integer") },
                .string, .allocated_string => |text| blk: {
                    if (text.len > max_id_bytes) return s.fail(error.Params, "requestId is too long");
                    break :blk .{ .string = text };
                },
                else => return s.fail(error.Params, "requestId must be a number or string"),
            };
        } else {
            scanner.skipValue() catch return error.Parse;
        }
    }
    if (!seen_id) return s.fail(error.Params, "requestId is missing");
}

fn toolOf(name: []const u8) Tool {
    const table = .{
        .{ "zcr_read", Tool.read },       .{ "zcr_files", Tool.files },
        .{ "zcr_search", Tool.search },   .{ "zcr_batch_read", Tool.batch_read },
        .{ "zcr_patch", Tool.patch },     .{ "zcr_create", Tool.create },
        .{ "zcr_status", Tool.status },   .{ "zcr_health", Tool.health },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, name, row[0])) return row[1];
    }
    return .unknown;
}

fn decodeToolCall(s: *State, request: *Request, params: []const u8) Error!void {
    var scanner = Scanner.initCompleteInput(s.arena, params);
    defer scanner.deinit();
    if (try nextToken(&scanner, s.arena) != .object_begin) return s.fail(error.Params, "params must be an object");
    var arguments: ?[]const u8 = null;
    var seen: struct { name: bool = false, arguments: bool = false } = .{};
    while (true) {
        const token = try nextToken(&scanner, s.arena);
        if (token == .object_end) break;
        const key = tokenString(token) orelse return s.fail(error.Params, "object key is not a string");
        if (std.mem.eql(u8, key, "name")) {
            if (seen.name) return s.fail(error.Invalid, "duplicate member");
            seen.name = true;
            request.tool_name = tokenString(try nextToken(&scanner, s.arena)) orelse return s.fail(error.Params, "tool name is not a string");
        } else if (std.mem.eql(u8, key, "arguments")) {
            if (seen.arguments) return s.fail(error.Invalid, "duplicate member");
            seen.arguments = true;
            arguments = try rawValue(&scanner, params);
        } else if (std.mem.eql(u8, key, "_meta")) {
            scanner.skipValue() catch return error.Parse;
        } else {
            return s.fail(error.Params, "unknown member of tools/call params");
        }
    }
    if (!seen.name) return s.fail(error.Params, "tool name is missing");
    request.tool = toolOf(request.tool_name);
    if (request.tool == .unknown) {
        request.argument_error = "unknown tool";
        return;
    }
    decodeArgs(s, request, arguments orelse "{}") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            request.argument_error = s.message orelse "invalid tool arguments";
            s.message = null;
            return;
        },
    };
}

// ------------------------------------------------------------------ tool arguments

/// One scalar of a tool's input schema.
const Field = struct {
    name: []const u8,
    kind: enum { string, integer, boolean, enumeration },
    min: u64 = 0,
    max: u64 = 0,
    choices: []const []const u8 = &.{},
};

const Value = union(enum) { string: []const u8, integer: u64, boolean: bool, choice: usize };

const consistency_choices = [_][]const u8{ "checked_live", "managed_generation", "bounded_stale" };
const order_choices = [_][]const u8{ "discovery", "path_then_offset" };

const common_fields = [_]Field{
    .{ .name = "output_bytes", .kind = .integer, .min = 1024, .max = core.limits.values.max_output_bytes },
    .{ .name = "deadline_ms", .kind = .integer, .min = 1, .max = core.limits.values.max_deadline_ms },
};

fn fieldsFor(tool: Tool) []const Field {
    return switch (tool) {
        .read => &[_]Field{
            .{ .name = "path", .kind = .string, .min = 1, .max = max_string_bytes },
            .{ .name = "start_line", .kind = .integer, .min = 1, .max = std.math.maxInt(u32) },
            .{ .name = "line_count", .kind = .integer, .min = 1, .max = core.limits.values.max_read_lines },
            .{ .name = "write_intent", .kind = .boolean },
            .{ .name = "consistency", .kind = .enumeration, .choices = &consistency_choices },
        } ++ common_fields,
        .files => &[_]Field{
            .{ .name = "glob", .kind = .string, .min = 1, .max = max_string_bytes },
            .{ .name = "limit", .kind = .integer, .min = 1, .max = core.limits.values.max_file_results },
            .{ .name = "include_hidden", .kind = .boolean },
            .{ .name = "order", .kind = .enumeration, .choices = &order_choices },
            .{ .name = "consistency", .kind = .enumeration, .choices = &consistency_choices },
            .{ .name = "max_stale_ms", .kind = .integer, .min = 0, .max = core.limits.values.max_deadline_ms },
        } ++ common_fields,
        .search => &[_]Field{
            .{ .name = "literal", .kind = .string, .min = 1, .max = max_string_bytes },
            .{ .name = "glob", .kind = .string, .min = 1, .max = max_string_bytes },
            .{ .name = "context_lines", .kind = .integer, .min = 0, .max = 20 },
            .{ .name = "limit", .kind = .integer, .min = 1, .max = core.limits.values.max_search_matches },
            .{ .name = "max_file_bytes", .kind = .integer, .min = 1, .max = core.limits.values.max_search_file_bytes },
            .{ .name = "include_hidden", .kind = .boolean },
            .{ .name = "order", .kind = .enumeration, .choices = &order_choices },
            .{ .name = "consistency", .kind = .enumeration, .choices = &consistency_choices },
            .{ .name = "max_stale_ms", .kind = .integer, .min = 0, .max = core.limits.values.max_deadline_ms },
        } ++ common_fields,
        .status => &[_]Field{
            .{ .name = "receipt_id", .kind = .string, .min = 1, .max = 128 },
        } ++ common_fields,
        .health => &common_fields,
        .batch_read, .patch, .create, .unknown => &.{},
    };
}

const item_fields = [_]Field{
    .{ .name = "item_id", .kind = .string, .min = 1, .max = 64 },
    .{ .name = "path", .kind = .string, .min = 1, .max = max_string_bytes },
    .{ .name = "start_line", .kind = .integer, .min = 1, .max = std.math.maxInt(u32) },
    .{ .name = "line_count", .kind = .integer, .min = 1, .max = core.limits.values.max_read_lines },
    .{ .name = "write_intent", .kind = .boolean },
    .{ .name = "consistency", .kind = .enumeration, .choices = &consistency_choices },
};

/// Reads one object of scalar fields into `out`, checking types, ranges and duplicates.
fn readFields(s: *State, scanner: *Scanner, fields: []const Field, out: []?Value) Error!void {
    if (try nextToken(scanner, s.arena) != .object_begin) return s.fail(error.Params, "arguments must be an object");
    while (true) {
        const token = try nextToken(scanner, s.arena);
        if (token == .object_end) return;
        const key = tokenString(token) orelse return s.fail(error.Params, "object key is not a string");
        const index = for (fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, key)) break i;
        } else return s.fail(error.Params, "unknown argument");
        if (out[index] != null) return s.fail(error.Params, "duplicate argument");
        const field = fields[index];
        const value = try nextToken(scanner, s.arena);
        out[index] = switch (field.kind) {
            .string => blk: {
                const text = tokenString(value) orelse return s.fail(error.Params, "argument is not a string");
                if (text.len < field.min or text.len > field.max) return s.fail(error.Params, "argument string length is out of range");
                break :blk .{ .string = text };
            },
            .integer => blk: {
                const raw = tokenNumber(value) orelse return s.fail(error.Params, "argument is not a number");
                const n = std.fmt.parseInt(u64, raw, 10) catch return s.fail(error.Params, "argument is not an integer in range");
                if (n < field.min or n > field.max) return s.fail(error.Params, "argument is out of range");
                break :blk .{ .integer = n };
            },
            .boolean => switch (value) {
                .true => Value{ .boolean = true },
                .false => Value{ .boolean = false },
                else => return s.fail(error.Params, "argument is not a boolean"),
            },
            .enumeration => blk: {
                const text = tokenString(value) orelse return s.fail(error.Params, "argument is not a string");
                const choice = for (field.choices, 0..) |c, i| {
                    if (std.mem.eql(u8, c, text)) break i;
                } else return s.fail(error.Params, "argument is not one of the allowed values");
                break :blk .{ .choice = choice };
            },
        };
    }
}

fn stringOf(out: []?Value, index: usize, default: []const u8) []const u8 {
    return if (out[index]) |v| v.string else default;
}

fn integerOf(out: []?Value, index: usize, default: u64) u64 {
    return if (out[index]) |v| v.integer else default;
}

fn booleanOf(out: []?Value, index: usize, default: bool) bool {
    return if (out[index]) |v| v.boolean else default;
}

fn choiceOf(out: []?Value, index: usize, default: usize) usize {
    return if (out[index]) |v| v.choice else default;
}

fn consistencyOf(index: usize) core.RequestConsistency {
    return switch (index) {
        0 => .checked_live,
        1 => .managed_generation,
        else => .bounded_stale,
    };
}

fn decodeArgs(s: *State, request: *Request, arguments: []const u8) Error!void {
    var scanner = Scanner.initCompleteInput(s.arena, arguments);
    defer scanner.deinit();

    if (request.tool == .batch_read) return decodeBatchArgs(s, request, &scanner, arguments);

    const fields = fieldsFor(request.tool);
    var values: [16]?Value = @splat(null);
    try readFields(s, &scanner, fields, values[0..fields.len]);
    if (try nextToken(&scanner, s.arena) != .end_of_document) return s.fail(error.Params, "trailing bytes after the arguments");
    const out = values[0..fields.len];
    const common = fields.len - common_fields.len;
    request.output_bytes = integerOf(out, common, core.limits.values.default_output_bytes);
    request.deadline_ms = @intCast(integerOf(out, common + 1, core.limits.values.default_deadline_ms));

    switch (request.tool) {
        .read => {
            if (out[0] == null) return s.fail(error.Params, "path is missing");
            request.args = .{ .read = .{
                .path = .{ .bytes = stringOf(out, 0, "") },
                .lines = .{ .first = @intCast(integerOf(out, 1, 1)), .count = @intCast(integerOf(out, 2, core.limits.values.default_read_lines)) },
                .write_intent = booleanOf(out, 3, false),
                .consistency = consistencyOf(choiceOf(out, 4, 0)),
                .output_bytes = request.output_bytes,
                .deadline_ms = request.deadline_ms,
            } };
        },
        .files => {
            request.args = .{ .files = .{
                .glob = stringOf(out, 0, "**/*"),
                .limit = @intCast(integerOf(out, 1, 1000)),
                .include_hidden = booleanOf(out, 2, false),
                .order = if (choiceOf(out, 3, 0) == 0) .discovery else .path_then_offset,
                .consistency = consistencyOf(choiceOf(out, 4, 0)),
                .max_stale_ms = @intCast(integerOf(out, 5, 0)),
            } };
        },
        .search => {
            if (out[0] == null) return s.fail(error.Params, "literal is missing");
            request.args = .{ .search = .{
                .literal = stringOf(out, 0, ""),
                .glob = stringOf(out, 1, "**/*"),
                .context_lines = @intCast(integerOf(out, 2, 2)),
                .limit = @intCast(integerOf(out, 3, core.limits.values.default_search_matches)),
                .max_file_bytes = integerOf(out, 4, core.limits.values.default_search_file_bytes),
                .include_hidden = booleanOf(out, 5, false),
                .order = if (choiceOf(out, 6, 0) == 0) .discovery else .path_then_offset,
                .consistency = consistencyOf(choiceOf(out, 7, 0)),
                .max_stale_ms = @intCast(integerOf(out, 8, 0)),
            } };
        },
        .status => request.args = .{ .status = .{
            .receipt_id = if (out[0]) |v| v.string else null,
            .output_bytes = request.output_bytes,
            .deadline_ms = request.deadline_ms,
        } },
        .health => request.args = .{ .health = .{ .output_bytes = request.output_bytes, .deadline_ms = request.deadline_ms } },
        else => {},
    }
}

fn decodeBatchArgs(s: *State, request: *Request, scanner: *Scanner, arguments: []const u8) Error!void {
    _ = arguments;
    if (try nextToken(scanner, s.arena) != .object_begin) return s.fail(error.Params, "arguments must be an object");
    var items: std.ArrayList(core.BatchReadItem) = .empty;
    var seen: struct { items: bool = false, output: bool = false, deadline: bool = false } = .{};

    while (true) {
        const token = try nextToken(scanner, s.arena);
        if (token == .object_end) break;
        const key = tokenString(token) orelse return s.fail(error.Params, "object key is not a string");
        if (std.mem.eql(u8, key, "items")) {
            if (seen.items) return s.fail(error.Params, "duplicate argument");
            seen.items = true;
            if (try nextToken(scanner, s.arena) != .array_begin) return s.fail(error.Params, "items is not an array");
            while (true) {
                const peek = scanner.peekNextTokenType() catch return error.Parse;
                if (peek == .array_end) {
                    _ = try nextToken(scanner, s.arena);
                    break;
                }
                if (items.items.len == core.limits.values.max_batch_items) return s.fail(error.Params, "more than 32 items");
                var values: [item_fields.len]?Value = @splat(null);
                try readFields(s, scanner, &item_fields, &values);
                const out: []?Value = &values;
                if (out[0] == null) return s.fail(error.Params, "item_id is missing");
                if (out[1] == null) return s.fail(error.Params, "item path is missing");
                try items.append(s.arena, .{
                    .item_id = stringOf(out, 0, ""),
                    .spec = .{
                        .path = .{ .bytes = stringOf(out, 1, "") },
                        .lines = .{ .first = @intCast(integerOf(out, 2, 1)), .count = @intCast(integerOf(out, 3, core.limits.values.default_read_lines)) },
                        .write_intent = booleanOf(out, 4, false),
                        .consistency = consistencyOf(choiceOf(out, 5, 0)),
                    },
                });
            }
        } else if (std.mem.eql(u8, key, "output_bytes")) {
            if (seen.output) return s.fail(error.Params, "duplicate argument");
            seen.output = true;
            const raw = tokenNumber(try nextToken(scanner, s.arena)) orelse return s.fail(error.Params, "output_bytes is not a number");
            const n = std.fmt.parseInt(u64, raw, 10) catch return s.fail(error.Params, "output_bytes is not an integer in range");
            if (n < 1024 or n > core.limits.values.max_output_bytes) return s.fail(error.Params, "output_bytes is out of range");
            request.output_bytes = n;
        } else if (std.mem.eql(u8, key, "deadline_ms")) {
            if (seen.deadline) return s.fail(error.Params, "duplicate argument");
            seen.deadline = true;
            const raw = tokenNumber(try nextToken(scanner, s.arena)) orelse return s.fail(error.Params, "deadline_ms is not a number");
            const n = std.fmt.parseInt(u32, raw, 10) catch return s.fail(error.Params, "deadline_ms is not an integer in range");
            if (n < 1 or n > core.limits.values.max_deadline_ms) return s.fail(error.Params, "deadline_ms is out of range");
            request.deadline_ms = n;
        } else {
            return s.fail(error.Params, "unknown argument");
        }
    }
    if (try nextToken(scanner, s.arena) != .end_of_document) return s.fail(error.Params, "trailing bytes after the arguments");
    if (!seen.items or items.items.len == 0) return s.fail(error.Params, "items is missing or empty");

    // Per-item output budgets are not in the tool schema; every item may use the batch budget.
    for (items.items) |*item| item.spec.output_bytes = request.output_bytes;
    request.args = .{ .batch_read = .{ .items = items.items, .output_bytes = request.output_bytes, .deadline_ms = request.deadline_ms } };
}

// ------------------------------------------------------------------ encoding

const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn raw(o: *Out, bytes: []const u8) error{NoSpace}!void {
        if (o.buf.len - o.len < bytes.len) return error.NoSpace;
        @memcpy(o.buf[o.len..][0..bytes.len], bytes);
        o.len += bytes.len;
    }

    fn int(o: *Out, value: anytype) error{NoSpace}!void {
        var tmp: [24]u8 = undefined;
        try o.raw(std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable);
    }

    fn string(o: *Out, bytes: []const u8) error{NoSpace}!void {
        try o.raw("\"");
        var run: usize = 0;
        for (bytes, 0..) |c, i| {
            const escape: ?[]const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0x08 => "\\b",
                0x0c => "\\f",
                else => null,
            };
            if (escape == null and c >= 0x20) continue;
            try o.raw(bytes[run..i]);
            if (escape) |e| {
                try o.raw(e);
            } else {
                var tmp: [6]u8 = undefined;
                try o.raw(std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable);
            }
            run = i + 1;
        }
        try o.raw(bytes[run..]);
        try o.raw("\"");
    }

    fn id(o: *Out, value: Id) error{NoSpace}!void {
        switch (value) {
            .none => try o.raw("null"),
            .number => |n| try o.int(n),
            .string => |text| try o.string(text),
        }
    }
};

fn head(o: *Out, value: Id) error{NoSpace}!void {
    try o.raw("{\"jsonrpc\":\"" ++ jsonrpc_version ++ "\",\"id\":");
    try o.id(value);
}

/// `{"jsonrpc":"2.0","id":...,"result":<result>}`
pub fn encodeResult(out: []u8, id: Id, result: []const u8) error{NoSpace}!usize {
    var o: Out = .{ .buf = out };
    try head(&o, id);
    try o.raw(",\"result\":");
    try o.raw(result);
    try o.raw("}");
    return o.len;
}

/// A `tools/call` result: one text block with the logical response, plus `isError`.
pub fn encodeToolResult(out: []u8, id: Id, text: []const u8, is_error: bool) error{NoSpace}!usize {
    var o: Out = .{ .buf = out };
    try head(&o, id);
    try o.raw(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try o.string(text);
    try o.raw("}],\"isError\":");
    try o.raw(if (is_error) "true" else "false");
    try o.raw("}}");
    return o.len;
}

/// `{"jsonrpc":"2.0","id":...,"error":{"code":...,"message":...,"data":...}}`
pub fn encodeError(out: []u8, fault: Fault, data: ?[]const u8) error{NoSpace}!usize {
    var o: Out = .{ .buf = out };
    try head(&o, fault.id);
    try o.raw(",\"error\":{\"code\":");
    try o.int(fault.code);
    try o.raw(",\"message\":");
    try o.string(fault.message);
    if (data) |extra| {
        try o.raw(",\"data\":");
        try o.string(extra);
    }
    try o.raw("}}");
    return o.len;
}

/// The zcr/1 envelope around data the projection does not encode (status, health).
pub fn encodeEnvelope(out: []u8, request_id: []const u8, workspace: ?core.WorkspaceId, generation: ?u64, data: []const u8) error{NoSpace}!usize {
    var o: Out = .{ .buf = out };
    try o.raw("{\"schema_version\":\"" ++ core.schema_version ++ "\",\"request_id\":");
    try o.string(request_id);
    try o.raw(",\"workspace_id\":");
    if (workspace) |id| {
        try o.raw("\"");
        try o.raw(&std.fmt.bytesToHex(id.registry_uuid, .lower));
        try o.raw(":");
        try o.raw(&std.fmt.bytesToHex(id.incarnation, .lower));
        try o.raw("\"");
    } else {
        try o.raw("null");
    }
    try o.raw(",\"generation\":");
    if (generation) |g| try o.int(g) else try o.raw("null");
    try o.raw(",\"ok\":true,\"complete\":true,\"truncated\":false,\"consistency\":\"not_applicable\"," ++
        "\"coverage\":{\"scope\":\"session\",\"skipped\":0,\"index_state\":\"not_applicable\"},\"data\":");
    try o.raw(data);
    try o.raw(",\"error\":null,\"meta\":{\"returned_bytes\":");
    try o.int(data.len);
    try o.raw("}}");
    return o.len;
}

/// Bytes `encodeToolResult` needs for a text of `text_len` bytes.
pub fn toolResultBytes(id: Id, text_len: usize) usize {
    const id_bytes: usize = switch (id) {
        .none => 4,
        .number => 24,
        .string => |text| 6 * text.len + 2,
    };
    return 96 + id_bytes + 6 * text_len;
}
