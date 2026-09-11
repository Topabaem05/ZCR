//! Bounded range reads (T04, I03). S02 RED stub: public API only.

const std = @import("std");
const core = @import("zcr_core");
const Io = std.Io;

pub const metadata = @import("metadata.zig");

pub const ReadFault = struct {
    max_read_bytes: ?usize = null,
    interrupt_every: ?u32 = null,
    after_open: ?*const fn (context: ?*anyopaque, attempt: u32) void = null,
    after_chunk: ?*const fn (context: ?*anyopaque, chunk: u32) void = null,
    context: ?*anyopaque = null,
    reads: u32 = 0,
    interrupts: u32 = 0,
    attempts: u32 = 0,
};

pub const Reader = struct {
    root: core.TrustedRoot,
    workspace_id: core.WorkspaceId,
    generation: u64,
    fault: ?*ReadFault = null,

    pub fn init(root: core.TrustedRoot, workspace_id: core.WorkspaceId, generation: u64) Reader {
        return .{ .root = root, .workspace_id = workspace_id, .generation = generation };
    }

    pub fn readRange(
        self: *Reader,
        io: Io,
        allocator: std.mem.Allocator,
        capability: core.Capability,
        spec: core.ReadSpec,
        reservation: *core.Reservation,
        cancel: core.Cancel,
    ) core.ReadError!core.Owned(core.ReadResult) {
        _ = .{ self, io, allocator, capability, spec, reservation, cancel };
        return error.Unsupported;
    }

    comptime {
        core.conforms(core.ReadRangeFn(Reader), Reader.readRange);
    }
};
