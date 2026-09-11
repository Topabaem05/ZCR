//! Git ignore rules (T05). S02 RED stub.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RuleStack = struct {
    pub fn init(allocator: Allocator, max_rules: u32, pool_bytes: usize) !RuleStack {
        _ = .{ allocator, max_rules, pool_bytes };
        return .{};
    }

    pub fn pushFile(self: *RuleStack, base: []const u8, contents: []const u8) !void {
        _ = .{ self, base, contents };
        return error.NotImplemented;
    }

    pub fn isIgnored(self: *const RuleStack, path: []const u8, is_dir: bool) bool {
        _ = .{ self, path, is_dir };
        return false;
    }
};
