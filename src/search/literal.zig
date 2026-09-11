//! Literal search (T06, I05). S02 RED stub: public API only.

const std = @import("std");
const core = @import("zcr_core");
const traverse = @import("zcr_fs_traverse");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const scalar = @import("scalar.zig");
pub const context = @import("context.zig");

pub const Caps = struct {
    chunk_bytes: usize = core.limits.values.chunk_bytes,
    output_bytes: u64 = core.limits.values.default_output_bytes,
    max_context_lines: u32 = 4096,
    traverse: traverse.Caps = .{},

    pub fn defaultBytes(caps: Caps) u64 {
        _ = caps;
        return 0;
    }
};

pub const SearchFault = struct {
    after_scan: ?*const fn (context: ?*anyopaque, path: []const u8) void = null,
    context: ?*anyopaque = null,
};

pub const Report = struct {
    complete: bool = false,
    truncated: bool = false,
    files_considered: u64 = 0,
    files_matched: u64 = 0,
    matches: u64 = 0,
    retries: u64 = 0,
    oversize_skipped: u64 = 0,
    binary_skipped: u64 = 0,
    invalid_utf8_skipped: u64 = 0,
    changed_skipped: u64 = 0,
    first_match_ns: ?u64 = null,
    first_push_ns: ?u64 = null,
    finished_ns: u64 = 0,
};

pub const Searcher = struct {
    output_bytes: u64 = 0,
    fault: ?*SearchFault = null,

    pub fn init(allocator: Allocator, root: core.TrustedRoot, workspace_id: core.WorkspaceId, generation: u64, caps: Caps) !Searcher {
        _ = .{ allocator, root, workspace_id, generation, caps };
        return .{};
    }

    pub fn deinit(self: *Searcher) void {
        _ = self;
    }

    pub fn search(
        self: *Searcher,
        io: Io,
        capability: core.Capability,
        spec: core.SearchSpec,
        sink: core.Sink(core.SearchFileResult),
        cancel: core.Cancel,
    ) core.ReadError!core.Coverage {
        _ = .{ self, io, capability, spec, sink, cancel };
        return error.Unsupported;
    }

    pub fn report(self: *const Searcher) Report {
        _ = self;
        return .{};
    }

    comptime {
        core.conforms(core.SearchLiteralFn(Searcher), Searcher.search);
    }
};
