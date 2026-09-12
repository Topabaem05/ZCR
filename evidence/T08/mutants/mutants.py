#!/usr/bin/env python3
"""T08 mutation checks.

usage: mutants.py <out-dir> [names...]

Each mutant is a one-place source change applied to an rsync copy of the worktree
outside it. A substitution that does not match exactly once is a hard error, so a
mutant can never be reported from an unmutated copy, and every log is checked for
a cached test compile.
"""
import os, shutil, subprocess, sys

WT = "/Users/guribbong/code/ZCR-worktrees/task-t08"
ST = "/Users/guribbong/code/ZCR-state/tasks/T08"
ZIG = os.path.expanduser("~/.local/share/zig/0.16.0/zig")
F, C, S = "src/protocol/framing.zig", "src/protocol/codec.zig", "src/protocol/mcp.zig"

MUTANTS = [
    ("b1-framer-keeps-overlong", F,
     "            const too_big = f.len + chunk.len > f.buffer.len or f.len + chunk.len > max_frame_bytes;",
     "            const too_big = false and (f.len + chunk.len > f.buffer.len or f.len + chunk.len > max_frame_bytes);"),
    ("b2-framer-no-resync", F,
     "                f.skipping = false;\n                f.oversize += 1;",
     "                f.oversize += 1;"),
    ("b3-writer-no-lock", F,
     "        w.mutex.lockUncancelable(io);\n        defer w.mutex.unlock(io);\n", ""),
    ("b4-writer-record-separator", F,
     '        w.file.writeStreamingAll(io, "\\n") catch return error.IoFailure;\n', ""),
    ("c1-no-depth-check", C,
     "    if (depthOf(bytes) > max_depth) {",
     "    if (false and depthOf(bytes) > max_depth) {"),
    ("c2-no-duplicate-member", C,
     '            if (seen.method) return s.fail(error.Invalid, "duplicate member");\n', ""),
    ("c3-no-jsonrpc-check", C,
     '    if (!seen.jsonrpc or !std.mem.eql(u8, version, jsonrpc_version)) return s.fail(error.Invalid, "jsonrpc must be \\"2.0\\"");\n', ""),
    ("c4-no-unknown-argument", C,
     '        } else return s.fail(error.Params, "unknown argument");',
     "        } else 0;"),
    ("c5-no-integer-range", C,
     '                if (n < field.min or n > field.max) return s.fail(error.Params, "argument is out of range");\n', ""),
    ("c6-no-string-length", C,
     '                if (text.len < field.min or text.len > field.max) return s.fail(error.Params, "argument string length is out of range");\n', ""),
    ("m1-no-initialized-gate", S,
     '                if (!self.initialized) return self.fault(.{ .code = codec.rpc_invalid_request, .id = request.id, .message = "initialize first" });\n                const result = try self.toolList(arena);',
     "                const result = try self.toolList(arena);"),
    ("m2-any-protocol-version", S,
     "                if (!std.mem.eql(u8, request.protocol_version, protocol_version)) {",
     "                if (false and !std.mem.eql(u8, request.protocol_version, protocol_version)) {"),
    ("m3-second-initialize-ok", S,
     '                if (self.initialized) return self.fault(.{ .code = codec.rpc_invalid_request, .id = request.id, .message = "the session is already initialized" });\n', ""),
    ("m4-advertise-disabled", S,
     "            if (!self.tools.enabled(tool)) continue;\n            for (all) |entry| {",
     "            for (all) |entry| {"),
    ("m5b-cancel-any-session", S,
     "            if (!std.mem.eql(u8, &slot.session.uuid, &session.uuid)) continue;",
     "            if (false and !std.mem.eql(u8, &slot.session.uuid, &session.uuid)) continue;"),
    ("m6-no-registry-close", S,
     "        defer self.registry.close(io, slot);\n", ""),
    ("m7-arguments-as-rpc-error", S,
     "        if (request.argument_error) |message| return self.toolError(request, .E_INVALID_ARGUMENT, message);",
     "        if (request.argument_error) |message| return self.fault(.{ .code = codec.rpc_invalid_params, .id = request.id, .message = message });"),
    ("m8-cancel-not-counted", S,
     "            if (code == .E_CANCELLED) self.last.cancelled += 1;\n", ""),
    ("m9-tool-enabled-ignored", S,
     "        if (request.tool == .unknown or !self.tools.enabled(request.tool)) {",
     "        if (request.tool == .unknown) {"),
]


def free_mib():
    out = subprocess.run(["df", "-m", "/System/Volumes/Data"], capture_output=True, text=True).stdout
    return int(out.strip().splitlines()[-1].split()[3])


def main():
    out_dir = sys.argv[1]
    wanted = set(sys.argv[2:])
    os.makedirs(out_dir, exist_ok=True)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=f"{ST}/zig-global-cache",
               ZIG_LOCAL_CACHE_DIR=f"{ST}/zig-local-cache", TMPDIR=f"{ST}/tmp")
    for name, rel, before, after in MUTANTS:
        if wanted and name not in wanted:
            continue
        if free_mib() < 800:
            print(f"STOP: only {free_mib()} MiB free before {name}")
            return 1
        work = f"{ST}/tmp/mut-{name}"
        shutil.rmtree(work, ignore_errors=True)
        subprocess.run(["rsync", "-a", "--exclude", ".git", "--exclude", "evidence", f"{WT}/", f"{work}/"], check=True)
        path = os.path.join(work, rel)
        text = open(path).read()
        if text.count(before) != 1:
            print(f"ERROR: {name} matched {text.count(before)} times in {rel}")
            return 1
        open(path, "w").write(text.replace(before, after))

        log_path = os.path.join(out_dir, f"{name}.log")
        with open(log_path, "w") as log:
            code = subprocess.run([ZIG, "build", "test", "-Dtest-group=mcp", "--summary", "all"],
                                  cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
        log_text = open(log_path).read()
        summary = next((l for l in log_text.splitlines() if l.startswith("Build Summary")), "")
        cached = "compile test" in log_text and " cached" in log_text
        failed = ";".join(sorted(set(
            l.split("'")[1][10:50] for l in log_text.splitlines()
            if l.startswith("error: '") and ("failed" in l or "terminated" in l))))
        print(f"{name} exit={code} cached={int(cached)} {summary} :: {failed}", flush=True)
        shutil.rmtree(work, ignore_errors=True)
    print(subprocess.run(["df", "-h", "/System/Volumes/Data"], capture_output=True, text=True).stdout.strip().splitlines()[-1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
