# T15: BR-005 reconnect over a real UDS broker

**Date:** 2026-09-14 · **Host:** Apple M2 8 CPU, macOS 26.6.2, Zig 0.16.0 · **Base:** `9c94517` · **Source:** `a029e06` (tree `24372c44…`)

## Question

docs/18 row 2 lists the write/reconnect lifecycle as open. BR-005 requires that a bridge reconnect after a broker crash never resends a write and only looks up receipts. Unit tests covered the `bridge.Reconnect` state machine, but no test drove a real UDS broker through a disconnect and restart.

## Test (`a029e06`: `tests/t15_test.zig` only)

`BR-005 real UDS reconnect after disconnect and broker restart needs a host rebind at a new fence and replays nothing`. Over a real UDS broker:

1. A client reads `file.txt` and disconnects. The grant is then refused, because closing the session removed its host binding.
2. The broker stops and a new instance is created. The grant is still refused.
3. The host binds the session again at fence 2. A writer lease for the fence-1 task is refused with `FenceMismatch`.
4. The grant reconnects. The first response line answers the new request (`id` 9), not the earlier one (`id` 2).

## Result: existing behavior, no production change

The test passed against unchanged broker, bridge and registry code, so this is characterization rather than a RED for new code. Two mutants on copies of the tree show the test detects the behaviors it claims:

| Mutant | Change | Result |
|---|---|---|
| `keep_binding_on_close` | closeSession keeps the grant's registry binding | FAIL at line 775: `try expectRefused(f.connect(0));` ([log](logs/mutant-keep_binding_on_close.log)) |
| `ignore_fence` | task binding matches regardless of fence | FAIL at line 786: `try t.expectError(error.FenceMismatch, f.registry.acquireWriter(old_task, session.bound_workspace));` ([log](logs/mutant-ignore_fence.log)) |

| Run | Result |
|---|---|
| first probe, long state cache path | FAIL before any broker assertion: `auth.address` refused the 110-byte socket path (macOS limit 104) ([log](logs/probe1-br005-debug.log)) |
| second probe, short cache root | lifecycle assertions passed; an extra `completed == 2` counter assertion failed (found 0) because `initialize` and `ping` do not use the counted job path. The assertion was removed ([log](logs/probe2-br005-debug.log)) |
| BR-005 Debug after that change | 4/4 steps succeeded; 4/4 tests passed; 0 leaks ([log](logs/green-br005-debug.log)) |

## Records (`zcr-evidence/1`, verified after recording)

| Record | Run | Binary | Result |
|---|---|---|---|
| [quiet-broker-debug-t15](records/quiet-broker-debug-t15.json) | broker group Debug, started with no other zig process and load below the CPU count | `fb51c5c0…` | exit 0; 5/5 steps succeeded; 29/29 tests passed; 0 leaks ([log](logs/quiet-broker-debug.log)) |
| [quiet-broker-releasesafe-t15](records/quiet-broker-releasesafe-t15.json) | broker group ReleaseSafe, same run | `4f613930…` | exit 0; 5/5 steps succeeded; 29/29 tests passed; 0 leaks ([log](logs/quiet-broker-releasesafe.log)) |

[records/runs.json](records/runs.json) binds each record to its log digest, `source_config_sha256` `707f38cf…` ([source-config.json](records/source-config.json)) and `corpus_sha256` `6b842ed0…` ([corpus.json](records/corpus.json)). The Zig local cache used a short root, because test socket paths live under it. The runs started at `2026-09-14T05:56:16Z start 14:56  up 18:22, 1 user, load averages: 7.76 13.77 27.46` ([uptime](logs/record_runs.uptime)); other applications were not stopped.

## Task identity

[task/manifest.json](task/manifest.json) (`zcr-task/1`, workspace `fs:16777232:649540255:16777232:649540253:16777232:647053195`, base `9c94517`), [task/authorization.json](task/authorization.json) and [task/preflight.json](task/preflight.json) were issued before any edit. `zcr-dev-guard scope` reported 0 violations at the start ([task/scope-start.json](task/scope-start.json)) and on the code commit against the base ([task/scope-commit1.json](task/scope-commit1.json)).

## Limits

- Writes stay disabled (`"writes":false`), so no write is in flight during the disconnect. The no-resend and receipt-lookup rules for an uncertain write remain covered only by the `bridge.Reconnect` unit tests.
- The broker restart is simulated in one process with a shared registry, not a killed process. The host rebind is done by the test, not by a supervisor (there is no supervisor yet).
- Not verified: Linux and Intel Mac runtime (native CI on the PR), Windows, actual host launch integration.
