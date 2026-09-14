#!/usr/bin/env python3
"""Build evidence/T15/reconnect-20260914 and create or extend evidence/T15/handoff.json.

Reads the code commit, records, logs, task files and mutant results from the task state directory
and writes them into the clean T15 worktree (no commit). Fails if any record does not bind to the
code commit, if a record is missing, or if a mutant did not fail the new BR-005 test.

usage: build_bundle.py
"""
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess

ST = "/Users/guribbong/code/ZCR-state/tasks/T15/reconnect-20260914"
SHORT = "/Users/guribbong/code/ZCR-state/tasks/T15/r"
WT = "/Users/guribbong/code/ZCR-worktrees/t15-reconnect"
E = f"{WT}/evidence/T15/reconnect-20260914"
TEST = "BR-005 real UDS reconnect after disconnect and broker restart needs a host rebind at a new fence and replays nothing"
MUTANTS = {
    "keep_binding_on_close": "closeSession keeps the grant's registry binding",
    "ignore_fence": "task binding matches regardless of fence",
}
RECORDS = {"quiet-broker-debug-t15": "quiet-broker-debug", "quiet-broker-releasesafe-t15": "quiet-broker-releasesafe"}


def h(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def git(*a):
    return subprocess.run(["git", "-C", WT, *a], capture_output=True, text=True, check=True).stdout.strip()


def summary(label):
    text = open(f"{ST}/logs/{label}.log").read()
    lines = [l for l in text.splitlines() if l.startswith("Build Summary")]
    return (lines[-1].replace("Build Summary: ", "") if lines else "") + f"; {text.count('leaked')} leaks"


def failures(label):
    """Failed test name -> first test-body location (file:line) and first message line."""
    text = open(f"{ST}/logs/{label}.log").read()
    out = {}
    for block in re.split(r"(?m)^error: 't15_test\.test\.", text)[1:]:
        name = block.split("'")[0]
        body = re.findall(r"tests/t15_test\.zig:(\d+):\d+: 0x[0-9a-f]+ in test\.", block)
        # Messages such as "expected 2, found 0" precede the first trace path; source excerpts follow paths.
        head = []
        for l in block.splitlines()[1:]:
            if l.strip().startswith("/") or l.startswith("failed command") or l.startswith("Build Summary"):
                break
            if l.strip():
                head.append(l.strip())
        msg = " ".join(head)
        out[name] = {"test_line": int(body[0]) if body else None, "message": msg}
    return out


def main():
    C = open(f"{ST}/code-commit").read().strip()
    assert git("rev-parse", "HEAD") == C and git("status", "--porcelain") == ""
    tree = git("rev-parse", f"{C}^{{tree}}")
    base = git("merge-base", C, "origin/main")
    src_lines = open(f"{WT}/tests/t15_test.zig").read().splitlines()
    mutants = {}
    for name, what in MUTANTS.items():
        f = failures(f"mutant-{name}")
        assert TEST in f, (name, list(f))
        line = f[TEST]["test_line"]
        mutants[name] = {"change": what, "log": f"logs/mutant-{name}.log", "summary": summary(f"mutant-{name}"),
                         "failed_tests": sorted(f), "test_line": line, "assertion": src_lines[line - 1].strip() if line else None,
                         "message": f[TEST]["message"]}

    for sub in ("records", "task", "logs", "probes"):
        os.makedirs(f"{E}/{sub}", exist_ok=True)
    for label in RECORDS:
        r = json.load(open(f"{ST}/records/{label}.json"))
        assert r["source_commit"] == C and r["source_tree"] == tree, label
        shutil.copy(f"{ST}/records/{label}.json", f"{E}/records/")
    for name in ("manifest.json", "authorization.json", "preflight.json", "scope-start.json", "scope-commit1.json"):
        shutil.copy(f"{ST}/task/{name}", f"{E}/task/{name}")
    for name in ("mutants.py", "record_runs.sh", "build_bundle.py"):
        shutil.copy(f"{ST}/task/{name}", f"{E}/probes/{name}")
    logs = ["probe1-br005-debug", "probe2-br005-debug", "green-br005-debug", "rec-preflight", "rec-contracts",
            "quiet-broker-debug", "quiet-broker-releasesafe", "verify-quiet-broker-debug-t15", "verify-quiet-broker-releasesafe-t15"] + [f"mutant-{m}" for m in MUTANTS]
    for name in logs:
        shutil.copy(f"{ST}/logs/{name}.log", f"{E}/logs/{name}.log")
    shutil.copy(f"{ST}/logs/record_runs.uptime", f"{E}/logs/record_runs.uptime")

    manifest = json.load(open(f"{E}/task/manifest.json"))
    zig = os.path.expanduser("~/.local/share/zig/0.16.0/zig")
    blob = lambda path: hashlib.sha256(subprocess.run(["git", "-C", WT, "show", f"{C}:{path}"], capture_output=True, check=True).stdout).hexdigest()
    files = lambda *p: sorted(x for x in git("ls-files", *p).split("\n") if x)
    config = {"schema": "zcr-t15-source-config/1", "derivation": "sha256 of this file's bytes is source_config_sha256; file hashes are sha256 of blobs at source_commit",
              "source_commit": C, "source_tree": tree, "base_commit": base, "contract_digest": manifest["contract_digest"], "workspace_id": manifest["workspace_id"],
              "build_config_file_hashes": {p: blob(p) for p in ["AGENTS.md", "build.zig", "build.zig.zon"] + files("contracts") + files("config")},
              "source_file_hashes": {p: blob(p) for p in files("src/broker", "src/core", "src/policy", "src/workspace", "src/protocol", "src/cache", "src/executor", "src/memory")},
              "toolchain": {"version": subprocess.run([zig, "version"], capture_output=True, text=True).stdout.strip(), "executable_sha256": h(zig)},
              "host": {"system": platform.system(), "release": platform.release(), "machine": platform.machine(), "macos": platform.mac_ver()[0], "ncpu": os.cpu_count()},
              "environment": {"ZIG_GLOBAL_CACHE_DIR": f"{SHORT}/zgc", "ZIG_LOCAL_CACHE_DIR": f"{SHORT}/zlc", "TMPDIR": f"{SHORT}/tmp", "STATE": ST,
                              "note": "short cache root: test socket paths live under the local cache and must fit macOS sun_path (104 bytes)"}}
    corpus = {"schema": "zcr-t15-corpus/1", "derivation": "sha256 of this file's bytes is corpus_sha256; file hashes are sha256 of blobs at source_commit", "source_commit": C,
              "description": "Each test creates a Git repository with one file.txt and a private socket directory under its temporary directory with /usr/bin/git; no checked-in data files.",
              "tests/t15_test.zig": blob("tests/t15_test.zig")}
    for name, doc in (("source-config.json", config), ("corpus.json", corpus)):
        with open(f"{E}/records/{name}", "w") as f:
            json.dump(doc, f, indent=2, sort_keys=True)
            f.write("\n")
    cfg, corp = h(f"{E}/records/source-config.json"), h(f"{E}/records/corpus.json")
    runs = []
    for label, log in RECORDS.items():
        r = json.load(open(f"{E}/records/{label}.json"))
        runs.append({"label": label, "record": f"records/{label}.json", "record_sha256": h(f"{E}/records/{label}.json"), "source_commit": C, "source_tree": tree,
                     "worktree_git_dir": r["worktree_git_dir"], "workspace_id": manifest["workspace_id"], "command": r["command"], "exit_code": r["exit_code"],
                     "binary_sha256": r["binary_sha256"], "source_config_sha256": cfg, "corpus_sha256": corp, "log": f"logs/{log}.log",
                     "log_sha256": h(f"{E}/logs/{log}.log"), "verify_log": f"logs/verify-{label}.log", "summary": summary(log),
                     "status": "PASS" if r["exit_code"] == 0 else "FAIL"})
    json.dump({"schema": "zcr-t15-runs/1", "verify": "zcr-dev-evidence verify --worktree <clean worktree at source_commit> --evidence <record>",
               "note": "exit codes are recorded as observed; the runs started only with no other zig process and a 1-minute load average below the CPU count; other applications could still load the host during the run", "runs": runs},
              open(f"{E}/records/runs.json", "w"), indent=2)
    by = {x["label"]: x for x in runs}

    def row(label, title):
        x = by[label]
        return f"| [{label}]({x['record']}) | {title} | `{x['binary_sha256'][:8]}…` | exit {x['exit_code']}; {x['summary']} ([log]({x['log']})) |"

    def mrow(name):
        m = mutants[name]
        return f"| `{name}` | {m['change']} | FAIL at line {m['test_line']}: `{m['assertion']}` ([log]({m['log']})) |"

    readme = f"""# T15: BR-005 reconnect over a real UDS broker

**Date:** 2026-09-14 · **Host:** Apple M2 8 CPU, macOS {platform.mac_ver()[0]}, Zig 0.16.0 · **Base:** `{base[:7]}` · **Source:** `{C[:7]}` (tree `{tree[:8]}…`)

## Question

docs/18 row 2 lists the write/reconnect lifecycle as open. BR-005 requires that a bridge reconnect after a broker crash never resends a write and only looks up receipts. Unit tests covered the `bridge.Reconnect` state machine, but no test drove a real UDS broker through a disconnect and restart.

## Test (`{C[:7]}`: `tests/t15_test.zig` only)

`{TEST}`. Over a real UDS broker:

1. A client reads `file.txt` and disconnects. The grant is then refused, because closing the session removed its host binding.
2. The broker stops and a new instance is created. The grant is still refused.
3. The host binds the session again at fence 2. A writer lease for the fence-1 task is refused with `FenceMismatch`.
4. The grant reconnects. The first response line answers the new request (`id` 9), not the earlier one (`id` 2).

## Result: existing behavior, no production change

The test passed against unchanged broker, bridge and registry code, so this is characterization rather than a RED for new code. Two mutants on copies of the tree show the test detects the behaviors it claims:

| Mutant | Change | Result |
|---|---|---|
{mrow('keep_binding_on_close')}
{mrow('ignore_fence')}

| Run | Result |
|---|---|
| first probe, long state cache path | FAIL before any broker assertion: `auth.address` refused the 110-byte socket path (macOS limit 104) ([log](logs/probe1-br005-debug.log)) |
| second probe, short cache root | lifecycle assertions passed; an extra `completed == 2` counter assertion failed (found 0) because `initialize` and `ping` do not use the counted job path. The assertion was removed ([log](logs/probe2-br005-debug.log)) |
| BR-005 Debug after that change | {summary('green-br005-debug')} ([log](logs/green-br005-debug.log)) |

## Records (`zcr-evidence/1`, verified after recording)

| Record | Run | Binary | Result |
|---|---|---|---|
{row('quiet-broker-debug-t15', 'broker group Debug, started with no other zig process and load below the CPU count')}
{row('quiet-broker-releasesafe-t15', 'broker group ReleaseSafe, same run')}

[records/runs.json](records/runs.json) binds each record to its log digest, `source_config_sha256` `{cfg[:8]}…` ([source-config.json](records/source-config.json)) and `corpus_sha256` `{corp[:8]}…` ([corpus.json](records/corpus.json)). The Zig local cache used a short root, because test socket paths live under it. The runs started at `{open(f'{ST}/logs/record_runs.uptime').read().strip()}` ([uptime](logs/record_runs.uptime)); other applications were not stopped.

## Task identity

[task/manifest.json](task/manifest.json) (`zcr-task/1`, workspace `{manifest['workspace_id']}`, base `{manifest['base_commit'][:7]}`), [task/authorization.json](task/authorization.json) and [task/preflight.json](task/preflight.json) were issued before any edit. `zcr-dev-guard scope` reported 0 violations at the start ([task/scope-start.json](task/scope-start.json)) and on the code commit against the base ([task/scope-commit1.json](task/scope-commit1.json)).

## Limits

- Writes stay disabled (`"writes":false`), so no write is in flight during the disconnect. The no-resend and receipt-lookup rules for an uncertain write remain covered only by the `bridge.Reconnect` unit tests.
- The broker restart is simulated in one process with a shared registry, not a killed process. The host rebind is done by the test, not by a supervisor (there is no supervisor yet).
- Not verified: Linux and Intel Mac runtime (native CI on the PR), Windows, actual host launch integration.
"""
    open(f"{E}/README.md", "w").write(readme)

    hp = f"{WT}/evidence/T15/handoff.json"
    hd = json.load(open(hp)) if os.path.exists(hp) else {"schema_version": "zcr-t15-handoff/1", "task": "T15",
                                                           "prior_evidence": ["evidence/continuation/runtime-review-fixes/r2/README.md",
                                                                              "evidence/continuation/review-checkpoints/runtime-wave-final.md",
                                                                              "evidence/continuation/integrated-108b906/README.md"]}
    revision = {
        "revision": "BR-005 real UDS reconnect characterization",
        "date": "2026-09-14",
        "base_commit": base, "head_commit": C, "source_tree": tree,
        "head_commit_note": "Tested source commit; the evidence-only commit follows.",
        "contract_digest": manifest["contract_digest"], "workspace_id": manifest["workspace_id"],
        "task_manifest": "evidence/T15/reconnect-20260914/task/manifest.json", "task_manifest_sha256": h(f"{E}/task/manifest.json"),
        "scope_report": "evidence/T15/reconnect-20260914/task/scope-commit1.json (0 violations)",
        "changed_files": ["tests/t15_test.zig"],
        "exports_added": [],
        "behaviour_change": "none; the test characterizes existing broker, bridge and registry behavior",
        "tests": {label: {"record": x["record"], "exit_code": x["exit_code"], "summary": x["summary"]} for label, x in by.items()},
        "mutants": mutants,
        "source_config_sha256": cfg, "corpus_sha256": corp,
        "remaining_gates": ["write-enabled reconnect with an uncertain write (writes stay disabled; unit coverage only)",
                            "supervisor-driven rebind after a real broker process crash (no supervisor by decision)",
                            "broker CLI wiring (T01 slice C)",
                            "native Linux/Intel Mac runtime for this revision beyond PR CI, Windows and actual host integration NOT_RUN"],
        "evidence": "evidence/T15/reconnect-20260914/README.md",
    }
    hd.setdefault("revisions", []).append(revision)
    json.dump(hd, open(hp, "w"), indent=2)
    open(hp, "a").write("\n")
    print(json.dumps({"code_commit": C[:7], "base": base[:7], "runs": [(x["label"], x["exit_code"], x["summary"]) for x in runs],
                      "mutants": {k: (v["test_line"], v["assertion"]) for k, v in mutants.items()}}, indent=1))


if __name__ == "__main__":
    main()
