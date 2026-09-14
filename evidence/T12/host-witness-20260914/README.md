# T12: host witness for continuity and publication

**Date:** 2026-09-14 · **Host:** Apple M2 8 CPU, macOS 26.6.2, Zig 0.16.0 · **Base:** `9c94517` · **Source:** `a17020a` (tree `cfd20d8c…`)

## Problem

docs/18 row 2 lists a trusted host that retains the root, state and per-publication handles and issues a one-use continuity grant. `recovery.ContinuityGrant` already had `validate` and `validate_publication` callbacks, but only test-local witnesses implemented them. No production type retained publication handles, so recovery could not re-check the live temp, target and parent that a journal record names.

## Change (`a17020a`: `src/storage/recovery.zig`, `tests/t12_test.zig`)

- **`recovery.HostWitness`:** `init(io, identity, state)` keeps the trusted workspace identity and state directory. `retainPublication(parent, record)` takes ownership of the parent handle, opens the temp and the original by observed identity (a create requires the target to be absent), and keeps at most 16 pending publications. `retirePublication(record)` closes and forgets the witness of a publication that reached a terminal state, so the limit bounds pending publications rather than lifetime writes; it is refused with `Busy` once recovery has started, and with `RecoveryRequired` for a publication that is not retained. `grant(data)` returns a `ContinuityGrant`.
- **`validate`** is one-use. It checks the state directory identity against the grant, re-validates the workspace identity, and matches the journal namespace.
- **`validate_publication`** is refused before `validate`. It matches the publication digest, then re-stats the retained handles: the temp name must be absent or still the retained temp, and the target must be absent, the retained original or the retained temp (the rename applied). Anything else returns `RecoveryRequired`.
- **Tests:** `WR-008 host witness grants once and refuses a replaced temp name after unlink`, `WR-008 host witness accepts an applied publication and refuses a foreign target` and `WR-008 host witness retires terminal publications so its limit bounds pending ones`. The third was added after review on PR #10 found that the witness had no way to release a finished publication.
- Production writes stay disabled. No caller outside tests constructs a `HostWitness` yet (see the T11 hook proposal below).

## RED, mutants, GREEN

| Run | Result |
|---|---|
| WR-008 before the change | compile error: no `HostWitness` in `recovery` ([log](logs/red-compile.log)) |
| WR-008 after the change | 8/8 steps succeeded; 14/14 tests passed; 0 leaks ([log](logs/green2-wr008-debug.log)) |
| retire test before `retirePublication` existed | compile error ([log](logs/red-retire-debug.log)) |
| WR-008 after `retirePublication`, Debug | 6/6 steps succeeded; 15/15 tests passed; 0 leaks ([log](logs/green-retire-Debug.log)) |
| WR-008 after `retirePublication`, ReleaseSafe | 6/6 steps succeeded; 15/15 tests passed; 0 leaks ([log](logs/green-retire-ReleaseSafe.log)) |
| `zig build verify-contracts` | see [log](logs/rec-contracts.log) |

Each [mutant](probes/mutants.py) was applied to a copy of the tree; the task worktree was never modified.

| Mutant | Change | Result |
|---|---|---|
| `no_temp_name_check` | accept any entry at the temp name | FAIL `WR-008 host witness grants once and refuses a replaced temp name after unlink` ([log](logs/mutant-no_temp_name_check-r2.log)) |
| `no_one_use` | drop the one-use guard on validate | FAIL `WR-008 host witness grants once and refuses a replaced temp name after unlink` ([log](logs/mutant-no_one_use-r2.log)) |
| `leaf_original_only` | accept only the original at the target, not the renamed temp | FAIL `WR-008 host witness accepts an applied publication and refuses a foreign target` ([log](logs/mutant-leaf_original_only-r2.log)) |
| `retire_keeps_slot` | retiring closes the handles but keeps the slot counted | FAIL `WR-008 host witness retires terminal publications so its limit bounds pending ones` ([log](logs/mutant-retire_keeps_slot-r2.log)) |
| `retire_during_recovery` | retiring is allowed after the continuity check | FAIL `WR-008 host witness retires terminal publications so its limit bounds pending ones` ([log](logs/mutant-retire_during_recovery-r2.log)) |

The first runs of two mutants shared the CPU with other builds. Each failed its intended test, but `no_one_use` also failed 3 older WR-008 tests ([log](logs/mutant-no_one_use.log)); `leaf_original_only` also failed 3 older WR-008 tests ([log](logs/mutant-leaf_original_only.log)). Those extra failures went through discovery git timeouts (`process.run` in `identity.discoverWith`), the load condition recorded in `evidence/T10/git-timeout-20260914`. The mutant results above are the reruns against the retire change.

## Records (`zcr-evidence/1`, verified after recording)

| Record | Run | Binary | Result |
|---|---|---|---|
| [quiet-write-debug-t12](records/quiet-write-debug-t12.json) | write group Debug, started with no other zig process and load below the CPU count | `f2221e2d…` | exit 0; 11/11 steps succeeded; 71/71 tests passed; 0 leaks ([log](logs/quiet-write-debug.log)) |
| [quiet-write-releasesafe-t12](records/quiet-write-releasesafe-t12.json) | write group ReleaseSafe, same session | `8997f219…` | exit 0; 11/11 steps succeeded; 71/71 tests passed; 0 leaks ([log](logs/quiet-write-releasesafe.log)) |

The runs started at `2026-09-14T07:05:54Z start 16:05  up 19:32, 1 user, load averages: 1.97 3.70 14.59` ([uptime](logs/record_runs.uptime)); other applications were not stopped.

### Earlier source commit (superseded)

Records of the source before `retirePublication`, kept with their logs:

| Record | Source | Result |
|---|---|---|
| [loaded-write-debug-t12](history-0a8627d/records/loaded-write-debug-t12.json) | `0a8627d` | exit 1; 8/11 steps succeeded (2 failed); 64/70 tests passed (6 failed); 12 leaks ([log](history-0a8627d/logs/loaded-write-debug.log)) |
| [quiet-write-debug-t12](history-0a8627d/records/quiet-write-debug-t12.json) | `0a8627d` | exit 1; 8/11 steps succeeded (2 failed); 68/70 tests passed (2 failed); 3 leaks ([log](history-0a8627d/logs/quiet-write-debug.log)) |
| [quiet-write-releasesafe-t12](history-0a8627d/records/quiet-write-releasesafe-t12.json) | `0a8627d` | exit 0; 11/11 steps succeeded; 70/70 tests passed; 0 leaks ([log](history-0a8627d/logs/quiet-write-releasesafe.log)) |
| [quiet2-write-debug-t12](history-0a8627d/records/quiet2-write-debug-t12.json) | `0a8627d` | exit 1; 8/11 steps succeeded (2 failed); 68/70 tests passed (2 failed); 4 leaks ([log](history-0a8627d/logs/quiet2-write-debug.log)) |
| [quiet3-write-debug-t12](history-0a8627d/records/quiet3-write-debug-t12.json) | `0a8627d` | exit 0; 11/11 steps succeeded; 70/70 tests passed; 0 leaks ([log](history-0a8627d/logs/quiet3-write-debug.log)) |

At that source, three Debug runs failed on the load signature seen in `evidence/T10/git-timeout-20260914`: T11 tests (which do not build the changed storage code) through git discovery timeouts, and T12 WR-005, whose recovery child closed its pipe before sending its hello. Before its hello the child runs fixture setup, which registers the workspace through git discovery with a 5000 ms budget. The child's stderr goes to a file in the test's temporary directory, which is deleted, so a copy of the tree kept each child's stderr outside it ([patch](logs/diag-wr005.patch), [script](probes/rerun_write_debug.sh)) and ran WR-005 Debug three times at load 6.8, 4.4 and 3.4: 3/3 passed ([1](logs/diag-wr005-run-1.log), [2](logs/diag-wr005-run-2.log), [3](logs/diag-wr005-run-3.log)). A fourth Debug run at that source, started at load 4.65, then passed 70/70. The failures stay recorded as observed; attributing WR-005's failures to discovery timeouts under load is an inference, because no failing child's stderr was captured.

[records/runs.json](records/runs.json) binds each record to its log digest, `source_config_sha256` `821abc5c…` ([source-config.json](records/source-config.json)) and `corpus_sha256` `d372d929…` ([corpus.json](records/corpus.json)).

## Proposed interface change for T11 (not implemented)

[task/t11-hook-proposal.json](task/t11-hook-proposal.json). `Editor.finishPublish` never hands out the parent, temp and original handles between PREPARED and the rename, so no host code can call `retainPublication` for a real publication. The proposal adds an optional pre-publish hook in `Editor.Options` that runs after `journal.prepare` stores the record and before `acquireCommit`. The repository owner chose to record the proposal only.

## Task identity

[task/manifest.json](task/manifest.json) (`zcr-task/1`, workspace `fs:16777232:649526621:16777232:649526619:16777232:647053195`, base `9c94517`), [task/authorization.json](task/authorization.json) and [task/preflight.json](task/preflight.json) were issued before any edit. `zcr-dev-guard scope` reported 0 violations at the start ([task/scope-start.json](task/scope-start.json)) and on the code commit against the base ([task/scope-commit1.json](task/scope-commit1.json)).

## Limits

- No production caller: the launcher and T11 editor do not construct a `HostWitness`; cold start stays quarantined.
- The witness holds at most 16 pending publications; the host must retire each one that reaches a terminal state.
- Not verified: Linux and Intel Mac runtime (native CI on the PR), Windows, actual host launch integration.
