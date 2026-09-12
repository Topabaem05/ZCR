//! Bounded JSON validation and JSON-RPC request decoding for direct stdio MCP.
//! Preflight needs no allocator. Its fixed key table is 128 KiB; exceeding the
//! 4096-key or 65536-value parser resource limit is an explicit resource error.
//! All allocations in `parse` use the caller's admitted request allocator.
const std = @import("std");

pub const max_frame_bytes: usize = 16 * 1024 * 1024;
pub const max_depth: usize = 64;
pub const max_object_keys: usize = 4096;
pub const max_values: usize = 65536;
pub const PreflightError = error{ FrameTooLarge, DepthExceeded, DuplicateKey, InvalidJson, ResourceExhausted };
pub const ValueError = error{ InvalidArgument, UnknownField };

/// Validate supported tool schemas before constructing a DOM. Member order and
/// escaped member names do not affect dispatch or validation. This function
/// deliberately leaves session capabilities, policy, paths and unsupported tool
/// handling to the dispatcher. Malformed envelopes and non-tool messages
/// receive syntax preflight only so their normal RPC classification is retained.
pub fn preflightToolArguments(raw: []const u8) (PreflightError || ValueError)!void {
    try preflight(raw);
    const root: RawValue = .{ .raw = std.mem.trim(u8, raw, " \t\r\n") };
    const method = root.member("method") orelse return;
    if (!method.stringEquals("tools/call")) return;
    if (!(root.member("jsonrpc") orelse return).stringEquals("2.0")) return;
    if (!root.hasOnly(&.{ "jsonrpc", "id", "method", "params" })) return;
    _ = boundedRawId(root.member("id") orelse return) orelse return;
    const params = root.member("params") orelse return;
    if (!params.isObject() or !params.hasOnly(&.{ "name", "arguments", "_meta" })) return;
    const name = params.member("name") orelse return;
    const arguments = params.member("arguments") orelse RawValue{ .raw = "{}" };
    if (!arguments.isObject()) return;
    const schema = argumentSchema(name) orelse return;
    validateRawArguments(arguments, schema) catch return error.InvalidArgument;
}

/// Return only a valid bounded request id's original JSON token, so an early
/// schema failure can be answered without decoding the rejected arguments.
/// The returned slice borrows raw; parse this small token to obtain a Value.
/// Missing, null, out-of-range or invalid-type ids return null.
pub fn rawRequestId(raw: []const u8) PreflightError!?[]const u8 {
    try preflight(raw);
    const root: RawValue = .{ .raw = std.mem.trim(u8, raw, " \t\r\n") };
    const id = root.member("id") orelse return null;
    return boundedRawId(id);
}

/// Return a static canonical tool name without decoding the request. The
/// caller must successfully run preflight(raw) before invoking this accessor.
/// Unknown names and messages other than tools/call return null.
pub fn toolName(raw: []const u8) ?[]const u8 {
    const root: RawValue = .{ .raw = std.mem.trim(u8, raw, " \t\r\n") };
    if (!(root.member("method") orelse return null).stringEquals("tools/call")) return null;
    const params = root.member("params") orelse return null;
    const name = params.member("name") orelse return null;
    for ([_][]const u8{ "zcr_read", "zcr_files", "zcr_search", "zcr_batch_read", "zcr_status", "zcr_health", "zcr_patch", "zcr_create" }) |canonical| {
        if (name.stringEquals(canonical)) return canonical;
    }
    return null;
}

fn boundedRawId(id: RawValue) ?[]const u8 {
    if (id.raw[0] == '"') {
        id.textLength(0, 256) catch return null;
    } else {
        _ = asInteger(.{ .number_string = id.raw }) catch return null;
    }
    return id.raw;
}

const RawValue = struct {
    raw: []const u8,

    fn isObject(value: RawValue) bool {
        return value.raw[0] == '{';
    }

    fn member(value: RawValue, name: []const u8) ?RawValue {
        if (!value.isObject()) return null;
        var members: RawObjectIterator = .{ .cursor = .{ .raw = value.raw, .at = 1 } };
        while (members.next()) |entry| if (entry.key.stringEquals(name)) return entry.value;
        return null;
    }

    fn hasOnly(value: RawValue, names: []const []const u8) bool {
        if (!value.isObject()) return false;
        var members: RawObjectIterator = .{ .cursor = .{ .raw = value.raw, .at = 1 } };
        while (members.next()) |entry| {
            for (names) |name| {
                if (entry.key.stringEquals(name)) break;
            } else return false;
        }
        return true;
    }

    fn stringEquals(value: RawValue, ascii: []const u8) bool {
        if (value.raw[0] != '"') return false;
        var string: StringIterator = .{ .raw = value.raw, .at = 1 };
        var i: usize = 0;
        while (string.next() catch unreachable) |codepoint| : (i += 1) {
            if (i == ascii.len or codepoint != ascii[i]) return false;
        }
        return i == ascii.len;
    }

    fn textLength(value: RawValue, minimum: usize, maximum: usize) ValueError!void {
        if (value.raw[0] != '"') return error.InvalidArgument;
        var string: StringIterator = .{ .raw = value.raw, .at = 1 };
        var length: usize = 0;
        while (string.next() catch unreachable) |codepoint| {
            length += std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            if (length > maximum) return error.InvalidArgument;
        }
        if (length < minimum) return error.InvalidArgument;
    }
};

/// This cursor only visits input already accepted by preflight. Skipping a
/// value scans its original bytes without copying or unescaping its strings.
const RawCursor = struct {
    raw: []const u8,
    at: usize = 0,

    fn whitespace(cursor: *RawCursor) void {
        while (cursor.at < cursor.raw.len and std.mem.indexOfScalar(u8, " \t\r\n", cursor.raw[cursor.at]) != null) cursor.at += 1;
    }

    fn skipString(cursor: *RawCursor) void {
        std.debug.assert(cursor.raw[cursor.at] == '"');
        cursor.at += 1;
        while (true) {
            const byte = cursor.raw[cursor.at];
            cursor.at += 1;
            if (byte == '"') return;
            if (byte == '\\') cursor.at += 1;
        }
    }

    fn takeValue(cursor: *RawCursor) RawValue {
        cursor.whitespace();
        const start = cursor.at;
        switch (cursor.raw[cursor.at]) {
            '"' => cursor.skipString(),
            '{', '[' => {
                var depth: usize = 1;
                cursor.at += 1;
                while (depth != 0) {
                    switch (cursor.raw[cursor.at]) {
                        '"' => {
                            cursor.skipString();
                            continue;
                        },
                        '{', '[' => depth += 1,
                        '}', ']' => depth -= 1,
                        else => {},
                    }
                    cursor.at += 1;
                }
            },
            else => while (cursor.at < cursor.raw.len and std.mem.indexOfScalar(u8, " \t\r\n,]}", cursor.raw[cursor.at]) == null) {
                cursor.at += 1;
            },
        }
        return .{ .raw = cursor.raw[start..cursor.at] };
    }
};

const RawObjectIterator = struct {
    cursor: RawCursor,
    const Member = struct { key: RawValue, value: RawValue };

    fn next(iterator: *RawObjectIterator) ?Member {
        const cursor = &iterator.cursor;
        cursor.whitespace();
        if (cursor.raw[cursor.at] == '}') return null;
        const key_start = cursor.at;
        cursor.skipString();
        const key: RawValue = .{ .raw = cursor.raw[key_start..cursor.at] };
        cursor.whitespace();
        std.debug.assert(cursor.raw[cursor.at] == ':');
        cursor.at += 1;
        const value = cursor.takeValue();
        cursor.whitespace();
        if (cursor.raw[cursor.at] == ',') cursor.at += 1;
        return .{ .key = key, .value = value };
    }
};

const FieldKind = union(enum) {
    text: struct { min: usize = 1, max: usize },
    uint: struct { min: u64, max: u64 },
    boolean,
    choice: []const []const u8,
    items,
};
const ArgumentField = struct { name: []const u8, kind: FieldKind, required: bool = false };

const output_field: ArgumentField = .{ .name = "output_bytes", .kind = .{ .uint = .{ .min = 1024, .max = 2097152 } } };
const deadline_field: ArgumentField = .{ .name = "deadline_ms", .kind = .{ .uint = .{ .min = 1, .max = 60000 } } };
const path_field: ArgumentField = .{ .name = "path", .kind = .{ .text = .{ .max = 4096 } }, .required = true };
const consistency_field: ArgumentField = .{ .name = "consistency", .kind = .{ .choice = &.{ "checked_live", "managed_generation", "bounded_stale" } } };
const order_field: ArgumentField = .{ .name = "order", .kind = .{ .choice = &.{ "discovery", "path_then_offset" } } };
const glob_field: ArgumentField = .{ .name = "glob", .kind = .{ .text = .{ .max = 4096 } } };
const hidden_field: ArgumentField = .{ .name = "include_hidden", .kind = .boolean };
const stale_field: ArgumentField = .{ .name = "max_stale_ms", .kind = .{ .uint = .{ .min = 0, .max = 60000 } } };
const read_fields = [_]ArgumentField{
    path_field,
    .{ .name = "start_line", .kind = .{ .uint = .{ .min = 1, .max = 4294967295 } } },
    .{ .name = "line_count", .kind = .{ .uint = .{ .min = 1, .max = 5000 } } },
    .{ .name = "write_intent", .kind = .boolean },
    consistency_field,
};
const batch_item_fields = read_fields ++ [_]ArgumentField{.{ .name = "item_id", .kind = .{ .text = .{ .max = 64 } }, .required = true }};
const common_fields = [_]ArgumentField{ output_field, deadline_field };
const files_fields = [_]ArgumentField{
    glob_field,
    .{ .name = "limit", .kind = .{ .uint = .{ .min = 1, .max = 10000 } } },
    hidden_field,
    order_field,
    consistency_field,
    stale_field,
} ++ common_fields;
const search_fields = [_]ArgumentField{
    .{ .name = "literal", .kind = .{ .text = .{ .max = 4096 } }, .required = true },
    glob_field,
    .{ .name = "context_lines", .kind = .{ .uint = .{ .min = 0, .max = 20 } } },
    .{ .name = "limit", .kind = .{ .uint = .{ .min = 1, .max = 1000 } } },
    .{ .name = "max_file_bytes", .kind = .{ .uint = .{ .min = 1, .max = 1073741824 } } },
    hidden_field,
    order_field,
    consistency_field,
    stale_field,
} ++ common_fields;

fn argumentSchema(name: RawValue) ?[]const ArgumentField {
    if (name.stringEquals("zcr_read")) return &(read_fields ++ common_fields);
    if (name.stringEquals("zcr_files")) return &files_fields;
    if (name.stringEquals("zcr_search")) return &search_fields;
    if (name.stringEquals("zcr_batch_read")) return &([_]ArgumentField{.{ .name = "items", .kind = .items, .required = true }} ++ common_fields);
    if (name.stringEquals("zcr_status")) return &([_]ArgumentField{.{ .name = "receipt_id", .kind = .{ .text = .{ .max = 128 } } }} ++ common_fields);
    if (name.stringEquals("zcr_health")) return &common_fields;
    return null;
}

fn validateRawArguments(arguments: RawValue, schema: []const ArgumentField) ValueError!void {
    if (!arguments.isObject()) return error.InvalidArgument;
    std.debug.assert(schema.len <= 16);
    var seen: [16]bool = @splat(false);
    var members: RawObjectIterator = .{ .cursor = .{ .raw = arguments.raw, .at = 1 } };
    while (members.next()) |entry| {
        const field_index = for (schema, 0..) |field, i| {
            if (entry.key.stringEquals(field.name)) break i;
        } else return error.UnknownField;
        seen[field_index] = true;
        switch (schema[field_index].kind) {
            .text => |limit| try entry.value.textLength(limit.min, limit.max),
            .uint => |limit| {
                const number = try asUnsigned(.{ .number_string = entry.value.raw }, limit.max);
                if (number < limit.min) return error.InvalidArgument;
            },
            .boolean => {
                if (!std.mem.eql(u8, entry.value.raw, "true") and !std.mem.eql(u8, entry.value.raw, "false")) return error.InvalidArgument;
            },
            .choice => |choices| {
                for (choices) |choice| {
                    if (entry.value.stringEquals(choice)) break;
                } else return error.InvalidArgument;
            },
            .items => {
                if (entry.value.raw[0] != '[') return error.InvalidArgument;
                var cursor: RawCursor = .{ .raw = entry.value.raw, .at = 1 };
                var count: usize = 0;
                cursor.whitespace();
                while (cursor.raw[cursor.at] != ']') {
                    if (count == 32) return error.InvalidArgument;
                    const item = cursor.takeValue();
                    try validateRawArguments(item, &batch_item_fields);
                    count += 1;
                    cursor.whitespace();
                    if (cursor.raw[cursor.at] == ',') {
                        cursor.at += 1;
                        cursor.whitespace();
                    }
                }
                if (count == 0) return error.InvalidArgument;
            },
        }
    }
    for (schema, 0..) |field, i| if (field.required and !seen[i]) return error.InvalidArgument;
}

/// Validate the entire frame before allowing a JSON DOM allocation. Depth is
/// the number of open arrays/objects: 64 nested containers are accepted.
pub fn preflight(raw: []const u8) PreflightError!void {
    if (raw.len > max_frame_bytes) return error.FrameTooLarge;
    if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidJson;
    var scan: Scanner = .{ .raw = raw };
    try scan.value(0);
    scan.whitespace();
    if (scan.at != raw.len) return error.InvalidJson;
}

/// The caller must reserve input and parser credit before providing its
/// allocator. Returned strings and number lexemes live until parsed.deinit().
/// Keeping numbers as lexemes prevents floating-point precision loss or
/// silently accepting overflow when converting a tool argument or RPC id.
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !std.json.Parsed(std.json.Value) {
    try preflight(raw);
    return std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = max_frame_bytes,
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateKey,
        else => return err,
    };
}

pub fn asObject(value: std.json.Value) ValueError!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidArgument;
}

pub fn asString(value: std.json.Value) ValueError![]const u8 {
    return if (value == .string) value.string else error.InvalidArgument;
}

pub fn asUnsigned(value: std.json.Value, maximum: u64) ValueError!u64 {
    const result: u64 = switch (value) {
        .integer => |number| std.math.cast(u64, number) orelse return error.InvalidArgument,
        .number_string => |number| blk: {
            if (!integerLexeme(number) or number[0] == '-') return error.InvalidArgument;
            break :blk std.fmt.parseInt(u64, number, 10) catch return error.InvalidArgument;
        },
        else => return error.InvalidArgument,
    };
    if (result > maximum) return error.InvalidArgument;
    return result;
}

pub fn asInteger(value: std.json.Value) ValueError!i64 {
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| blk: {
            if (!integerLexeme(number)) return error.InvalidArgument;
            break :blk std.fmt.parseInt(i64, number, 10) catch return error.InvalidArgument;
        },
        else => error.InvalidArgument,
    };
}

fn integerLexeme(number: []const u8) bool {
    if (number.len == 0) return false;
    const start: usize = @intFromBool(number[0] == '-');
    if (start == number.len) return false;
    if (number.len - start > 1 and number[start] == '0') return false;
    for (number[start..]) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

pub fn rejectUnknownFields(object: std.json.ObjectMap, allowed: []const []const u8) ValueError!void {
    for (object.keys()) |key| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, key, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownField;
    }
}

pub const RequestId = union(enum) {
    string: []const u8,
    integer: i64,

    pub fn eql(a: RequestId, b: RequestId) bool {
        return switch (a) {
            .string => |text| b == .string and std.mem.eql(u8, text, b.string),
            .integer => |number| b == .integer and number == b.integer,
        };
    }
};

pub const Envelope = struct {
    /// Null means no id member (a notification); a JSON null id is invalid.
    id: ?RequestId,
    method: []const u8,
    params: ?std.json.Value,
};

pub fn requestId(value: std.json.Value) ValueError!RequestId {
    return if (value == .string) .{ .string = value.string } else .{ .integer = try asInteger(value) };
}

/// Request/notification envelopes only. Response envelopes and JSON-RPC batch
/// arrays are intentionally excluded from the MCP request dispatcher.
pub fn envelope(value: std.json.Value) error{InvalidRequest}!Envelope {
    const object = asObject(value) catch return error.InvalidRequest;
    rejectUnknownFields(object, &.{ "jsonrpc", "id", "method", "params" }) catch return error.InvalidRequest;
    const version = asString(object.get("jsonrpc") orelse return error.InvalidRequest) catch return error.InvalidRequest;
    if (!std.mem.eql(u8, version, "2.0")) return error.InvalidRequest;
    const method = asString(object.get("method") orelse return error.InvalidRequest) catch return error.InvalidRequest;
    const id: ?RequestId = if (object.get("id")) |id_value| tryId: {
        break :tryId requestId(id_value) catch return error.InvalidRequest;
    } else null;
    const params = object.get("params");
    if (params) |parameters| {
        if (parameters != .object and parameters != .array) return error.InvalidRequest;
    }
    return .{ .id = id, .method = method, .params = params };
}

const Key = struct { hash: u64 = 0, object: u32 = 0, start: u32 = 0 };
const key_slots = max_object_keys * 2;

const Scanner = struct {
    raw: []const u8,
    at: usize = 0,
    key_count: usize = 0,
    value_count: usize = 0,
    keys: [key_slots]Key = @splat(.{}),

    fn whitespace(s: *Scanner) void {
        while (s.at < s.raw.len) : (s.at += 1) {
            switch (s.raw[s.at]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn take(s: *Scanner, byte: u8) bool {
        if (s.at == s.raw.len or s.raw[s.at] != byte) return false;
        s.at += 1;
        return true;
    }

    fn value(s: *Scanner, depth: usize) PreflightError!void {
        s.whitespace();
        if (s.at == s.raw.len) return error.InvalidJson;
        if (s.value_count == max_values) return error.ResourceExhausted;
        s.value_count += 1;
        switch (s.raw[s.at]) {
            '{' => {
                if (depth == max_depth) return error.DepthExceeded;
                const object_start = s.at;
                s.at += 1;
                s.whitespace();
                if (s.take('}')) return;
                while (true) {
                    const key_start = s.at;
                    try s.string();
                    try s.addKey(object_start, key_start);
                    s.whitespace();
                    if (!s.take(':')) return error.InvalidJson;
                    try s.value(depth + 1);
                    s.whitespace();
                    if (s.take('}')) return;
                    if (!s.take(',')) return error.InvalidJson;
                    s.whitespace();
                }
            },
            '[' => {
                if (depth == max_depth) return error.DepthExceeded;
                s.at += 1;
                s.whitespace();
                if (s.take(']')) return;
                while (true) {
                    try s.value(depth + 1);
                    s.whitespace();
                    if (s.take(']')) return;
                    if (!s.take(',')) return error.InvalidJson;
                }
            },
            '"' => try s.string(),
            't' => try s.literal("true"),
            'f' => try s.literal("false"),
            'n' => try s.literal("null"),
            '-', '0'...'9' => try s.number(),
            else => return error.InvalidJson,
        }
    }

    fn literal(s: *Scanner, expected: []const u8) PreflightError!void {
        if (!std.mem.startsWith(u8, s.raw[s.at..], expected)) return error.InvalidJson;
        s.at += expected.len;
    }

    fn number(s: *Scanner) PreflightError!void {
        _ = s.take('-');
        if (s.at == s.raw.len) return error.InvalidJson;
        if (!s.take('0')) {
            if (s.raw[s.at] < '1' or s.raw[s.at] > '9') return error.InvalidJson;
            s.digits();
        }
        if (s.take('.')) {
            const start = s.at;
            s.digits();
            if (s.at == start) return error.InvalidJson;
        }
        if (s.take('e') or s.take('E')) {
            if (!s.take('+')) _ = s.take('-');
            const start = s.at;
            s.digits();
            if (s.at == start) return error.InvalidJson;
        }
    }

    fn digits(s: *Scanner) void {
        while (s.at < s.raw.len and s.raw[s.at] >= '0' and s.raw[s.at] <= '9') s.at += 1;
    }

    fn string(s: *Scanner) PreflightError!void {
        if (!s.take('"')) return error.InvalidJson;
        var iterator: StringIterator = .{ .raw = s.raw, .at = s.at };
        while (try iterator.next()) |_| {}
        s.at = iterator.at;
    }

    fn addKey(s: *Scanner, object: usize, start: usize) PreflightError!void {
        var hash = std.hash.Wyhash.init(@intCast(object));
        var iterator: StringIterator = .{ .raw = s.raw, .at = start + 1 };
        while (try iterator.next()) |codepoint| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, codepoint, .little);
            hash.update(&bytes);
        }
        const key_hash = hash.final();
        var slot: usize = @intCast(key_hash % key_slots);
        while (s.keys[slot].start != 0) : (slot = (slot + 1) % key_slots) {
            const key = s.keys[slot];
            if (key.hash == key_hash and key.object == object and keysEqual(s.raw, key.start, start)) return error.DuplicateKey;
        }
        if (s.key_count == max_object_keys) return error.ResourceExhausted;
        s.keys[slot] = .{ .hash = key_hash, .object = @intCast(object), .start = @intCast(start) };
        s.key_count += 1;
    }
};

/// Iterate decoded Unicode scalar values without allocating a decoded string.
/// Different spellings of the same escape/raw UTF-8 key compare identically.
const StringIterator = struct {
    raw: []const u8,
    at: usize,

    fn next(s: *StringIterator) PreflightError!?u21 {
        if (s.at == s.raw.len) return error.InvalidJson;
        const byte = s.raw[s.at];
        s.at += 1;
        if (byte == '"') return null;
        if (byte < 0x20) return error.InvalidJson;
        if (byte == '\\') {
            if (s.at == s.raw.len) return error.InvalidJson;
            const escape = s.raw[s.at];
            s.at += 1;
            return switch (escape) {
                '"', '\\', '/' => escape,
                'b' => 8,
                'f' => 12,
                'n' => 10,
                'r' => 13,
                't' => 9,
                'u' => blk: {
                    const first = try s.hexUnit();
                    if (first >= 0xdc00 and first <= 0xdfff) return error.InvalidJson;
                    if (first < 0xd800 or first > 0xdbff) break :blk first;
                    if (s.raw.len - s.at < 2 or s.raw[s.at] != '\\' or s.raw[s.at + 1] != 'u') return error.InvalidJson;
                    s.at += 2;
                    const second = try s.hexUnit();
                    if (second < 0xdc00 or second > 0xdfff) return error.InvalidJson;
                    break :blk 0x10000 + ((@as(u21, first) - 0xd800) << 10) + (@as(u21, second) - 0xdc00);
                },
                else => error.InvalidJson,
            };
        }
        if (byte < 0x80) return byte;
        const length = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidJson;
        const start = s.at - 1;
        if (length > s.raw.len - start) return error.InvalidJson;
        s.at = start + length;
        return std.unicode.utf8Decode(s.raw[start..s.at]) catch return error.InvalidJson;
    }

    fn hexUnit(s: *StringIterator) PreflightError!u16 {
        if (s.raw.len - s.at < 4) return error.InvalidJson;
        var result: u16 = 0;
        for (s.raw[s.at..][0..4]) |byte| {
            const digit: u16 = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => return error.InvalidJson,
            };
            result = (result << 4) | digit;
        }
        s.at += 4;
        return result;
    }
};

fn keysEqual(raw: []const u8, a: usize, b: usize) bool {
    var left: StringIterator = .{ .raw = raw, .at = a + 1 };
    var right: StringIterator = .{ .raw = raw, .at = b + 1 };
    while (true) {
        // Both complete keys were already validated by Scanner.string.
        const l = left.next() catch unreachable;
        const r = right.next() catch unreachable;
        if (l != r) return false;
        if (l == null) return true;
    }
}

test "MC-003 codec preflight rejects decoded duplicate keys" {
    try preflight("{\"a\":1,\"nested\":{\"a\":2}}");
    try std.testing.expectError(error.DuplicateKey, preflight("{\"a\":1,\"\\u0061\":2}"));
    try std.testing.expectError(error.DuplicateKey, preflight("{\"😀\":1,\"\\uD83D\\uDE00\":2}"));
    try std.testing.expectError(error.DuplicateKey, preflight("{\"x\":{\"a\":0},\"\\u0078\":1}"));
    try std.testing.expectError(error.DuplicateKey, preflight("{\"\\u0000\":1,\"\\u0000\":2}"));
    try std.testing.expectError(error.DuplicateKey, preflight("{\"/\":1,\"\\/\":2}"));
    try preflight("{\"A\":1,\"a\":2,\"é\":3,\"e\\u0301\":4}");
}

test "MC-003 codec validates JSON strings numbers UTF-8 and complete document" {
    const invalid = [_][]const u8{
        "",                 " ",           "{",           "[",           "{a:1}",              "{\"a\" 1}",      "{\"a\":}",
        "{\"a\":1,}",       "[1,]",        "[1 2]",       "{}{}",        "null null",          "TRUE",           "+1",
        "01",               "-01",         "-",           ".1",          "1.",                 "1e",             "1E+",
        "1e-",              "NaN",         "Infinity",    "-Infinity",   "tru",                "falsex",         "\"\n\"",
        "\"\\x\"",          "\"\\u00xz\"", "\"\\uD800\"", "\"\\uDC00\"", "\"\\uD800\\u0041\"", "\"unterminated", "\"\xc0\x80\"",
        "\"\xed\xa0\x80\"",
    };
    for (invalid) |raw| try std.testing.expectError(error.InvalidJson, preflight(raw));
    const valid = [_][]const u8{
        "null",                                         "true",                           "false", "0", "-0", "-1", "12.5", "1e+4", "-2.5E-10",
        " {\"a\":[true,false,null,0],\"z\":{}} \t\r\n", "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"",
        "\"한글é😀\\uD83D\\uDE00\"",
        "{\"a\":1,\"b\":{\"a\":2},\"c\":{\"a\":3}}",
    };
    for (valid) |raw| try preflight(raw);
}

test "MC-003 codec enforces exact depth and frame limits before allocation" {
    var nested: [2 * (max_depth + 1)]u8 = undefined;
    @memset(nested[0..max_depth], '[');
    @memset(nested[max_depth..][0..max_depth], ']');
    try preflight(nested[0 .. 2 * max_depth]);
    @memset(nested[0 .. max_depth + 1], '[');
    @memset(nested[max_depth + 1 ..], ']');
    try std.testing.expectError(error.DepthExceeded, preflight(&nested));

    const raw = try std.testing.allocator.alloc(u8, max_frame_bytes + 1);
    defer std.testing.allocator.free(raw);
    @memset(raw, ' ');
    raw[0] = '0';
    try preflight(raw[0..max_frame_bytes]);
    try std.testing.expectError(error.FrameTooLarge, preflight(raw));
    var empty: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&empty);
    try std.testing.expectError(error.FrameTooLarge, parse(allocator.allocator(), raw));
    try std.testing.expectError(error.DepthExceeded, parse(allocator.allocator(), &nested));
    try std.testing.expectError(error.DuplicateKey, parse(allocator.allocator(), "{\"a\":1,\"\\u0061\":2}"));
}

test "MC-003 codec resource limits bound object tables and flat arrays" {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(std.testing.allocator);
    try raw.append(std.testing.allocator, '{');
    for (0..max_object_keys) |i| {
        var buffer: [40]u8 = undefined;
        const entry = try std.fmt.bufPrint(&buffer, "{s}\"k{d}\":0", .{ if (i == 0) "" else ",", i });
        try raw.appendSlice(std.testing.allocator, entry);
    }
    try raw.append(std.testing.allocator, '}');
    try preflight(raw.items);
    raw.items.len -= 1;
    try raw.appendSlice(std.testing.allocator, ",\"overflow\":0}");
    try std.testing.expectError(error.ResourceExhausted, preflight(raw.items));

    raw.clearRetainingCapacity();
    try raw.append(std.testing.allocator, '[');
    for (0..max_values - 1) |i| try raw.appendSlice(std.testing.allocator, if (i == 0) "0" else ",0");
    try raw.append(std.testing.allocator, ']');
    try preflight(raw.items);
    raw.items.len -= 1;
    try raw.appendSlice(std.testing.allocator, ",0]");
    try std.testing.expectError(error.ResourceExhausted, preflight(raw.items));
}

test "MC-001 codec RPC envelope keeps id types and strict integer ranges" {
    var parsed = try parse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":9223372036854775807,\"params\":{\"u\":18446744073709551615}}");
    defer parsed.deinit();
    const request = try envelope(parsed.value);
    try std.testing.expectEqual(std.math.maxInt(i64), request.id.?.integer);
    try std.testing.expectEqual(std.math.maxInt(u64), try asUnsigned(request.params.?.object.get("u").?, std.math.maxInt(u64)));
    try std.testing.expectError(error.InvalidArgument, asInteger(request.params.?.object.get("u").?));
    try std.testing.expectError(error.InvalidArgument, asUnsigned(.{ .number_string = "18446744073709551616" }, std.math.maxInt(u64)));
    try std.testing.expectError(error.InvalidArgument, asUnsigned(.{ .number_string = "10" }, 9));
    try std.testing.expectError(error.InvalidArgument, asUnsigned(.{ .number_string = "-0" }, 9));
    for ([_][]const u8{ "1.0", "1e0", "01", "+1", "", "-", "9223372036854775808" }) |number| {
        try std.testing.expectError(error.InvalidArgument, asInteger(.{ .number_string = number }));
    }
    try std.testing.expectEqual(std.math.minInt(i64), try asInteger(.{ .number_string = "-9223372036854775808" }));
    try std.testing.expectError(error.UnknownField, rejectUnknownFields(request.params.?.object, &.{"other"}));
    try rejectUnknownFields(request.params.?.object, &.{"u"});

    var text = try parse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":\"17\"}");
    defer text.deinit();
    const text_id = (try envelope(text.value)).id.?;
    try std.testing.expectEqualStrings("17", text_id.string);
    try std.testing.expect(!RequestId.eql(text_id, .{ .integer = 17 }));
    try std.testing.expect(RequestId.eql(text_id, .{ .string = "17" }));

    const invalid = [_][]const u8{
        "[]",                                                   "{}",                                                                   "{\"jsonrpc\":\"1.0\",\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":1}",                   "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":null}",                "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":true}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":1.5}", "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":9223372036854775808}", "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":null}",
    };
    for (invalid) |raw| {
        var document = try parse(std.testing.allocator, raw);
        defer document.deinit();
        try std.testing.expectError(error.InvalidRequest, envelope(document.value));
    }
}

fn allocationFailureCase(allocator: std.mem.Allocator) !void {
    var parsed = try parse(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"\\u0061\",\"method\":\"ping\",\"params\":{\"nested\":[1,2,3]}}");
    defer parsed.deinit();
    const request = try envelope(parsed.value);
    try std.testing.expectEqualStrings("a", request.id.?.string);
}

test "MC-003 codec frees all DOM allocations on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}

test "MC-003 tool schema validation precedes decoded string allocation" {
    try std.testing.expectError(error.InvalidArgument, preflightToolArguments("{\"params\":{\"arguments\":{\"unknown\":\"large\",\"path\":\"a\"},\"name\":\"zcr_read\"},\"method\":\"tools/call\",\"id\":7,\"jsonrpc\":\"2.0\"}"));

    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(std.testing.allocator);
    try request.appendSlice(std.testing.allocator, "{\"params\":{\"arguments\":{\"unknown\":\"");
    try request.appendNTimes(std.testing.allocator, 'x', 2 * 1024 * 1024);
    try request.appendSlice(std.testing.allocator, "\",\"path\":\"a\"},\"name\":\"zcr_read\"},\"method\":\"tools/call\",\"id\":\"kept\\u002did\",\"jsonrpc\":\"2.0\"}");
    try std.testing.expectError(error.InvalidArgument, preflightToolArguments(request.items));
    try std.testing.expectEqualStrings("\"kept\\u002did\"", (try rawRequestId(request.items)).?);
    // Only the original bounded id token is decoded after preflight rejects
    // this frame; the two-megabyte unknown argument never needs a DOM.
    var small_buffer: [2048]u8 = undefined;
    var small_allocator = std.heap.FixedBufferAllocator.init(&small_buffer);
    var id = try parse(small_allocator.allocator(), (try rawRequestId(request.items)).?);
    defer id.deinit();
    try std.testing.expectEqualStrings("kept-id", id.value.string);
}

fn checkToolArguments(tool: []const u8, arguments: []const u8, expected: ?ValueError) !void {
    const raw = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":-43,\"params\":{{\"arguments\":{s},\"name\":\"{s}\"}},\"method\":\"tools/call\"}}", .{ arguments, tool });
    defer std.testing.allocator.free(raw);
    if (expected) |err| try std.testing.expectError(err, preflightToolArguments(raw)) else try preflightToolArguments(raw);
}

test "MC-003 raw tool schema checks all supported tools and nested batch fields" {
    try checkToolArguments("zcr_read", "{\"p\\u0061th\":\"a\",\"start_line\":4294967295,\"line_count\":5000,\"write_intent\":false,\"consistency\":\"checked_live\",\"output_bytes\":2097152,\"deadline_ms\":60000}", null);
    try checkToolArguments("zcr_files", "{\"glob\":\"**/*\",\"limit\":10000,\"include_hidden\":true,\"order\":\"discovery\",\"consistency\":\"managed_generation\",\"max_stale_ms\":60000,\"output_bytes\":1024,\"deadline_ms\":1}", null);
    try checkToolArguments("zcr_search", "{\"literal\":\"한글\",\"glob\":\"*.zig\",\"context_lines\":20,\"limit\":1000,\"max_file_bytes\":1073741824,\"include_hidden\":false,\"order\":\"path_then_offset\",\"consistency\":\"bounded_stale\",\"max_stale_ms\":0}", null);
    try checkToolArguments("zcr_batch_read", "{\"items\":[{\"item_id\":\"first\",\"path\":\"a\",\"line_count\":1},{\"item_id\":\"second\",\"path\":\"b\"}]}", null);
    try checkToolArguments("zcr_status", "{\"receipt_id\":\"known\"}", null);
    try checkToolArguments("zcr_health", "{}", null);
    try checkToolArguments("zcr_heal\\u0074h", "{\"deadline_ms\":0}", error.InvalidArgument);
    for ([_][]const u8{ "zcr_read", "zcr_files", "zcr_search", "zcr_batch_read", "zcr_status", "zcr_health" }) |tool| {
        try checkToolArguments(tool, "{\"unknown\":0}", error.InvalidArgument);
        try checkToolArguments(tool, "{\"outpu\\u0074_bytes\":1023}", error.InvalidArgument);
        try checkToolArguments(tool, "{\"deadline_ms\":60001}", error.InvalidArgument);
    }
    for ([_][]const u8{
        "{}",                                         "{\"path\":\"\"}",                      "{\"path\":1}",                          "{\"path\":\"a\",\"start_line\":0}",
        "{\"path\":\"a\",\"start_line\":4294967296}", "{\"path\":\"a\",\"line_count\":5001}", "{\"path\":\"a\",\"write_intent\":1}",   "{\"path\":\"a\",\"consistency\":\"unbounded\"}",
        "{\"path\":\"a\",\"line_count\":1.0}",        "{\"path\":\"a\",\"line_count\":1e0}",  "{\"path\":\"a\",\"line_count\":\"1\"}", "{\"path\":\"a\",\"line_count\":18446744073709551616}",
    }) |arguments| try checkToolArguments("zcr_read", arguments, error.InvalidArgument);
    for ([_][]const u8{
        "{}",                             "{\"items\":[]}",                    "{\"items\":{}}",                                                         "{\"items\":[null]}",
        "{\"items\":[{\"path\":\"a\"}]}", "{\"items\":[{\"item_id\":\"a\"}]}", "{\"items\":[{\"item_id\":\"a\",\"path\":\"a\",\"output_bytes\":1024}]}",
    }) |arguments| try checkToolArguments("zcr_batch_read", arguments, error.InvalidArgument);
    try checkToolArguments("zcr_search", "{\"literal\":\"a\",\"context_lines\":21}", error.InvalidArgument);
    try checkToolArguments("zcr_search", "{\"literal\":\"a\",\"max_file_bytes\":1073741825}", error.InvalidArgument);
    try checkToolArguments("zcr_files", "{\"limit\":10001}", error.InvalidArgument);
    try checkToolArguments("zcr_files", "{\"order\":null}", error.InvalidArgument);
}

test "MC-003 raw tool strings count decoded UTF-8 bytes and batch count is exact" {
    var arguments: std.ArrayList(u8) = .empty;
    defer arguments.deinit(std.testing.allocator);
    try arguments.appendSlice(std.testing.allocator, "{\"path\":\"");
    for (0..2048) |_| try arguments.appendSlice(std.testing.allocator, "\\u00e9");
    try arguments.appendSlice(std.testing.allocator, "\"}");
    try checkToolArguments("zcr_read", arguments.items, null);
    arguments.items.len -= 2;
    try arguments.appendSlice(std.testing.allocator, "a\"}");
    try checkToolArguments("zcr_read", arguments.items, error.InvalidArgument);

    arguments.clearRetainingCapacity();
    try arguments.appendSlice(std.testing.allocator, "{\"items\":[");
    for (0..32) |i| {
        if (i > 0) try arguments.append(std.testing.allocator, ',');
        try arguments.appendSlice(std.testing.allocator, "{\"item_id\":\"x\",\"path\":\"a\"}");
    }
    try arguments.appendSlice(std.testing.allocator, "]}");
    try checkToolArguments("zcr_batch_read", arguments.items, null);
    arguments.items.len -= 2;
    try arguments.appendSlice(std.testing.allocator, ",{\"item_id\":\"last\",\"path\":\"a\"}]}");
    try checkToolArguments("zcr_batch_read", arguments.items, error.InvalidArgument);
}

test "MC-001 raw argument preflight retains malformed envelope classification" {
    const bypass = [_][]const u8{
        "[]",                                                                                                              "null",                                                                                                                       "{}",
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{}}}",    "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{}}}",                        "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{}}}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"unknown\":0,\"params\":{\"name\":\"zcr_read\",\"arguments\":{}}}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"unknown\":0,\"arguments\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_read\",\"arguments\":[]}}",    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":1,\"arguments\":{}}}",                          "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":[]}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{\"name\":\"zcr_read\",\"arguments\":{}}}",
    };
    for (bypass) |raw| try preflightToolArguments(raw);
    try checkToolArguments("zcr_patch", "{\"unknown\":1}", null);
    try checkToolArguments("unknown_tool", "{\"unknown\":1}", null);
    try std.testing.expectEqualStrings("-9223372036854775808", (try rawRequestId("{\"id\":-9223372036854775808}")).?);
    try std.testing.expectEqualStrings("\"\\u0061\"", (try rawRequestId("{\"\\u0069d\":\"\\u0061\"}")).?);
    for ([_][]const u8{ "[]", "{}", "{\"id\":null}", "{\"id\":1.0}", "{\"id\":9223372036854775808}" }) |raw| {
        try std.testing.expectEqual(@as(?[]const u8, null), try rawRequestId(raw));
    }
    const named = "{\"method\":\"tools/call\",\"params\":{\"name\":\"zcr_pa\\u0074ch\"}}";
    try preflight(named);
    try std.testing.expectEqualStrings("zcr_patch", toolName(named).?);
    const other = "{\"method\":\"ping\",\"params\":{\"name\":\"zcr_read\"}}";
    try preflight(other);
    try std.testing.expectEqual(@as(?[]const u8, null), toolName(other));
}
