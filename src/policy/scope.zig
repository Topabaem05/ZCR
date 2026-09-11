//! Task scope checks (T02). S02 RED stub.

const std = @import("std");
const core = @import("zcr_core");

pub const Access = enum { read, write, none };

pub fn covers(prefix: []const u8, path: []const u8) bool {
    _ = .{ prefix, path };
    return false;
}
