#!/usr/bin/env python3
"""Broker CLI mutants for slice C. Each applies one change to a copy of the tree.

usage: mutants.py <name> <copy root>
  ignore_broker_allowed   the broker role no longer requires broker_allowed in the launch policy
  bridge_zero_token       the bridge sends an all-zero token instead of the one read from the descriptor
  watcher_ignores_grant_end  the broker keeps listening after its only grant's binding ends
"""
import sys

name, root = sys.argv[1], sys.argv[2]
reps = {
    "ignore_broker_allowed": ("src/launch.zig",
                              "cfg.broker_allowed != (role == .broker) or ",
                              ""),
    "bridge_zero_token": ("src/launch.zig",
                          "    var client = try broker.bridge.Client.connect(a, io, socket_path, token, domain);\n",
                          "    _ = token;\n    var client = try broker.bridge.Client.connect(a, io, socket_path, @splat(0), domain);\n"),
    "watcher_ignores_grant_end": ("src/launch.zig",
                                  "            w.registry.validateSession(w.session, w.boot) catch {\n                w.grant_ended.store(true, .release);\n                break;\n            };\n",
                                  ""),
}
path, a, b = reps[name]
p = f"{root}/{path}"
s = open(p).read()
assert s.count(a) == 1, (name, s.count(a))
open(p, "w").write(s.replace(a, b))
print("applied", name)
