# T08 MC-004 deadline test: observe the watcher's cancellation

**Date:** 2026-09-14 · **Host:** Apple M2 8 GB, macOS 26.6.2, Zig 0.16.0 · **Base:** `main` `a15b127` · **Source:** `3621430` (tree `ddcf33e6…`)

Canonical handoff: `evidence/T08/handoff.json`. PASS records bind to `3621430`; this bundle is added by a later evidence-only commit.

## Problem

`MC-004 deadline watcher interrupts before filesystem work and output failure drains` slept 15 ms in the authority check and read a missing file. A mutant whose deadline watcher never sets the cancellation flag still passed (PR #3 evidence, `evidence/T08/mc004-retirement-20260913/README.md` section 3): the read ran and the worker still rewrote the result to `E_DEADLINE`.

## Change (`3621430`: `src/protocol/mcp.zig`, `tests/t08_test.zig`)

- `Config` gains `deadline_context` and `after_deadline_cancel`, an optional deterministic hook. The watcher calls it once for each request it expires, after setting the request's cancellation flag, outside the transport lock. With no hook configured, behaviour is unchanged.
- The test's first authority check waits for that hook (bounded only by the shared 10 s hang guard), then returns. The request reads the existing `hello.txt` with `deadline_ms` 500.
- Assertions: `E_DEADLINE`, no file content in the output, the hook fired, no hang-guard timeout, and exactly one authority check. A read that ran would succeed and trigger the second, post-execution authority check.

## RED, controls and GREEN

| Run | Binary | Result |
|---|---|---|
| new test before the hook exists | — | compile error: no field `deadline_context` in `mcp.Config` ([log](logs/red-compile.log)) |
| [`mutant_watcher_never_cancels.py`](probes/mutant_watcher_never_cancels.py), test with `deadline_ms` 1 | — | **passed** (5/5 steps succeeded; 6/6 tests passed) ([log](logs/red-mutant-no-cancel.log)) |
| same mutant, test output printed | — | one authority check, `E_DEADLINE` ([log](logs/mutant-diag.log)): the read engine's own `deadline_ms` timeout, which `execute` creates only after the authority check, expired first and stopped the read, so 1 ms could not tell which check stopped it |
| same mutant, final test with `deadline_ms` 500 | — | **FAIL** `expected 1, found 2` at the authority-count assertion ([log](logs/red-mutant-no-cancel-500ms.log)) |
| final test on the real code (pre-commit) | — | 6/6 ([log](logs/green2-mc004-debug.log)) |

## PASS records (`zcr-evidence/1`, all accepted by `zcr-dev-evidence verify`)

| Record | Binary | Result |
|---|---|---|
| [mc004-debug](records/mc004-debug.json) | `T08-test e2d3ee2e…` | 5/5 steps succeeded; 6/6 tests passed |
| [mc004-debug-stress](records/mc004-debug-stress.json) | `T08-test e2d3ee2e…` | idle pass=10 fail=0, 8 busy loops pass=30 fail=0, runner exit 0 ([logs](logs/stress.tar.gz)) |
| [mcp-debug](records/mcp-debug.json), [launch](records/mcp-debug-launch.json) | `T08-test 7a94ff02…`, `T08-launch-test 746a0c39…` | 8/8 steps succeeded; 29/29 tests passed |
| [mcp-releasesafe](records/mcp-releasesafe.json), [launch](records/mcp-releasesafe-launch.json) | `T08-test 3ab979a2…`, `T08-launch-test afb03ae5…` | 8/8 steps succeeded; 29/29 tests passed |

[records/runs.json](records/runs.json) binds each record to its log digest, `source_config_sha256` `0c3177d8…` ([source-config.json](records/source-config.json)), `corpus_sha256` `36a3160c…` ([corpus.json](records/corpus.json)) and the task manifest.

## Task identity

[task/manifest.json](task/manifest.json) (`zcr-task/1`, workspace `fs:16777232:649333702:16777232:649333700:16777232:647053195`, base `a15b127`, write paths `src/protocol/mcp.zig`, `tests/t08_test.zig`, `evidence/T08`) and [task/authorization.json](task/authorization.json) were issued **before any edit** in the recording worktree; [task/preflight.json](task/preflight.json) is the clean-worktree preflight. `zcr-dev-guard scope` reported 0 violations at the start ([task/scope-start.json](task/scope-start.json)) and at the code commit ([task/scope-code.json](task/scope-code.json)). Records, builds and stress ran in that same worktree.

To check a later head against the record commit: `git diff --stat 3621430 -- . ':!evidence/T08'` must be empty.

## Not verified

Linux and Intel Mac runtime (native CI on the PR), actual host integration, Windows.
