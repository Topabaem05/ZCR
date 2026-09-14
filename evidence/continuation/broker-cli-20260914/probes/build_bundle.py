#!/usr/bin/env python3
"""Build evidence/continuation/broker-cli-20260914 in the clean slice C worktree (no commit).

Fails if any record does not bind to the code commit, if a record is missing, or if a mutant
did not fail its intended BR-004 CLI test.

usage: build_bundle.py
"""
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess

ST = "/Users/guribbong/code/ZCR-state/tasks/T01/broker-cli-20260914"
SHORT = "/Users/guribbong/code/ZCR-state/tasks/T01/bc"
WT = "/Users/guribbong/code/ZCR-worktrees/t01-broker-cli"
E = f"{WT}/evidence/continuation/broker-cli-20260914"
MAIN = "BR-004 zcr broker serve and mcp --broker take the token from an inherited fd and serve reads only"
NO_BROKER = "BR-004 zcr mcp --broker without a running broker refuses clearly and starts nothing"
REFUSE = "BR-004 zcr broker serve refuses a token on argv and a policy without broker_allowed"
MUTANTS = {
    "ignore_broker_allowed": ("broker role no longer requires broker_allowed", REFUSE),
    "bridge_zero_token": ("bridge sends an all-zero token", MAIN),
}
RECORDS = {
    "quiet-broker-debug": "broker group Debug (T01-broker-cli-test binary)",
    "quiet-broker-releasesafe": "broker group ReleaseSafe (T01-broker-cli-test binary)",
    "quiet-dev-debug": "dev group Debug including the zcr CLI contract checks (T01-test binary)",
    "quiet-mcp-debug": "mcp group Debug including MC-005 launch tests (T08-launch-test binary)",
}


def h(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def git(*a):
    return subprocess.run(["git", "-C", WT, *a], capture_output=True, text=True, check=True).stdout.strip()


def summary(label):
    text = open(f"{ST}/logs/{label}.log").read()
    lines = [l for l in text.splitlines() if l.startswith("Build Summary")]
    return (lines[-1].replace("Build Summary: ", "") if lines else "") + f"; {text.count('leaked')} leaks"


def failures(label):
    text = open(f"{ST}/logs/{label}.log").read()
    out = {}
    for block in re.split(r"(?m)^error: 'broker_cli_test\.test\.", text)[1:]:
        name = block.split("'")[0]
        body = re.findall(r"tests/broker_cli_test\.zig:(\d+):\d+: 0x[0-9a-f]+ in test\.", block)
        head = []
        for l in block.splitlines()[1:]:
            if l.strip().startswith("/") or l.startswith("failed command") or l.startswith("Build Summary"):
                break
            if l.strip():
                head.append(l.strip())
        out[name] = {"test_line": int(body[0]) if body else None, "message": " ".join(head)}
    return out


def main():
    C = open(f"{ST}/code-commit").read().strip()
    assert git("rev-parse", "HEAD") == C and git("status", "--porcelain") == ""
    tree = git("rev-parse", f"{C}^{{tree}}")
    base = git("merge-base", C, "origin/main")
    src = open(f"{WT}/tests/broker_cli_test.zig").read().splitlines()
    red = failures("red-br004-cli-debug")
    assert set(red) == {MAIN, NO_BROKER, REFUSE}, list(red)
    mutants = {}
    for name, (what, must) in MUTANTS.items():
        f = failures(f"mutant-{name}")
        assert must in f, (name, list(f))
        line = f[must]["test_line"]
        mutants[name] = {"change": what, "intended": must, "failed_tests": sorted(f), "test_line": line,
                         "assertion": src[line - 1].strip() if line else None, "message": f[must]["message"],
                         "log": f"logs/mutant-{name}.log", "summary": summary(f"mutant-{name}")}

    for sub in ("records", "task", "logs", "probes"):
        os.makedirs(f"{E}/{sub}", exist_ok=True)
    for label in RECORDS:
        r = json.load(open(f"{ST}/records/{label}.json"))
        assert r["source_commit"] == C and r["source_tree"] == tree, label
        shutil.copy(f"{ST}/records/{label}.json", f"{E}/records/")
    for name in ("manifest.json", "manifest-fence1.json", "authorization.json", "preflight.json", "scope-start.json", "scope-commit1.json"):
        shutil.copy(f"{ST}/task/{name}", f"{E}/task/{name}")
    for name in ("mutants.py", "record_runs.sh", "build_bundle.py"):
        shutil.copy(f"{ST}/task/{name}", f"{E}/probes/{name}")
    logs = ["red-br004-cli-debug", "green-br004-cli-debug", "validate2", "rec-preflight", "rec-contracts"] + list(RECORDS) + \
           [f"verify-{l}" for l in RECORDS] + [f"mutant-{m}" for m in MUTANTS]
    for name in logs:
        shutil.copy(f"{ST}/logs/{name}.log", f"{E}/logs/{name}.log")
    for name in ("red-br004-cli-debug.uptime", "green-br004-cli-debug.uptime", "mutants.uptime", "record_runs.uptime"):
        shutil.copy(f"{ST}/logs/{name}", f"{E}/logs/{name}")

    manifest = json.load(open(f"{E}/task/manifest.json"))
    zig = os.path.expanduser("~/.local/share/zig/0.16.0/zig")
    blob = lambda path: hashlib.sha256(subprocess.run(["git", "-C", WT, "show", f"{C}:{path}"], capture_output=True, check=True).stdout).hexdigest()
    files = lambda *p: sorted(x for x in git("ls-files", *p).split("\n") if x)
    config = {"schema": "zcr-t01-broker-cli-source-config/1", "derivation": "sha256 of this file's bytes is source_config_sha256; file hashes are sha256 of blobs at source_commit",
              "source_commit": C, "source_tree": tree, "base_commit": base, "contract_digest": manifest["contract_digest"], "workspace_id": manifest["workspace_id"],
              "build_config_file_hashes": {p: blob(p) for p in ["AGENTS.md", "build.zig", "build.zig.zon", "tasks/tasks.json"] + files("contracts") + files("config")},
              "source_file_hashes": {p: blob(p) for p in ["src/main.zig", "src/launch.zig", "src/launch_ignore.zig"] + files("src/broker", "src/core", "src/policy", "src/workspace", "src/protocol", "src/cache", "src/scheduler", "src/memory")},
              "toolchain": {"version": subprocess.run([zig, "version"], capture_output=True, text=True).stdout.strip(), "executable_sha256": h(zig)},
              "host": {"system": platform.system(), "release": platform.release(), "machine": platform.machine(), "macos": platform.mac_ver()[0], "ncpu": os.cpu_count()},
              "environment": {"ZIG_GLOBAL_CACHE_DIR": f"{SHORT}/zgc", "ZIG_LOCAL_CACHE_DIR": f"{SHORT}/zlc", "TMPDIR": f"{SHORT}/tmp", "STATE": ST,
                              "note": "short cache root: the broker socket lives under the test temp directory and must fit macOS sun_path (104 bytes)"}}
    corpus = {"schema": "zcr-t01-broker-cli-corpus/1", "derivation": "sha256 of this file's bytes is corpus_sha256; file hashes are sha256 of blobs at source_commit", "source_commit": C,
              "description": "Each CLI test creates a Git repository with one file.txt, a zcr-task/1 manifest and an approved launch policy in a private temporary directory; tokens are random per run.",
              **{p: blob(p) for p in ["tests/broker_cli_test.zig", "tests/t15_test.zig", "tests/t01_test.zig", "tests/launch_test.zig"]}}
    for name, doc in (("source-config.json", config), ("corpus.json", corpus)):
        with open(f"{E}/records/{name}", "w") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")
    cfg, corp = h(f"{E}/records/source-config.json"), h(f"{E}/records/corpus.json")
    runs = []
    for label in RECORDS:
        r = json.load(open(f"{E}/records/{label}.json"))
        runs.append({"label": label, "record": f"records/{label}.json", "record_sha256": h(f"{E}/records/{label}.json"), "source_commit": C, "source_tree": tree,
                     "worktree_git_dir": r["worktree_git_dir"], "workspace_id": manifest["workspace_id"], "command": r["command"], "exit_code": r["exit_code"],
                     "binary_sha256": r["binary_sha256"], "source_config_sha256": cfg, "corpus_sha256": corp, "log": f"logs/{label}.log",
                     "log_sha256": h(f"{E}/logs/{label}.log"), "verify_log": f"logs/verify-{label}.log", "summary": summary(label),
                     "status": "PASS" if r["exit_code"] == 0 else "FAIL"})
    json.dump({"schema": "zcr-t01-broker-cli-runs/1", "verify": "zcr-dev-evidence verify --worktree <clean worktree at source_commit> --evidence <record>",
               "note": "exit codes are recorded as observed; runs started only with no other zig build, no other evidence run and load average below the CPU count",
               "runs": runs}, open(f"{E}/records/runs.json", "w"), indent=2)
    by = {x["label"]: x for x in runs}
    start_uptime = open(f"{ST}/logs/record_runs.uptime").read().strip()

    def row(label):
        x = by[label]
        return f"| [{label}]({x['record']}) | {RECORDS[label]} | `{x['binary_sha256'][:8]}…` | exit {x['exit_code']}; {x['summary']} ([log]({x['log']})) |"

    def redrow(name):
        return f"| `{name}` | line {red[name]['test_line']}: `{src[red[name]['test_line'] - 1].strip()}` {red[name]['message']} |"

    def mrow(name):
        m = mutants[name]
        return f"| `{name}` | {m['change']} | FAIL `{m['intended']}` at line {m['test_line']}: `{m['assertion']}` ([log]({m['log']})) |"

    readme = f"""# Broker CLI wiring: `zcr broker serve` and `zcr mcp --broker`

**Date:** 2026-09-14 · **Host:** Apple M2 8 CPU, macOS {platform.mac_ver()[0]}, Zig 0.16.0 · **Base:** `{base[:7]}` · **Source:** `{C[:7]}` (tree `{tree[:8]}…`) · **Task:** T01 integrator (docs/18 row 2, slice C)

## Decision and scope

The repository owner chose, in this session, to wire the broker CLI as the T01 integrator, to add no supervisor for now, and to record the T11 pre-publish hook only as a proposal. docs/02 §2.2 and docs/03 name the roles. docs/11 requires the token to travel by inherited handle or protected file, never argv. docs/14 §5 says a missing broker must not be started silently.

## Change (`{C[:7]}`)

- **`zcr broker serve --socket /abs --policy /abs --token-fd FD`** reads the token from descriptor FD (at least 3, 64 lowercase hex digits and an optional newline) and closes it. It binds one approved grant through the same launch path as standalone: approved policy, manifest, workspace identity, registry, session, authorizer and cache. The launch policy must set `broker_allowed`. It creates the UDS broker with one executor and one group budget, writes `zcr broker: listening domain=N` to stderr and serves until its stdin closes.
- **`zcr mcp --broker --socket /abs --domain N --token-fd FD`** relays stdio to a running broker. A missing broker or a wrong token exits 69 with a message that no broker was started and that `zcr mcp --standalone` is the alternative.
- **Refusals:** a `--token` on argv exits 64 (usage), and the token is not echoed. Standalone `zcr mcp` still refuses a policy that allows the broker. Writes stay disabled: the handshake keeps `"writes":false`, and patch/create remain unsupported.
- **Ownership:** `src/launch.zig` is assigned to T01 in `tasks/tasks.json` and `tasks/T01.md`. `build.zig` gives the launch module the broker and executor imports, registers `tests/broker_cli_test.zig` (group broker), and passes it the built `zcr` path. `DESIGNBOOK.html` and `MANIFEST.sha256` are regenerated, and `validate_bundle.py` passes.

## RED, GREEN, mutants

The tests run the built `zcr` binary as real subprocesses and pass the token through a pipe descriptor that is not close-on-exec.

RED before the change ([log](logs/red-br004-cli-debug.log)):

| Test | Failure |
|---|---|
{redrow(MAIN)}
{redrow(NO_BROKER)}
{redrow(REFUSE)}

GREEN after the change: {summary('green-br004-cli-debug')} ([log](logs/green-br004-cli-debug.log)). This run was not quiet ([uptime](logs/green-br004-cli-debug.uptime)).

| Mutant | Change | Result |
|---|---|---|
{mrow('ignore_broker_allowed')}
{mrow('bridge_zero_token')}

## Records (`zcr-evidence/1`, verified after recording)

The runs started with no other zig process, no other evidence run and a 1-minute load average below the CPU count, at `{start_uptime}`. Other applications on the host were not stopped, and the load rose during the run.

| Record | Run | Binary | Result |
|---|---|---|---|
{row('quiet-broker-debug')}
{row('quiet-broker-releasesafe')}
{row('quiet-dev-debug')}
{row('quiet-mcp-debug')}

[records/runs.json](records/runs.json) binds each record to its log digest, `source_config_sha256` `{cfg[:8]}…` ([source-config.json](records/source-config.json)) and `corpus_sha256` `{corp[:8]}…` ([corpus.json](records/corpus.json)).

## Task identity

[task/manifest.json](task/manifest.json) (`zcr-task/1`, workspace `{manifest['workspace_id']}`, base `{manifest['base_commit'][:7]}`), [task/authorization.json](task/authorization.json) and [task/preflight.json](task/preflight.json) were issued before any edit. Fence 2 added `tasks/T01.md` and `DESIGNBOOK.html` before either was edited, because `validate_bundle.py` requires every owned path to appear in the task document and `render_book.py` renders that document. The fence-1 manifest is kept. `zcr-dev-guard scope` reported 0 violations at the start ([task/scope-start.json](task/scope-start.json)) and on the code commit ([task/scope-commit1.json](task/scope-commit1.json)).

## Limits

- One grant per broker process. Several grants, and a supervisor that rebinds sessions after a broker crash, are not implemented (no supervisor, by decision).
- The broker keeps the conservative launch budget: the first memory profile's inflight bucket and one CPU permit.
- Not verified: Linux and Intel Mac runtime (native CI on the PR), Windows named pipes, actual host (Claude Code) registration of the bridge.
"""
    open(f"{E}/README.md", "w").write(readme)
    print(json.dumps({"code_commit": C[:7], "base": base[:7], "runs": [(x["label"], x["exit_code"], x["summary"]) for x in runs],
                      "mutants": {k: (v["intended"][:40], v["test_line"]) for k, v in mutants.items()}}, indent=1))


if __name__ == "__main__":
    main()
