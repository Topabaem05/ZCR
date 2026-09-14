//! zcr CLI bootstrap (integrator-owned).
//!
//! Direct stdio requires an explicit approved launch policy and bound manifest.
//! Workspace inspection reports filesystem identity. The broker starts only when
//! the operator runs `zcr broker serve`; bridges never start one.

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
    \\              broker bridge: --broker --socket /absolute/socket --domain N --token-fd FD
    \\  workspace-id --root /absolute/worktree [--git /absolute/git]
    \\  broker      explicit shared broker: serve --socket /absolute/socket --policy /absolute/policy.json --token-fd FD
    \\              runs until its stdin closes
    \\
    \\The broker capability token is read from the inherited descriptor FD (at least 3), never from argv.
    \\
;
const bridge_usage = "zcr: mcp --broker requires --socket /absolute/socket --domain N --token-fd FD (FD >= 3; the token is never accepted on argv)\n";
const serve_usage = "zcr: broker requires serve --socket /absolute/socket --policy /absolute/approved-policy.json --token-fd FD (FD >= 3; the token is never accepted on argv)\n";

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
        const mode = args.next() orelse "";
        if (std.mem.eql(u8, mode, "--broker")) {
            var socket: []const u8 = "";
            var domain: ?u64 = null;
            var token_fd: ?std.c.fd_t = null;
            while (args.next()) |flag| {
                const value = args.next() orelse "";
                if (std.mem.eql(u8, flag, "--socket")) {
                    socket = value;
                } else if (std.mem.eql(u8, flag, "--domain")) {
                    domain = std.fmt.parseInt(u64, value, 10) catch null;
                } else if (std.mem.eql(u8, flag, "--token-fd")) {
                    token_fd = std.fmt.parseInt(std.c.fd_t, value, 10) catch null;
                } else {
                    try Io.File.stderr().writeStreamingAll(io, bridge_usage);
                    return exit_usage;
                }
            }
            if (!std.fs.path.isAbsolute(socket) or domain == null or token_fd == null or token_fd.? < 3) {
                try Io.File.stderr().writeStreamingAll(io, bridge_usage);
                return exit_usage;
            }
            launch.bridge(init.gpa, io, socket, .{ .id = domain.? }, token_fd.?) catch |err| {
                const message = try std.fmt.allocPrint(init.arena.allocator(), "zcr: broker bridge refused: {s}; no broker was started. Run zcr broker serve explicitly, or use zcr mcp --standalone\n", .{@errorName(err)});
                try Io.File.stderr().writeStreamingAll(io, message);
                return exit_unavailable;
            };
            return 0;
        }
        const flag = args.next() orelse "";
        const path = args.next() orelse "";
        if (!std.mem.eql(u8, mode, "--standalone") or !std.mem.eql(u8, flag, "--policy") or !std.fs.path.isAbsolute(path) or args.next() != null) {
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
    if (std.mem.eql(u8, command, "broker")) {
        const sub = args.next() orelse "";
        var socket: []const u8 = "";
        var policy_path: []const u8 = "";
        var token_fd: ?std.c.fd_t = null;
        var valid = std.mem.eql(u8, sub, "serve");
        while (args.next()) |flag| {
            const value = args.next() orelse "";
            if (std.mem.eql(u8, flag, "--socket")) {
                socket = value;
            } else if (std.mem.eql(u8, flag, "--policy")) {
                policy_path = value;
            } else if (std.mem.eql(u8, flag, "--token-fd")) {
                token_fd = std.fmt.parseInt(std.c.fd_t, value, 10) catch null;
            } else {
                valid = false;
            }
        }
        if (!valid or !std.fs.path.isAbsolute(socket) or !std.fs.path.isAbsolute(policy_path) or token_fd == null or token_fd.? < 3) {
            try Io.File.stderr().writeStreamingAll(io, serve_usage);
            return exit_usage;
        }
        launch.serveBroker(init.gpa, io, policy_path, socket, token_fd.?) catch |err| {
            const message = try std.fmt.allocPrint(init.arena.allocator(), "zcr: broker startup refused: {s}\n", .{@errorName(err)});
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

    try Io.File.stderr().writeStreamingAll(io, usage);
    return exit_usage;
}
