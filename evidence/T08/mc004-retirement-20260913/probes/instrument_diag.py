#!/usr/bin/env python3
"""Instrument the original MC-004 retirement test (main f1c388a) without changing its assertions.

Applied to an rsync copy of the source tree, never to the task worktree. It records the
validation counter at the moment the test reads it, the final counter, whether any response
was "Duplicate active request id", and how many responses reported ok:true.

usage: instrument_diag.py <copy>/tests/t08_test.zig
"""
import sys

p = sys.argv[1]
s = open(p).read()
a = "    const accepted_during_retirement = gate.validated.load(.acquire) == 2;\n"
b = "    const validated_at_read = gate.validated.load(.acquire);\n    const accepted_during_retirement = validated_at_read == 2;\n"
assert s.count(a) == 1
s = s.replace(a, b)
a = "    thread.join();\n    try testing.expect(entered and accepted_during_retirement);\n"
b = """    thread.join();
    {
        var dbuf: [16384]u8 = undefined;
        var dr = drain.readerStreaming(io, &dbuf);
        const all = try dr.interface.allocRemaining(testing.allocator, .unlimited);
        defer testing.allocator.free(all);
        std.debug.print("MC004DIAG entered={} validated_at_read={d} validated_final={d} dup={} ok_count={d}\\n", .{ entered, validated_at_read, gate.validated.load(.acquire), std.mem.indexOf(u8, all, "Duplicate active request id") != null, std.mem.count(u8, all, "\\\\\\"ok\\\\\\":true") });
    }
    try testing.expect(entered and accepted_during_retirement);
"""
assert s.count(a) == 1
s = s.replace(a, b)
open(p, "w").write(s)
