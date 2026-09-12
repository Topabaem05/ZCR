const std = @import("std");
const mcp = @import("zcr_mcp");
test "MC-001 supported version negotiates and unsupported version refuses" {
    try std.testing.expect(mcp.supportedVersion("2025-11-25"));
    try std.testing.expect(!mcp.supportedVersion("2024-11-05"));
}
