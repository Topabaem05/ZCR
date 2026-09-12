//! zcr CLI bootstrap (integrator-owned).
//!
//! Direct stdio requires an explicit approved launch policy and bound manifest.
//! Workspace inspection reports filesystem identity; broker remains gated.

const std = @import("std");
const core = @import("zcr_core");
const build_options = @import("build_options");
const launch = @import("zcr_launch");

const Io = std.Io;

const exit_usage = 64;
const exit_unavailable = 69;

const usage =
    \\usage: zcr <command>
    \\
    \\commands:
    \\  --version   print build, protocol schema and Zig versions
    \\  help        print this message
    \\  mcp         direct stdio MCP server: --standalone --policy /absolute/policy.json
    \\  workspace-id --root /absolute/worktree [--git /absolute/git]
    \\  broker      explicit shared broker (not implemented yet: T15)
    \\
;

const PendingRole = struct { name: []const u8, owner_task: []const u8 };
const pending_roles = [_]PendingRole{
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
    if (std.mem.eql(u8, command, "mcp")) {
        const standalone = args.next() orelse "";
        const flag = args.next() orelse "";
        const path = args.next() orelse "";
        if (!std.mem.eql(u8, standalone, "--standalone") or !std.mem.eql(u8, flag, "--policy") or !std.fs.path.isAbsolute(path) or args.next() != null) {
            try Io.File.stderr().writeStreamingAll(io, "zcr: mcp requires --standalone --policy /absolute/approved-policy.json\n");
            return exit_usage;
        }
        launch.serve(init.gpa, io, path) catch |err| {
            const message = try std.fmt.allocPrint(init.arena.allocator(), "zcr: startup refused: {s}\n", .{@errorName(err)});
            try Io.File.stderr().writeStreamingAll(io, message);
            return exit_unavailable;
        };
        return 0;
    }
    if (std.mem.eql(u8, command, "workspace-id")) {
        const flag = args.next() orelse "";
        const root = args.next() orelse "";
        var git: []const u8 = "/usr/bin/git";
        if (args.next()) |git_flag| {
            if (!std.mem.eql(u8, git_flag, "--git")) return exit_usage;
            git = args.next() orelse return exit_usage;
        }
        if (!std.mem.eql(u8, flag, "--root") or !std.fs.path.isAbsolute(root) or !std.fs.path.isAbsolute(git) or args.next() != null) return exit_usage;
        launch.describe(init.gpa, io, root, git) catch |err| {
            const message = try std.fmt.allocPrint(init.arena.allocator(), "zcr: workspace discovery refused: {s}\n", .{@errorName(err)});
            try Io.File.stderr().writeStreamingAll(io, message);
            return exit_unavailable;
        };
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
