const std = @import("std");
const core = @import("zcr_core");
pub const max_frame_bytes = 16 * 1024;
pub const header_bytes = 16;
pub const checksum_bytes = 32;
pub const Origin = enum { live, recovered };
pub const Frame = struct {
    store_id: core.Uuid,
    namespace_digest: core.Sha256,
    sequence: u32,
    previous: core.Sha256,
    state: core.JournalState,
    prepared: core.PreparedRecord,
    receipt: ?core.Receipt = null,
    origin: Origin = .live,
    created_unix_ms: i64,
    reason: enum { ordinary, recovered_not_applied } = .ordinary,
};
pub const Error = error{ InvalidArgument, RecoveryRequired, OutOfMemory, ResourceExhausted };
pub fn hash(bytes: []const u8) core.Sha256 {
    var result: core.Sha256 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
pub fn encode(comptime T: type, value: T, buffer: *[max_frame_bytes]u8) Error![]const u8 {
    var writer = std.Io.Writer.fixed(buffer[header_bytes .. max_frame_bytes - checksum_bytes]);
    std.json.Stringify.value(value, .{}, &writer) catch return error.ResourceExhausted;
    const len = header_bytes + writer.end + checksum_bytes;
    @memcpy(buffer[0..8], "ZCRJNL1\n");
    std.mem.writeInt(u32, buffer[8..12], @intCast(len), .little);
    std.mem.writeInt(u16, buffer[12..14], 1, .little);
    std.mem.writeInt(u16, buffer[14..16], 0, .little);
    @memcpy(buffer[len - checksum_bytes .. len], &hash(buffer[0 .. len - checksum_bytes]));
    return buffer[0..len];
}
pub fn length(header: []const u8) Error!usize {
    if (header.len < header_bytes) return error.RecoveryRequired;
    if (!std.mem.eql(u8, header[0..8], "ZCRJNL1\n") or std.mem.readInt(u16, header[12..14], .little) != 1 or std.mem.readInt(u16, header[14..16], .little) != 0) return error.RecoveryRequired;
    const len = std.mem.readInt(u32, header[8..12], .little);
    if (len <= header_bytes + checksum_bytes or len > max_frame_bytes) return error.RecoveryRequired;
    return len;
}
/// Only typed bounded objects are decoded; unknown/duplicate fields and integer
/// overflow are rejected. The caller reserves parser memory before this call.
pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) Error!std.json.Parsed(T) {
    const len = try length(bytes);
    if (bytes.len != len or !std.mem.eql(u8, bytes[len - checksum_bytes ..], &hash(bytes[0 .. len - checksum_bytes]))) return error.RecoveryRequired;
    return std.json.parseFromSlice(T, allocator, bytes[header_bytes .. len - checksum_bytes], .{ .allocate = .alloc_always, .max_value_len = max_frame_bytes, .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.RecoveryRequired;
}
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    for (key) |c| if (c < 0x21 or c > 0x7e) return false;
    return true;
}
pub fn keyName(key: core.JournalKey) Error![64]u8 {
    if (!validKey(key.idempotency_key)) return error.InvalidArgument;
    var buf: [8 + 16 + 16 + 2 + 128]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], key.security_domain.id, .little);
    @memcpy(buf[8..24], &key.workspace_incarnation);
    @memcpy(buf[24..40], &key.task_id.uuid);
    std.mem.writeInt(u16, buf[40..42], @intCast(key.idempotency_key.len), .little);
    @memcpy(buf[42..][0..key.idempotency_key.len], key.idempotency_key);
    return std.fmt.bytesToHex(hash(buf[0 .. 42 + key.idempotency_key.len]), .lower);
}
pub fn sameKey(a: core.JournalKey, b: core.JournalKey) bool {
    return a.security_domain.id == b.security_domain.id and std.meta.eql(a.workspace_incarnation, b.workspace_incarnation) and std.meta.eql(a.task_id, b.task_id) and std.mem.eql(u8, a.idempotency_key, b.idempotency_key);
}
pub fn validTemp(name: []const u8) bool {
    if (name.len != 41 or !std.mem.startsWith(u8, name, ".zcr-tmp-")) return false;
    for (name[9..]) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}
