//! Probe: run the same git commands as src/workspace/identity.zig through
//! std.process.run with the same environment, limits and 5 s timeout, and print
//! the real error name that identity.zig maps to IoFailure. Build natively and
//! for x86_64-macos (Rosetta) and compare.
//!
//! usage: git_spawn_probe <absolute repo root> <iterations>
const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const root = args.next() orelse return 2;
    const iterations = std.fmt.parseInt(u32, args.next() orelse "10", 10) catch return 2;

    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_OPTIONAL_LOCKS", "0");
    try env.put("LC_ALL", "C");

    const commands = [_][]const []const u8{
        &.{ "rev-parse", "--path-format=absolute", "--show-toplevel" },
        &.{ "rev-parse", "--absolute-git-dir" },
        &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" },
        &.{ "worktree", "list", "--porcelain", "-z" },
    };
    var failures: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        for (commands) |command| {
            var argv: [12][]const u8 = undefined;
            argv[0] = "/usr/bin/git";
            argv[1] = "-C";
            argv[2] = root;
            @memcpy(argv[3..][0..command.len], command);
            const started = std.Io.Clock.Timestamp.now(io, .awake);
            const result = std.process.run(a, io, .{
                .argv = argv[0 .. command.len + 3],
                .environ_map = &env,
                .stdout_limit = .limited(1024 * 1024),
                .stderr_limit = .limited(4096),
                .timeout = .{ .duration = .{ .raw = .fromMilliseconds(5000), .clock = .awake } },
            });
            const elapsed_ms = started.untilNow(io).raw.toMilliseconds();
            if (result) |r| {
                defer a.free(r.stdout);
                defer a.free(r.stderr);
                const code: i64 = switch (r.term) {
                    .exited => |c| c,
                    else => -1,
                };
                if (code != 0) failures += 1;
                std.debug.print("iter={d} cmd={s} ok exit={d} ms={d}\n", .{ i, command[0], code, elapsed_ms });
            } else |err| {
                failures += 1;
                std.debug.print("iter={d} cmd={s} error={t} ms={d}\n", .{ i, command[0], err, elapsed_ms });
            }
        }
    }
    std.debug.print("failures={d}\n", .{failures});
    return if (failures == 0) 0 else 1;
}
