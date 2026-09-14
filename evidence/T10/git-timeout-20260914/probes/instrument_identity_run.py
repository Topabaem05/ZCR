#!/usr/bin/env python3
"""Instrument workspace identity git runs (investigation copy only, never the task worktree).

Prints one line per git invocation from identity.zig `output`: the git arguments, elapsed
milliseconds, and either the process exit or the std.process.run error name that the product
code maps to IoFailure. Product error mapping is unchanged.

usage: instrument_identity_run.py <copy>/src/workspace/identity.zig
"""
import sys

p = sys.argv[1]
s = open(p).read()
a = """    const r = std.process.run(a, io, .{
        .argv = argv[0 .. args.len + 3],
        .environ_map = &env,
        .stdout_limit = .limited(max_git_output),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(5000), .clock = .awake } },
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.ResourceExhausted,
        else => error.IoFailure,
    };
    switch (r.term) {
        .exited => |code| if (code == 0) return r.stdout,
        else => {},
    }
    return error.IoFailure;"""
b = """    const diag_started = std.Io.Clock.Timestamp.now(io, .awake);
    const r = std.process.run(a, io, .{
        .argv = argv[0 .. args.len + 3],
        .environ_map = &env,
        .stdout_limit = .limited(max_git_output),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(5000), .clock = .awake } },
    }) catch |err| {
        std.debug.print("IDENTDIAG args={s} elapsed_ms={d} run_error={s}\\n", .{ args[0], diag_started.untilNow(io).raw.toMilliseconds(), @errorName(err) });
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => error.ResourceExhausted,
            else => error.IoFailure,
        };
    };
    const diag_ms = diag_started.untilNow(io).raw.toMilliseconds();
    if (diag_ms > 1000) std.debug.print("IDENTDIAG args={s} elapsed_ms={d} slow\\n", .{ args[0], diag_ms });
    switch (r.term) {
        .exited => |code| if (code == 0) return r.stdout,
        else => {},
    }
    std.debug.print("IDENTDIAG args={s} elapsed_ms={d} term={any} stderr={s}\\n", .{ args[0], diag_ms, r.term, r.stderr });
    return error.IoFailure;"""
assert s.count(a) == 1
s = s.replace(a, b)
open(p, "w").write(s)
print("identity git runs instrumented")
