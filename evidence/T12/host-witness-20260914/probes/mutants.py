#!/usr/bin/env python3
"""HostWitness mutants for slice A. Each applies one change to a copy of src/storage/recovery.zig.

usage: mutants.py <name> <copy>/src/storage/recovery.zig
  no_temp_name_check   drop the check that the current temp name resolves to the retained temp
  no_one_use           drop the one-use guard on the continuity check
  leaf_original_only   accept only the retained original at the target name (not the renamed temp)
"""
import sys
name, p = sys.argv[1], sys.argv[2]
s = open(p).read()
reps = {
    "no_temp_name_check": ("            if (temp_now) |entry| if (!sameEntry(entry, self.temp_id)) return error.RecoveryRequired;\n", "            _ = temp_now;\n"),
    "no_one_use": ("        if (self.used) return error.RecoveryRequired;\n        const state = journal.metadata(self.state.handle, true)", "        const state = journal.metadata(self.state.handle, true)"),
    "leaf_original_only": ("                if (!original and !sameEntry(entry, self.temp_id)) return error.RecoveryRequired;\n", "                if (!original) return error.RecoveryRequired;\n"),
}
a, b = reps[name]
assert s.count(a) == 1, name
open(p, "w").write(s.replace(a, b))
print("applied", name)
