//! Root-handle path checks (T02). S02 RED stub.

const std = @import("std");
const core = @import("zcr_core");
const Io = std.Io;

pub const Kind = enum { directory, regular, symlink, other };

pub const Identity = struct {
    device: u64,
    inode: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.device == b.device and a.inode == b.inode;
    }
};

pub const Entry = struct { identity: Identity, kind: Kind };

pub const SyntaxError = error{ InvalidArgument, PathEscape };

pub fn validate(bytes: []const u8) SyntaxError!void {
    _ = bytes;
    return error.InvalidArgument;
}
