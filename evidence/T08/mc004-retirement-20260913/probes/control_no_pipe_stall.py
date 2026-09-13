#!/usr/bin/env python3
"""Negative control for the MC-004 partial pipe test: make the "large" response fit in the pipe.

With a 1 KiB file the writer never blocks, so the pipe never stops reporting POLLOUT. The
event-based test must fail at `stalled`; the former 30 ms sleep passed without a stall.

usage: control_no_pipe_stall.py <copy>/tests/t08_test.zig
"""
import sys

p = sys.argv[1]
s = open(p).read()
a = "    const text = try h.arena.allocator().alloc(u8, 128 * 1024);\n"
assert s.count(a) == 1
s = s.replace(a, "    const text = try h.arena.allocator().alloc(u8, 1024);\n")
open(p, "w").write(s)
print("control applied: large response is 1 KiB")
