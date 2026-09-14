#!/usr/bin/env python3
"""Mutant: the deadline watcher marks a request expired and reports it, but never sets its
cancellation flag. The request then reaches filesystem work; the event-based deadline test
must fail on this mutant. Applied to an rsync copy only.

usage: mutant_watcher_never_cancels.py <copy>/src/protocol/mcp.zig
"""
import sys
p = sys.argv[1]
s = open(p).read()
a = "                slot.expired.store(true, .release);\n                slot.cancel.store(true, .release);\n                cancelled += 1;\n"
assert s.count(a) == 1
s = s.replace(a, "                slot.expired.store(true, .release);\n                cancelled += 1;\n")
open(p, "w").write(s)
print("mutant applied: watcher never cancels")
