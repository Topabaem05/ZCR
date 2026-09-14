#!/usr/bin/env python3
"""BR-005 reconnect mutants for slice B. Each applies one change to a copy of the tree.

usage: mutants.py <name> <copy root>
  keep_binding_on_close   closeSession no longer unbinds the grant's registry session, so a
                          disconnected grant could resume without a host rebind
  ignore_fence            registry task binding matches regardless of fence, so a stale fence
                          is accepted after the host rebinds at a new fence
"""
import sys

name, root = sys.argv[1], sys.argv[2]
reps = {
    "keep_binding_on_close": ("src/broker/server.zig",
                              "            s.config.registry.unbindSession(s.config.grants[i].config.session.session_id, s.config.registry.bootNonce()) catch {};\n",
                              "            _ = i;\n"),
    "ignore_fence": ("src/workspace/registry.zig",
                     "self.task.fence == task.fence and",
                     "true and"),
}
path, a, b = reps[name]
p = f"{root}/{path}"
s = open(p).read()
assert s.count(a) == 1, (name, s.count(a))
open(p, "w").write(s.replace(a, b))
print("applied", name)
