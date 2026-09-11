//! zcr CLI bootstrap (integrator-owned).
//!
//! Only `--version` and `help` work in this build. Contract roles that are not
//! implemented yet (`mcp`, `broker`) exit with EX_UNAVAILABLE (69) and serve
//! nothing, so a host never mistakes a stub for a working server.

const std = @import("std");
const core = @import("zcr_core");
const build_options = @import("build_options");

const Io = std.Io;

const exit_usage = 64;
const exit_unavailable = 69;

const usage =
    \\usage: zcr <command>
    \\
    \\commands:
    \\  --version   print build, protocol schema and Zig versions
    \\  help        print this message
    \\  mcp         direct stdio MCP server (not implemented yet: T08)
    \\  broker      explicit shared broker (not implemented yet: T15)
    \\
;

const PendingRole = struct { name: []const u8, owner_task: []const u8 };
const pending_roles = [_]PendingRole{
    .{ .name = "mcp", .owner_task = "T08" },
    .{ .name = "broker", .owner_task = "T15" },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const command = args.next() orelse {
        try Io.File.stderr().writeStreamingAll(io, usage);
        return exit_usage;
    };

    if (std.mem.eql(u8, command, "--version")) {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "zcr {s} schema={s} zig={s}\n", .{
            build_options.version,
            core.schema_version,
            build_options.zig_version,
        });
        try Io.File.stdout().writeStreamingAll(io, line);
        return 0;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try Io.File.stdout().writeStreamingAll(io, usage);
        return 0;
    }
    for (pending_roles) |role| {
        if (std.mem.eql(u8, command, role.name)) {
            const message = try std.fmt.allocPrint(init.arena.allocator(), "zcr: '{s}' is not implemented in this build ({s}); no tools are served\n", .{ role.name, role.owner_task });
            try Io.File.stderr().writeStreamingAll(io, message);
            return exit_unavailable;
        }
    }

    try Io.File.stderr().writeStreamingAll(io, usage);
    return exit_usage;
}
