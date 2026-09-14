#!/usr/bin/env python3
"""Mutant: drop the Timeout -> Busy mapping so a git discovery timeout is reported as IoFailure
again (the behaviour before this change). The IS-008 timeout test must fail. Copy only.

usage: mutant_timeout_as_ioerror.py <copy>/src/workspace/identity.zig
"""
import sys
p = sys.argv[1]
s = open(p).read()
a = "        error.Timeout => error.Busy,\n"
assert s.count(a) == 1
s = s.replace(a, "")
open(p, "w").write(s)
print("mutant applied: Timeout maps to IoFailure")
