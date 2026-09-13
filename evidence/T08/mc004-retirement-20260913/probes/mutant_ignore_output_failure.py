#!/usr/bin/env python3
"""Mutant for MC-004 stdout failure: the input reader ignores the transport failure flag.

After a failed stdout write the reader keeps polling stdin, so serve only returns once the
peer closes stdin. The event-based stdout-failure test must fail on this mutant.

usage: mutant_ignore_output_failure.py <copy>/src/protocol/mcp.zig
"""
import sys

p = sys.argv[1]
s = open(p).read()
a = "            if (failed) return error.IoFailure;\n            var fds"
assert s.count(a) == 1
s = s.replace(a, "            _ = failed;\n            var fds")
open(p, "w").write(s)
print("mutant applied: readInput ignores failed")
