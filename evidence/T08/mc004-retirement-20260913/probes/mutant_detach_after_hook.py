#!/usr/bin/env python3
"""Mutant for MC-004: run the retirement hook before the slot's id is detached.

While the hook blocks, the retiring slot stays `.writing` with its id, so a request that
reuses the id is rejected as "Duplicate active request id". A correct MC-004 retirement
test must fail on this mutant. Applied to an rsync copy only.

usage: mutant_detach_after_hook.py <copy>/src/protocol/mcp.zig
"""
import sys

p = sys.argv[1]
s = open(p).read()
hook = "        if (!slot.control) if (t.server.config.before_tool_release) |hook| hook(t.server.config.retirement_context);\n"
block = """        t.mutex.lockUncancelable(io);
        slot.state = .retiring;
        slot.id = .null;
        slot.raw = "";
        slot.response = "";
        t.mutex.unlock(io);
"""
a = block + hook
assert s.count(a) == 1
s = s.replace(a, hook + block)
open(p, "w").write(s)
print("mutant applied: hook now runs before id detach")
