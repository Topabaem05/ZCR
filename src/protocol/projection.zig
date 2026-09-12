//! Common compact output projection (T07; docs/08 §3–§5, contracts/response.schema.json,
//! contracts/data.schema.json).
//!
//! `success` writes one compact logical response: the zcr/1 envelope with the
//! `read`, `batch_read`, `files` or `search` data payload. `output_bytes` bounds
//! the serialized data payload, which is also `meta.returned_bytes` (docs/08 §3).
//! When the payload does not fit, whole entries are dropped from the end: lines
//! of a read, paths, or search files; batch items that do not fit are replaced by
//! an `E_OUTPUT_BUDGET` item error, so every item id stays in input order. The
//! envelope then says `truncated=true`, `complete=false` and adds a reason. A
//! payload that cannot hold even its first entry is `OutputBudgetExceeded`; the
//! caller answers with `failure` instead of an empty success.
//!
//! Plans are made by measuring with the same writer that later writes, so the
//! byte counts are exact. Nothing is allocated; the caller owns the buffer.
//! Workspace ids are written as `<registry hex>:<incarnation hex>`, file ids as
//! `<device>:<inode>`.

const std = @import("std");
const core = @import("zcr_core");

pub const max_request_id_bytes = 256;
pub const reason_output_budget = "serialized data reached output_bytes";
pub const message_item_output_budget = "item does not fit the remaining batch output_bytes";

pub const Envelope = struct {
    request_id: []const u8,
    workspace_id: ?core.WorkspaceId = null,
    generation: ?u64 = null,
    elapsed_us: ?u64 = null,
    cache: ?core.CacheResult = null,
};

pub const FilesData = struct { paths: []const core.RelativePath, order: core.Order };
pub const SearchData = struct { files: []const core.SearchFileResult, order: core.Order };

pub const Data = union(enum) {
    read: core.ReadResult,
    batch_read: core.BatchResult,
    files: FilesData,
    search: SearchData,
};

pub const Response = struct {
    bytes: []const u8,
    returned_bytes: u64,
    ok: bool,
    complete: bool,
    truncated: bool,
    /// Lines, items, paths or files left out or replaced to fit `output_bytes`.
    omitted: u32,
};

pub const Error = error{ InvalidArgument, OutputBudgetExceeded };

/// Envelope bytes other than escaped strings and the data payload.
const envelope_fixed_bytes = 640;

/// Buffer capacity that always holds `success` for this envelope, status and budget.
pub fn bufferBytes(envelope: Envelope, status: core.ResultStatus, output_bytes: u64) u64 {
    var strings: u64 = envelope.request_id.len + status.coverage.scope.len + reason_output_budget.len;
    for (status.coverage.reasons) |reason| strings += reason.len + 3;
    return envelope_fixed_bytes + 6 * strings + output_bytes;
}

/// Buffer capacity that always holds `failure` for this envelope and error.
pub fn failureBufferBytes(envelope: Envelope, info: core.errors.ErrorInfo) u64 {
    return envelope_fixed_bytes + 6 * (envelope.request_id.len + info.message.len);
}

pub fn success(buffer: []u8, envelope: Envelope, data: Data, status: core.ResultStatus, output_bytes: u64) Error!Response {
    try checkEnvelope(envelope);
    if (output_bytes == 0 or output_bytes > core.limits.values.max_output_bytes) return error.InvalidArgument;
    if (!validUtf8(status.coverage.scope)) return error.InvalidArgument;
    for (status.coverage.reasons) |reason| if (!validUtf8(reason)) return error.InvalidArgument;

    const plan = try planData(data, output_bytes);
    const truncated = status.truncated or plan.omitted > 0;
    const complete = status.complete and !truncated;
    var emitted_status = status;
    if (data == .batch_read) {
        // Existing item errors are already counted by the batcher. Only successful
        // items replaced during projection introduce additional skipped items.
        emitted_status.coverage.skipped = std.math.add(u64, status.coverage.skipped, plan.omitted) catch return error.InvalidArgument;
    }

    var out: Out = .{ .buf = buffer };
    writeSuccess(&out, envelope, data, emitted_status, plan, complete, truncated) catch |err| return switch (err) {
        error.NoSpace => error.InvalidArgument,
        error.InvalidText => error.InvalidArgument,
    };
    return .{
        .bytes = buffer[0..out.len],
        .returned_bytes = plan.bytes,
        .ok = true,
        .complete = complete,
        .truncated = truncated,
        .omitted = plan.omitted,
    };
}

pub fn failure(buffer: []u8, envelope: Envelope, info: core.errors.ErrorInfo) error{InvalidArgument}!Response {
    try checkEnvelope(envelope);
    if (info.message.len > core.errors.max_message_bytes) return error.InvalidArgument;
    var out: Out = .{ .buf = buffer };
    writeFailure(&out, envelope, info) catch return error.InvalidArgument;
    return .{ .bytes = buffer[0..out.len], .returned_bytes = 2, .ok = false, .complete = false, .truncated = false, .omitted = 0 };
}

fn checkEnvelope(envelope: Envelope) error{InvalidArgument}!void {
    if (envelope.request_id.len == 0 or envelope.request_id.len > max_request_id_bytes) return error.InvalidArgument;
    if (!validUtf8(envelope.request_id)) return error.InvalidArgument;
}

fn validUtf8(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes);
}

// ------------------------------------------------------------------ writer

const WriteError = error{ NoSpace, InvalidText };

/// Compact JSON writer over a fixed buffer; with `buf == null` it only counts bytes.
const Out = struct {
    buf: ?[]u8,
    len: usize = 0,

    fn raw(o: *Out, bytes: []const u8) WriteError!void {
        if (o.buf) |b| {
            if (b.len - o.len < bytes.len) return error.NoSpace;
            @memcpy(b[o.len..][0..bytes.len], bytes);
        }
        o.len += bytes.len;
    }

    fn int(o: *Out, value: anytype) WriteError!void {
        var tmp: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
        try o.raw(text);
    }

    fn boolean(o: *Out, value: bool) WriteError!void {
        try o.raw(if (value) "true" else "false");
    }

    /// A JSON string. Bytes must be UTF-8; control characters are escaped.
    fn string(o: *Out, bytes: []const u8) WriteError!void {
        if (!validUtf8(bytes)) return error.InvalidText;
        try o.raw("\"");
        var run_start: usize = 0;
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
            try o.raw(bytes[run_start..i]);
            if (escape) |e| {
                try o.raw(e);
            } else {
                var tmp: [6]u8 = undefined;
                try o.raw(std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable);
            }
            run_start = i + 1;
        }
        try o.raw(bytes[run_start..]);
        try o.raw("\"");
    }
};

fn measure(comptime f: anytype, args: anytype) usize {
    var out: Out = .{ .buf = null };
    @call(.auto, f, .{&out} ++ args) catch unreachable;
    return out.len;
}

// ------------------------------------------------------------------ data payloads

fn writeLine(o: *Out, line: core.Line) WriteError!void {
    try o.raw("{\"number\":");
    try o.int(line.number);
    try o.raw(",\"start\":");
    try o.int(line.span.start);
    try o.raw(",\"end\":");
    try o.int(line.span.end);
    try o.raw(",\"text\":");
    try o.string(line.text);
    try o.raw("}");
}

fn writeVersion(o: *Out, version: core.FileVersion) WriteError!void {
    try o.raw("{\"size\":");
    try o.int(version.size);
    try o.raw(",\"file_id\":\"");
    try o.int(version.file_id.device);
    try o.raw(":");
    try o.int(version.file_id.inode);
    try o.raw("\",\"sha256\":");
    if (version.sha256) |digest| {
        try o.raw("\"");
        try o.raw(&std.fmt.bytesToHex(digest, .lower));
        try o.raw("\"");
    } else {
        try o.raw("null");
    }
    try o.raw("}");
}

fn writeLines(o: *Out, lines: []const core.Line) WriteError!void {
    try o.raw("[");
    for (lines, 0..) |line, i| {
        if (i > 0) try o.raw(",");
        try writeLine(o, line);
    }
    try o.raw("]");
}

fn writeRead(o: *Out, result: core.ReadResult, line_count: usize) WriteError!void {
    try o.raw("{\"path\":");
    try o.string(result.path.bytes);
    try o.raw(",\"lines\":");
    try writeLines(o, result.lines[0..line_count]);
    try o.raw(",\"version\":");
    try writeVersion(o, result.version);
    try o.raw("}");
}

fn writeErrorInfo(o: *Out, info: core.errors.ErrorInfo) WriteError!void {
    try o.raw("{\"code\":\"");
    try o.raw(@tagName(info.code));
    try o.raw("\",\"message\":");
    try o.string(info.message);
    try o.raw(",\"retryable\":");
    try o.boolean(info.retryable);
    try o.raw("}");
}

const budget_error: core.errors.ErrorInfo = .{ .code = .E_OUTPUT_BUDGET, .message = message_item_output_budget, .retryable = false };

/// One batch item; `fits == false` writes the output-budget error in its place.
fn writeItem(o: *Out, item: core.BatchItem, fits: bool) WriteError!void {
    try o.raw("{\"item_id\":");
    try o.string(item.item_id);
    switch (item.result) {
        .ok => |result| if (fits) {
            try o.raw(",\"ok\":true,\"data\":");
            try writeRead(o, result, result.lines.len);
            try o.raw(",\"error\":null}");
            return;
        },
        .err => |info| {
            try o.raw(",\"ok\":false,\"data\":null,\"error\":");
            try writeErrorInfo(o, info);
            try o.raw("}");
            return;
        },
    }
    try o.raw(",\"ok\":false,\"data\":null,\"error\":");
    try writeErrorInfo(o, budget_error);
    try o.raw("}");
}

fn writeSearchFile(o: *Out, file: core.SearchFileResult) WriteError!void {
    try o.raw("{\"path\":");
    try o.string(file.path.bytes);
    try o.raw(",\"matches\":[");
    for (file.matches, 0..) |match, i| {
        if (i > 0) try o.raw(",");
        try o.raw("{\"start\":");
        try o.int(match.span.start);
        try o.raw(",\"end\":");
        try o.int(match.span.end);
        try o.raw(",\"line\":");
        try o.int(match.line);
        try o.raw("}");
    }
    try o.raw("],\"context\":");
    try writeLines(o, file.context);
    try o.raw(",\"version\":");
    try writeVersion(o, file.version);
    try o.raw("}");
}

fn writeOrder(o: *Out, order: core.Order) WriteError!void {
    try o.raw(",\"order\":\"");
    try o.raw(@tagName(order));
    try o.raw("\"}");
}

// ------------------------------------------------------------------ planning

const max_items = core.limits.values.max_batch_items;

const Plan = struct {
    /// Serialized payload bytes.
    bytes: u64,
    /// Entries written (lines, paths or files); unused for batches.
    count: usize = 0,
    omitted: u32 = 0,
    /// Batch items that are written in full.
    fits: [max_items]bool = @splat(true),
};

/// Largest prefix of entries whose serialized size, with separators and the
/// fixed parts, stays within `budget`.
fn prefixPlan(fixed: usize, sizes: anytype, n: usize, budget: u64) Error!Plan {
    var total: u64 = fixed;
    var count: usize = 0;
    while (count < n) : (count += 1) {
        const next = total + sizes.at(count) + @intFromBool(count > 0);
        if (next > budget) break;
        total = next;
    }
    if (total > budget or (count == 0 and n > 0)) return error.OutputBudgetExceeded;
    return .{ .bytes = total, .count = count, .omitted = @intCast(n - count) };
}

fn planData(data: Data, budget: u64) Error!Plan {
    switch (data) {
        .read => |result| {
            for (result.lines) |line| if (!validUtf8(line.text)) return error.InvalidArgument;
            if (!validUtf8(result.path.bytes)) return error.InvalidArgument;
            const fixed = measure(writeRead, .{ result, @as(usize, 0) });
            const Sizes = struct {
                lines: []const core.Line,
                fn at(s: @This(), i: usize) usize {
                    return measure(writeLine, .{s.lines[i]});
                }
            };
            return prefixPlan(fixed, Sizes{ .lines = result.lines }, result.lines.len, budget);
        },
        .files => |files| {
            for (files.paths) |path| if (!validUtf8(path.bytes)) return error.InvalidArgument;
            const Sizes = struct {
                paths: []const core.RelativePath,
                fn at(s: @This(), i: usize) usize {
                    return measure(Out.string, .{s.paths[i].bytes});
                }
            };
            const fixed = "{\"paths\":[]".len + measure(writeOrder, .{files.order});
            return prefixPlan(fixed, Sizes{ .paths = files.paths }, files.paths.len, budget);
        },
        .search => |search| {
            for (search.files) |file| {
                if (!validUtf8(file.path.bytes)) return error.InvalidArgument;
                for (file.context) |line| if (!validUtf8(line.text)) return error.InvalidArgument;
            }
            const Sizes = struct {
                files: []const core.SearchFileResult,
                fn at(s: @This(), i: usize) usize {
                    return measure(writeSearchFile, .{s.files[i]});
                }
            };
            const fixed = "{\"files\":[]".len + measure(writeOrder, .{search.order});
            return prefixPlan(fixed, Sizes{ .files = search.files }, search.files.len, budget);
        },
        .batch_read => |value| {
            const items = value.items;
            if (items.len > max_items) return error.InvalidArgument;
            for (items) |item| {
                if (!validUtf8(item.item_id)) return error.InvalidArgument;
                switch (item.result) {
                    .ok => |result| {
                        if (!validUtf8(result.path.bytes)) return error.InvalidArgument;
                        for (result.lines) |line| if (!validUtf8(line.text)) return error.InvalidArgument;
                    },
                    .err => |info| if (!validUtf8(info.message)) return error.InvalidArgument,
                }
            }
            // Every item takes at least the smaller of its full and error forms; items whose
            // full form is larger then take what is left, in input order.
            var plan: Plan = .{ .bytes = "{\"items\":[]}".len + (items.len -| 1) };
            var extra: [max_items]usize = undefined;
            for (items, 0..) |item, i| {
                const small = measure(writeItem, .{ item, false });
                const full = measure(writeItem, .{ item, true });
                if (full <= small) {
                    plan.bytes += full;
                    extra[i] = 0;
                } else {
                    plan.bytes += small;
                    extra[i] = full - small;
                }
            }
            if (plan.bytes > budget) return error.OutputBudgetExceeded;
            for (extra[0..items.len], 0..) |more, i| {
                if (more == 0) continue;
                if (plan.bytes + more <= budget) {
                    plan.bytes += more;
                } else {
                    plan.fits[i] = false;
                    plan.omitted += 1;
                }
            }
            return plan;
        },
    }
}

// ------------------------------------------------------------------ envelope

fn writeHead(o: *Out, envelope: Envelope, ok: bool, complete: bool, truncated: bool, consistency: core.Consistency) WriteError!void {
    try o.raw("{\"schema_version\":\"" ++ core.schema_version ++ "\",\"request_id\":");
    try o.string(envelope.request_id);
    try o.raw(",\"workspace_id\":");
    if (envelope.workspace_id) |id| {
        try o.raw("\"");
        try o.raw(&std.fmt.bytesToHex(id.registry_uuid, .lower));
        try o.raw(":");
        try o.raw(&std.fmt.bytesToHex(id.incarnation, .lower));
        try o.raw("\"");
    } else {
        try o.raw("null");
    }
    try o.raw(",\"generation\":");
    if (envelope.generation) |g| try o.int(g) else try o.raw("null");
    try o.raw(",\"ok\":");
    try o.boolean(ok);
    try o.raw(",\"complete\":");
    try o.boolean(complete);
    try o.raw(",\"truncated\":");
    try o.boolean(truncated);
    try o.raw(",\"consistency\":\"");
    try o.raw(@tagName(consistency));
    try o.raw("\"");
}

fn writeMeta(o: *Out, envelope: Envelope, returned_bytes: u64) WriteError!void {
    try o.raw(",\"meta\":{");
    if (envelope.elapsed_us) |us| {
        try o.raw("\"elapsed_us\":");
        try o.int(us);
        try o.raw(",");
    }
    try o.raw("\"returned_bytes\":");
    try o.int(returned_bytes);
    if (envelope.cache) |cache| {
        try o.raw(",\"cache\":\"");
        try o.raw(@tagName(cache));
        try o.raw("\"");
    }
    try o.raw("}}");
}

fn writeSuccess(o: *Out, envelope: Envelope, data: Data, status: core.ResultStatus, plan: Plan, complete: bool, truncated: bool) WriteError!void {
    try writeHead(o, envelope, true, complete, truncated, status.consistency);
    const coverage = status.coverage;
    try o.raw(",\"coverage\":{\"scope\":");
    try o.string(coverage.scope);
    try o.raw(",\"skipped\":");
    try o.int(coverage.skipped);
    try o.raw(",\"index_state\":\"");
    try o.raw(@tagName(coverage.index_state));
    try o.raw("\"");
    if (coverage.reasons.len > 0 or plan.omitted > 0) {
        try o.raw(",\"reasons\":[");
        for (coverage.reasons, 0..) |reason, i| {
            if (i > 0) try o.raw(",");
            try o.string(reason);
        }
        if (plan.omitted > 0) {
            if (coverage.reasons.len > 0) try o.raw(",");
            try o.string(reason_output_budget);
        }
        try o.raw("]");
    }
    try o.raw("},\"data\":");

    const data_start = o.len;
    switch (data) {
        .read => |result| try writeRead(o, result, plan.count),
        .files => |files| {
            try o.raw("{\"paths\":[");
            for (files.paths[0..plan.count], 0..) |path, i| {
                if (i > 0) try o.raw(",");
                try o.string(path.bytes);
            }
            try o.raw("]");
            try writeOrder(o, files.order);
        },
        .search => |search| {
            try o.raw("{\"files\":[");
            for (search.files[0..plan.count], 0..) |file, i| {
                if (i > 0) try o.raw(",");
                try writeSearchFile(o, file);
            }
            try o.raw("]");
            try writeOrder(o, search.order);
        },
        .batch_read => |value| {
            try o.raw("{\"items\":[");
            for (value.items, 0..) |item, i| {
                if (i > 0) try o.raw(",");
                try writeItem(o, item, plan.fits[i]);
            }
            try o.raw("]}");
        },
    }
    std.debug.assert(o.len - data_start == plan.bytes);

    try o.raw(",\"error\":null");
    try writeMeta(o, envelope, plan.bytes);
}

fn writeFailure(o: *Out, envelope: Envelope, info: core.errors.ErrorInfo) WriteError!void {
    try writeHead(o, envelope, false, false, false, .not_applicable);
    try o.raw(",\"coverage\":{\"scope\":\"\",\"skipped\":0,\"index_state\":\"not_applicable\"},\"data\":{},\"error\":");
    try writeErrorInfo(o, info);
    try writeMeta(o, envelope, 2);
}
