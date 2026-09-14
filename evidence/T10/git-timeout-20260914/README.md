# T10: git discovery timeout reported as retryable Busy

**Date:** 2026-09-14 · **Host:** Apple M2 8 CPU, macOS 26.6.2, Zig 0.16.0 · **Base:** `a15b127` · **Source:** `ad99dc3` (tree `4ae5a707…`)

## Problem

Runtime-cache tests (T08 BR-001, IS-006) failed now and then under local CPU load with `IoFailure`. The cause was hidden: `src/workspace/identity.zig` runs git through `std.process.run` with a 5000 ms timeout and reports every run error except OutOfMemory and StreamTooLong as `IoFailure`, which is non-retryable `E_IO`.

## Cause (confirmed)

- [probes/instrument_identity_run.py](probes/instrument_identity_run.py) printed the error name and elapsed time of each discovery git call in a copy of the tree. Nothing in the task worktree was instrumented.
- Under 8 busy loops, 30 of 30 runs passed, but individual git calls took up to 4422 ms ([logs](logs/diag-loaded8.tar.gz)).
- Under 16 busy loops on 8 CPUs, runs 1 and 9 failed with `run_error=Timeout` (`git worktree list` 6932 ms, `git rev-parse` 5767 ms) ([summary](logs/diag-loaded16.summary.txt), [logs](logs/diag-loaded16.tar.gz)).

## Change (`ad99dc3`: `identity.zig`, `registry.zig`, `tests/t10_test.zig`)

- **Error mapping:** `error.Timeout` from a discovery git call is now reported as `error.Busy`. Identity is not established, registration is still refused, and nothing is written. Spawn failures and non-zero exits stay `IoFailure`.
- **Budget:** `identity.DiscoverOptions.timeout_ms` (default 5000, 1 to 60000) and `discoverWith` are added. `discover` keeps its signature, so callers owned by other tasks do not change. `Registry.Options.git_timeout_ms` passes the budget through; the default stays 5000 ms, and no limit is raised to make tests pass.
- **Test:** `IS-008 discovery git timeout is retryable Busy while a failing git stays IoFailure`. A stand-in git that sleeps 30 s under a 200 ms budget returns `Busy` well within 10 s, a stand-in that exits 1 returns `IoFailure`, budgets 0 and 60001 are rejected, and the default is 5000.

## RED, mutant, GREEN

| Run | Result |
|---|---|
| IS-008 before the change | compile error: no `git_timeout_ms` in `Registry.Options` ([log](logs/red-compile.log)) |
| [mutant](probes/mutant_timeout_as_ioerror.py): Timeout maps to IoFailure again | FAIL `expected error.Busy, found error.IoFailure` ([log](logs/red-mutant-timeout-ioerror.log)) |
| IS-008 after the change | 3/3 ([log](logs/green-is008-debug.log)) |
| `zig build verify-contracts` | exit 0 ([log](logs/rec-contracts.log)) |

## Records (`zcr-evidence/1`, each accepted by `zcr-dev-evidence verify` at record time)

| Record | Run | Binary | Result |
|---|---|---|---|
| [is008-debug](records/is008-debug.json) | IS-008 Debug | `3845f73c…` | 4/4 steps succeeded; 3/3 tests passed; 0 leaks ([log](logs/rec-is008-debug.log)) |
| [quiet-isolation-debug-t10](records/quiet-isolation-debug-t10.json) | isolation group Debug, nothing else running | `45b84a4f…` | 8/8 steps succeeded; 60/60 tests passed; 0 leaks ([log](logs/quiet-isolation-debug.log)) |
| [quiet-isolation-releasesafe-t10](records/quiet-isolation-releasesafe-t10.json) | isolation group ReleaseSafe, nothing else running | `12bd83e2…` | 8/8 steps succeeded; 60/60 tests passed; 0 leaks ([log](logs/quiet-isolation-releasesafe.log)) |
| [quiet-write-debug-t12](records/quiet-write-debug-t12.json) | write group Debug (T12 binary), nothing else running | `c02ea78a…` | 11/11 steps succeeded; 68/68 tests passed; 0 leaks ([log](logs/quiet-write-debug.log)) |
| [quiet-write-debug-t11](records/quiet-write-debug-t11.json) | write group Debug (T11 binary), same run | `aad37404…` | 11/11 steps succeeded; 68/68 tests passed; 0 leaks ([log](logs/quiet-write-debug.log)) |
| [mcp-debug-t08](records/mcp-debug-t08.json) | mcp group Debug | `3f77ac35…` | 8/8 steps succeeded; 29/29 tests passed; 0 leaks ([log](logs/rec-mcp-debug.log)) |
| [isolation-debug-t10](records/isolation-debug-t10.json) | isolation group Debug, concurrent with other builds | `45b84a4f…` | 6/8 steps succeeded (1 failed); 59/60 tests passed (1 failed); 0 leaks ([log](logs/rec-isolation-debug.log)) |
| [isolation-releasesafe-t10](records/isolation-releasesafe-t10.json) | isolation group ReleaseSafe, concurrent with reruns | `12bd83e2…` | 6/8 steps succeeded (1 failed); 57/60 tests passed (3 failed); 0 leaks ([log](logs/rec-isolation-releasesafe.log)) |
| [write-debug-t12](records/write-debug-t12.json) | write group Debug, concurrent with reruns | `c02ea78a…` | 9/11 steps succeeded (1 failed); 67/68 tests passed (1 failed); 3 leaks ([log](logs/rec-write-debug.log)) |

[records/runs.json](records/runs.json) binds each record to its log digest, `source_config_sha256` `b18dcf02…` ([source-config.json](records/source-config.json)) and `corpus_sha256` `c942758a…` ([corpus.json](records/corpus.json)). Exit codes are recorded as observed.

## Failures under contention also occur on unmodified main

- **Concurrent group runs:** the isolation and write runs that shared the CPU with other builds and reruns failed 1, 3 and 1 tests. Every failure went through the same path: a discovery git read timeout (`std.process.run` `fill` in `process.zig`, then `identity.output`, then `registerWorkspace`). The failing test changed from run to run.
- **Controlled comparison:** [probes/compare_t10_binaries.sh](probes/compare_t10_binaries.sh) ran the fix's T10 test binary and one built from unmodified main `96c2666` alternately ([summary](logs/compare.summary.txt), [logs](logs/compare.tar.gz)). Main's isolation Debug group passed 59/59 on its own ([log](logs/baseline-isolation-debug.log)).

| Condition | fix `ad99dc3` | main `96c2666` |
|---|---|---|
| idle, 3 runs | 3 pass / 0 fail | 3 pass / 0 fail |
| 8 busy loops, 3 runs | 2 pass / 1 fail | 1 pass / 2 fail |

Every loaded failure on both binaries took the same discovery-timeout path. The change reports these timeouts as `Busy` and does not make them more frequent.

## Task identity

[task/manifest.json](task/manifest.json) (`zcr-task/1`, workspace `fs:16777232:649346710:16777232:649346708:16777232:647053195`, base `a15b127`) and [task/authorization.json](task/authorization.json) were issued before any investigation or edit. Fence 2 added `src/workspace/registry.zig` before that file was edited; the fence-1 manifest is kept. [task/preflight.json](task/preflight.json) records the clean-worktree preflight, and `zcr-dev-guard scope` against the merge base reports 0 violations ([task/scope-code.json](task/scope-code.json)).

## Limits and findings

- Heavy CPU oversubscription can still make discovery exceed 5 s. Registration then returns retryable `Busy` instead of `IoFailure`. This is a documented limit, not a gate, and it is not load-tested in CI.
- T11's test fixture leaks allocations when registration fails (3 leaks in the concurrent write run). T11 owns that file, so it is left to a separate task.
- Not verified: Linux and Intel Mac runtime (native CI on the PR), actual host integration, Windows.
