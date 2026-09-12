//! Immutable LF checkpoints; offsets preserve CRLF, BOM and final-newline bytes.
const std = @import("std");
const core = @import("zcr_core");
pub const stride: u32 = 128;
pub const newline_policy_version: u32 = 1;
pub const Checkpoint = struct { line: u32, offset: u64 };
pub const Range = struct { first: u32, count: u32, span: core.ByteSpan };
pub fn count(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    const total = std.mem.count(u8, bytes, "\n") + @intFromBool(bytes[bytes.len - 1] != '\n');
    return (total + stride - 1) / stride;
}
/// Caller allocates exactly count(bytes) checkpoints; source is immutable.
pub fn build(bytes: []const u8, out: []Checkpoint) void {
    std.debug.assert(out.len == count(bytes));
    if (out.len == 0) return;
    out[0] = .{ .line = 1, .offset = 0 };
    var line: u32 = 1;
    var next: usize = 1;
    for (bytes, 0..) |byte, i| {
        if (byte != '\n' or i + 1 == bytes.len) continue;
        line += 1;
        if ((line - 1) % stride == 0) {
            out[next] = .{ .line = line, .offset = i + 1 };
            next += 1;
        }
    }
    std.debug.assert(next == out.len);
}
/// Borrowed byte span; the caller keeps its cache pin alive through use.
pub fn select(bytes: []const u8, checkpoints: []const Checkpoint, requested: core.LineRange) error{InvalidArgument}!Range {
    _ = try core.LineRange.init(requested.first, requested.count);
    if (bytes.len == 0) return .{ .first = requested.first, .count = 0, .span = .{ .start = 0, .end = 0 } };
    if (checkpoints.len == 0) return error.InvalidArgument;
    const chosen = @min((requested.first - 1) / stride, checkpoints.len - 1);
    const checkpoint = checkpoints[chosen];
    if (checkpoint.offset >= bytes.len or checkpoint.line > requested.first) return error.InvalidArgument;
    var offset: usize = @intCast(checkpoint.offset);
    var line = checkpoint.line;
    while (line < requested.first and offset < bytes.len) : (line += 1) {
        offset = if (std.mem.indexOfScalarPos(u8, bytes, offset, '\n')) |end| end + 1 else bytes.len;
    }
    const start = offset;
    var selected: u32 = 0;
    while (offset < bytes.len and selected < requested.count) : (selected += 1) {
        offset = if (std.mem.indexOfScalarPos(u8, bytes, offset, '\n')) |end| end + 1 else bytes.len;
    }
    return .{ .first = requested.first, .count = selected, .span = .{ .start = start, .end = offset } };
}
