#!/usr/bin/env python3
"""Build evidence/T12/host-witness-20260914 and append a revision to evidence/T12/handoff.json.

Reads the code commit, records, logs, task files and mutant results from the task state directory
and writes them into the clean T12 worktree (no commit). Fails if any record does not bind to the
code commit, if a record is missing, or if a mutant did not fail its intended WR-008 test.

usage: build_bundle.py
"""
import glob
import hashlib
import json
import os
import platform
import shutil
import subprocess

ST = "/Users/guribbong/code/ZCR-state/tasks/T12/host-witness-20260914"
WT = "/Users/guribbong/code/ZCR-worktrees/t12-host-witness"
E = f"{WT}/evidence/T12/host-witness-20260914"
TEMP_TEST = "WR-008 host witness grants once and refuses a replaced temp name after unlink"
TARGET_TEST = "WR-008 host witness accepts an applied publication and refuses a foreign target"
# mutant -> (log label, WR-008 test that must fail)
MUTANTS = {
    "no_temp_name_check": ("mutant-no_temp_name_check", TEMP_TEST),
    "no_one_use": ("mutant-no_one_use-quiet", TEMP_TEST),
    "leaf_original_only": ("mutant-leaf_original_only-quiet", TARGET_TEST),
}
# First runs of these mutants shared the CPU with other builds; kept as observed.
LOADED = ["mutant-no_one_use", "mutant-leaf_original_only"]
RECORDS = {
    "loaded-write-debug-t12": "loaded-write-debug",
    "quiet-write-debug-t12": "quiet-write-debug",
    "quiet-write-releasesafe-t12": "quiet-write-releasesafe",
    "quiet2-write-debug-t12": "quiet2-write-debug",
    "quiet3-write-debug-t12": "quiet3-write-debug",
}


def h(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def git(*a):
    return subprocess.run(["git", "-C", WT, *a], capture_output=True, text=True, check=True).stdout.strip()


def summary(label):
    text = open(f"{ST}/logs/{label}.log").read()
    lines = [l for l in text.splitlines() if l.startswith("Build Summary")]
    return (lines[-1].replace("Build Summary: ", "") if lines else "") + f"; {text.count('leaked')} leaks"


def failed_tests(label):
    text = open(f"{ST}/logs/{label}.log").read()
    return sorted({l.split("'")[1].removeprefix("t12_test.test.") for l in text.splitlines() if l.startswith("error: 't12_test.test.")})


def main():
    C = open(f"{ST}/code-commit").read().strip()
    assert git("rev-parse", "HEAD") == C and git("status", "--porcelain") == ""
    tree = git("rev-parse", f"{C}^{{tree}}")
    base = git("merge-base", C, "origin/main")
    mutants = {}
    for name, (log, must) in MUTANTS.items():
        failed = failed_tests(log)
        assert must in failed, (name, failed)
        mutants[name] = {"log": f"logs/{log}.log", "summary": summary(log), "failed_tests": failed, "intended": must}

    for sub in ("records", "task", "logs", "probes"):
        os.makedirs(f"{E}/{sub}", exist_ok=True)
    for label in RECORDS:
        r = json.load(open(f"{ST}/records/{label}.json"))
        assert r["source_commit"] == C and r["source_tree"] == tree, label
        shutil.copy(f"{ST}/records/{label}.json", f"{E}/records/")
    for name in ("manifest.json", "authorization.json", "preflight.json", "scope-start.json", "scope-commit1.json", "t11-hook-proposal.json"):
        shutil.copy(f"{ST}/task/{name}", f"{E}/task/{name}")
    for name in ("mutants.py", "record_runs.sh", "build_bundle.py"):
        shutil.copy(f"{ST}/task/{name}", f"{E}/probes/{name}")
    logs = ["red-compile", "green2-wr008-debug", "rec-contracts", "rec-preflight"] + list(RECORDS.values()) + \
           [f"verify-{l}" for l in RECORDS] + [v[0] for v in MUTANTS.values()] + [f"diag-wr005-run-{i}" for i in (1, 2, 3)]
    for name in sorted(set(logs + LOADED)):
        shutil.copy(f"{ST}/logs/{name}.log", f"{E}/logs/{name}.log")
    for name in ("record_runs.uptime", "loaded-write-debug.uptime", "quiet2-write-debug.uptime", "quiet3-write-debug.uptime", "diag-wr005.patch"):
        shutil.copy(f"{ST}/logs/{name}", f"{E}/logs/{name}")
    for name in ("rerun_write_debug.sh",):
        shutil.copy(f"{ST}/task/{name}", f"{E}/probes/{name}")

    manifest = json.load(open(f"{E}/task/manifest.json"))
    zig = os.path.expanduser("~/.local/share/zig/0.16.0/zig")
    blob = lambda path: hashlib.sha256(subprocess.run(["git", "-C", WT, "show", f"{C}:{path}"], capture_output=True, check=True).stdout).hexdigest()
    files = lambda *p: sorted(x for x in git("ls-files", *p).split("\n") if x)
    config = {"schema": "zcr-t12-source-config/1", "derivation": "sha256 of this file's bytes is source_config_sha256; file hashes are sha256 of blobs at source_commit",
              "source_commit": C, "source_tree": tree, "base_commit": base, "contract_digest": manifest["contract_digest"], "workspace_id": manifest["workspace_id"],
              "build_config_file_hashes": {p: blob(p) for p in ["AGENTS.md", "build.zig", "build.zig.zon"] + files("contracts") + files("config")},
              "source_file_hashes": {p: blob(p) for p in files("src/storage", "src/core", "src/policy", "src/workspace", "src/fs")},
              "toolchain": {"version": subprocess.run([zig, "version"], capture_output=True, text=True).stdout.strip(), "executable_sha256": h(zig)},
              "host": {"system": platform.system(), "release": platform.release(), "machine": platform.machine(), "macos": platform.mac_ver()[0], "ncpu": os.cpu_count()},
              "environment": {"ZIG_GLOBAL_CACHE_DIR": "$STATE/zig-global-cache", "ZIG_LOCAL_CACHE_DIR": "$STATE/zig-local-cache", "TMPDIR": "$STATE/tmp", "STATE": ST}}
    corpus = {"schema": "zcr-t12-corpus/1", "derivation": "sha256 of this file's bytes is corpus_sha256; file hashes are sha256 of blobs at source_commit", "source_commit": C,
              "description": "Git repositories, journals and publication fixtures are generated per test run by tests/t12_fixtures.zig with /usr/bin/git; no checked-in data files.",
              **{p: blob(p) for p in ["tests/t12_test.zig", "tests/t12_fixtures.zig", "tests/t12_child.zig", "tests/t11_test.zig"]}}
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
    json.dump({"schema": "zcr-t12-runs/1", "verify": "zcr-dev-evidence verify --worktree <clean worktree at source_commit> --evidence <record>",
               "note": "exit codes are recorded as observed; the loaded run started at load average about 220, the others with no other zig process and load below the CPU count, and other applications could load the host during a run", "runs": runs},
              open(f"{E}/records/runs.json", "w"), indent=2)
    by = {x["label"]: x for x in runs}

    def row(label, title):
        x = by[label]
        return f"| [{label}]({x['record']}) | {title} | `{x['binary_sha256'][:8]}…` | exit {x['exit_code']}; {x['summary']} ([log]({x['log']})) |"

    def mrow(name, what):
        m = mutants[name]
        others = [t for t in m["failed_tests"] if t != m["intended"]]
        extra = f"; also failed: {', '.join(others)}" if others else ""
        return f"| `{name}` | {what} | FAIL `{m['intended']}`{extra} ([log]({m['log']})) |"

    parts = []
    for log in LOADED:
        name = log.removeprefix("mutant-")
        others = [t for t in failed_tests(log) if t != MUTANTS[name][1]]
        assert MUTANTS[name][1] in failed_tests(log), log
        parts.append(f"`{name}` also failed {len(others)} older WR-008 tests ([log](logs/{log}.log))")
    loaded_note = ("The first runs of two mutants shared the CPU with other builds. Each failed its intended test, but " + "; ".join(parts) +
                   ". Those extra failures went through discovery git timeouts (`process.run` in `identity.discoverWith`), the load condition recorded in "
                   "`evidence/T10/git-timeout-20260914`. The quiet reruns above are the mutant results.")
    readme = f"""# T12: host witness for continuity and publication

**Date:** 2026-09-14 · **Host:** Apple M2 8 CPU, macOS {platform.mac_ver()[0]}, Zig 0.16.0 · **Base:** `{base[:7]}` · **Source:** `{C[:7]}` (tree `{tree[:8]}…`)

## Problem

docs/18 row 2 lists a trusted host that retains the root, state and per-publication handles and issues a one-use continuity grant. `recovery.ContinuityGrant` already had `validate` and `validate_publication` callbacks, but only test-local witnesses implemented them. No production type retained publication handles, so recovery could not re-check the live temp, target and parent that a journal record names.

## Change (`{C[:7]}`: `src/storage/recovery.zig`, `tests/t12_test.zig`)

- **`recovery.HostWitness`:** `init(io, identity, state)` keeps the trusted workspace identity and state directory. `retainPublication(parent, record)` takes ownership of the parent handle, opens the temp and the original by observed identity (a create requires the target to be absent), and keeps at most 16 publications. `grant(data)` returns a `ContinuityGrant`.
- **`validate`** is one-use. It checks the state directory identity against the grant, re-validates the workspace identity, and matches the journal namespace.
- **`validate_publication`** is refused before `validate`. It matches the publication digest, then re-stats the retained handles: the temp name must be absent or still the retained temp, and the target must be absent, the retained original or the retained temp (the rename applied). Anything else returns `RecoveryRequired`.
- **Tests:** `{TEMP_TEST}` and `{TARGET_TEST}`.
- Production writes stay disabled. No caller outside tests constructs a `HostWitness` yet (see the T11 hook proposal below).

## RED, mutants, GREEN

| Run | Result |
|---|---|
| WR-008 before the change | compile error: no `HostWitness` in `recovery` ([log](logs/red-compile.log)) |
| WR-008 after the change | {summary('green2-wr008-debug')} ([log](logs/green2-wr008-debug.log)) |
| `zig build verify-contracts` | see [log](logs/rec-contracts.log) |

Each [mutant](probes/mutants.py) was applied to a copy of the tree; the task worktree was never modified.

| Mutant | Change | Result |
|---|---|---|
{mrow('no_temp_name_check', 'accept any entry at the temp name')}
{mrow('no_one_use', 'drop the one-use guard on validate (quiet rerun)')}
{mrow('leaf_original_only', 'accept only the original at the target, not the renamed temp (quiet rerun)')}

{loaded_note}

## Records (`zcr-evidence/1`, verified after recording)

| Record | Run | Binary | Result |
|---|---|---|---|
{row('loaded-write-debug-t12', 'write group Debug; load average about 220 from other applications, run stopped after Debug')}
{row('quiet-write-debug-t12', 'write group Debug; started at load 7.87, load rose past 38 during the run')}
{row('quiet-write-releasesafe-t12', 'write group ReleaseSafe; same session')}
{row('quiet2-write-debug-t12', 'write group Debug; started at load 5.70, a concurrent local build then raised load to 45-60')}
{row('quiet3-write-debug-t12', 'write group Debug; started at load 4.65')}

The three earlier Debug runs failed on the load signature seen in `evidence/T10/git-timeout-20260914`: T11 tests (which do not build the changed storage code) through git discovery timeouts, and T12 WR-005, whose recovery child closed its pipe before sending its hello. Before its hello the child runs fixture setup, which registers the workspace through git discovery with a 5000 ms budget. The child's stderr goes to a file in the test's temporary directory, which is deleted, so a copy of the tree kept each child's stderr outside it ([patch](logs/diag-wr005.patch), [script](probes/rerun_write_debug.sh)) and ran WR-005 Debug three times at load 6.8, 4.4 and 3.4: 3/3 passed ([1](logs/diag-wr005-run-1.log), [2](logs/diag-wr005-run-2.log), [3](logs/diag-wr005-run-3.log)). The third Debug run at the code commit then passed 70/70. The earlier failures stay recorded as observed; attributing WR-005's failures to discovery timeouts under load is an inference, because no failing child's stderr was captured.

[records/runs.json](records/runs.json) binds each record to its log digest, `source_config_sha256` `{cfg[:8]}…` ([source-config.json](records/source-config.json)) and `corpus_sha256` `{corp[:8]}…` ([corpus.json](records/corpus.json)).

## Proposed interface change for T11 (not implemented)

[task/t11-hook-proposal.json](task/t11-hook-proposal.json). `Editor.finishPublish` never hands out the parent, temp and original handles between PREPARED and the rename, so no host code can call `retainPublication` for a real publication. The proposal adds an optional pre-publish hook in `Editor.Options` that runs after `journal.prepare` stores the record and before `acquireCommit`. The repository owner chose to record the proposal only.

## Task identity

[task/manifest.json](task/manifest.json) (`zcr-task/1`, workspace `{manifest['workspace_id']}`, base `{manifest['base_commit'][:7]}`), [task/authorization.json](task/authorization.json) and [task/preflight.json](task/preflight.json) were issued before any edit. `zcr-dev-guard scope` reported 0 violations at the start ([task/scope-start.json](task/scope-start.json)) and on the code commit against the base ([task/scope-commit1.json](task/scope-commit1.json)).

## Limits

- No production caller: the launcher and T11 editor do not construct a `HostWitness`; cold start stays quarantined.
- The witness holds at most 16 publications per grant.
- Not verified: Linux and Intel Mac runtime (native CI on the PR), Windows, actual host launch integration.
"""
    open(f"{E}/README.md", "w").write(readme)

    hp = f"{WT}/evidence/T12/handoff.json"
    hd = json.load(open(hp))
    revision = {
        "revision": "host witness for continuity and publication",
        "date": "2026-09-14",
        "base_commit": base, "head_commit": C, "source_tree": tree,
        "head_commit_note": "Tested source commit; the evidence-only commit follows.",
        "contract_digest": manifest["contract_digest"], "workspace_id": manifest["workspace_id"],
        "task_manifest": "evidence/T12/host-witness-20260914/task/manifest.json", "task_manifest_sha256": h(f"{E}/task/manifest.json"),
        "scope_report": "evidence/T12/host-witness-20260914/task/scope-commit1.json (0 violations)",
        "changed_files": ["src/storage/recovery.zig", "tests/t12_test.zig"],
        "exports_added": ["recovery.HostWitness.init(Io, *const workspace.identity.Identity, Io.Dir)", "HostWitness.deinit()",
                          "HostWitness.retainPublication(Io.Dir, core.PreparedRecord) !void (takes ownership of the parent handle)",
                          "HostWitness.grant(GrantData) ContinuityGrant", "HostWitness.max_publications = 16"],
        "tests": {label: {"record": x["record"], "exit_code": x["exit_code"], "summary": x["summary"]} for label, x in by.items()},
        "mutants": mutants,
        "source_config_sha256": cfg, "corpus_sha256": corp,
        "interface_change_proposal": json.load(open(f"{E}/task/t11-hook-proposal.json")),
        "remaining_gates": ["T11 pre-publish hook (proposal only) and launcher wiring before any production caller constructs HostWitness",
                            "native Linux/Intel Mac runtime for this revision beyond PR CI, Windows and actual host integration NOT_RUN",
                            "production writes remain disabled"],
        "evidence": "evidence/T12/host-witness-20260914/README.md",
    }
    hd["revisions"] = [r for r in hd.get("revisions", []) if r.get("revision") != revision["revision"]] + [revision]
    json.dump(hd, open(hp, "w"), indent=2)
    open(hp, "a").write("\n")
    print(json.dumps({"code_commit": C[:7], "base": base[:7], "runs": [(x["label"], x["exit_code"], x["summary"]) for x in runs],
                      "mutants": {k: v["intended"] for k, v in mutants.items()}}, indent=1))


if __name__ == "__main__":
    main()
