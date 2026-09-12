const std = @import("std");
const launch = @import("zcr_launch");

test "MC-005 launch expiry parses exact UTC and rejects calendar overflows" {
    try std.testing.expectEqual(@as(i64, 0), try launch.parseExpiry("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1709164800000), try launch.parseExpiry("2024-02-29T00:00:00Z"));
    for ([_][]const u8{ "2025-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-01-00T00:00:00Z", "2026-01-01T24:00:00Z", "2026-01-01T00:60:00Z", "2026-01-01T00:00:60Z", "2026-01-01T00:00:00+00:00", "2026-01-01T00:00:00Zx" }) |bad|
        try std.testing.expectError(error.InvalidArgument, launch.parseExpiry(bad));
}

test "MC-005 launch binding fingerprint includes every filesystem identity" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const first = try launch.workspaceFingerprint(&a, .{ .device = 1, .inode = 2 }, .{ .device = 1, .inode = 3 }, .{ .device = 1, .inode = 4 });
    const changed = try launch.workspaceFingerprint(&b, .{ .device = 1, .inode = 2 }, .{ .device = 1, .inode = 5 }, .{ .device = 1, .inode = 4 });
    try std.testing.expect(!std.mem.eql(u8, first, changed));
    try std.testing.expectEqualStrings("fs:1:2:1:3:1:4", first);
}
