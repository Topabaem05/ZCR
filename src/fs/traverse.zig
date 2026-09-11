//! Streaming traversal (T05, I04). S02 RED stub: public API only.

const std = @import("std");
const core = @import("zcr_core");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ignore = @import("ignore.zig");

pub const Caps = struct {
    path_cache_entries: u32 = 4096,
    path_cache_bytes: usize = 256 * 1024,
    max_ignore_file_bytes: usize = core.limits.values.max_ignore_file_bytes,
    max_ignore_rules: u32 = core.limits.values.max_ignore_rules,

    pub fn defaultBytes(caps: Caps) u64 {
        _ = caps;
        return 0;
    }
};

pub const Report = struct {
    complete: bool = false,
    truncated: bool = false,
    order_fallback: bool = false,
    files_seen: u64 = 0,
    directories_visited: u64 = 0,
    unreadable_directories: u64 = 0,
    symlinks_not_followed: u64 = 0,
    unsupported_names: u64 = 0,
    ignore_limits_exceeded: u64 = 0,
};

pub const Traverser = struct {
    root: core.TrustedRoot,

    pub fn init(allocator: Allocator, root: core.TrustedRoot, workspace_id: core.WorkspaceId, caps: Caps) !Traverser {
        _ = .{ allocator, workspace_id, caps };
        return .{ .root = root };
    }

    pub fn deinit(self: *Traverser) void {
        _ = self;
    }

    pub fn enumerate(
        self: *Traverser,
        io: Io,
        capability: core.Capability,
        spec: core.FileSpec,
        sink: core.Sink(core.RelativePath),
        cancel: core.Cancel,
    ) core.ReadError!core.Coverage {
        _ = .{ self, io, capability, spec, sink, cancel };
        return error.Unsupported;
    }

    pub fn report(self: *const Traverser) Report {
        _ = self;
        return .{};
    }

    comptime {
        core.conforms(core.EnumerateFn(Traverser), Traverser.enumerate);
    }
};
