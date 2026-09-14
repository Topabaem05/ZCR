# T15: BR-005 reconnect over a real UDS broker

**Date:** 2026-09-14 · **Host:** Apple M2 8 CPU, macOS 26.6.2, Zig 0.16.0 · **Base:** `9c94517` · **Source:** `17a5cf3` (tree `04938245…`)

## Question

docs/18 row 2 lists the write/reconnect lifecycle as open. BR-005 requires that a bridge reconnect after a broker crash never resends a write and only looks up receipts. Unit tests covered the `bridge.Reconnect` state machine, but no test drove a real UDS broker through a disconnect and restart.

## Test (`17a5cf3`: `tests/t15_test.zig` only)

`BR-005 real UDS stale grant is refused and a broker restart needs a host rebind at a new fence and the bridge does not reconnect or resend`. Over a real UDS broker:

1. Grant 1's bridge client authenticates and stays open across the restart.
2. Grant 0 reads `file.txt` and disconnects. Closing the session ends its host binding, so the running, listening broker refuses the same grant at authentication: the connection fails with `OutOfScope` or `Disconnected`, and the server's `refused` counter rises by one. A missing listener (`IoFailure`) does not satisfy this check.
3. The broker stops, which closes every session and ends every host binding. `Server.create` for the same grants then fails with `OutOfScope`: a broker cannot even start for unbound grants.
4. The host binds both sessions again at fence 2. A writer lease for the fence-1 task is refused with `FenceMismatch`, and the broker starts.
5. Grant 1's old bridge client gets a request (`id` 7) that its stopped broker never answers. Its real `forward` path returns `Disconnected` and writes no response. The restarted broker records no authenticated session, no completed frame and no refusal, so the bridge neither reconnected nor resent.
6. Rebound grant 0 connects to the restarted broker and its `ping` (`id` 9) is answered.

Review on PR #8 found the first version weak in two places. Its post-restart refusal ran before any new broker listened, so a missing socket (`IoFailure`) passed the check, and its no-replay assertion used a fresh client with nothing to replay. A second version started the new broker before checking the stale grant; it failed because `Server.create` refuses unbound grants ([log](logs/green2-br005-debug.log)). The test above checks the refusal on the broker that is still listening and checks the restart through `Server.create`.

## Result: existing behavior, no production change

The test passed against unchanged broker, bridge and registry code, so this is characterization rather than a RED for new code. Two mutants on copies of the tree show the test detects the behaviors it claims:

| Mutant | Change | Result |
|---|---|---|
| `keep_binding_on_close` | closeSession keeps the grant's registry binding | FAIL at line 803: `try expectAuthRefused(f, 0);` ([log](logs/mutant-keep_binding_on_close.log)) |
| `ignore_fence` | task binding matches regardless of fence | FAIL at line 821: `try t.expectError(error.FenceMismatch, f.registry.acquireWriter(old_task, session.bound_workspace));` ([log](logs/mutant-ignore_fence.log)) |

| Run | Result |
|---|---|
| first probe, long state cache path | FAIL before any broker assertion: `auth.address` refused the 110-byte socket path (macOS limit 104) ([log](logs/probe1-br005-debug.log)) |
| second probe, short cache root | lifecycle assertions passed; an extra `completed == 2` counter assertion failed (found 0) because `initialize` and `ping` do not use the counted job path. The assertion was removed ([log](logs/probe2-br005-debug.log)) |
| BR-005 Debug after that change | 4/4 steps succeeded; 4/4 tests passed; 0 leaks ([log](logs/green-br005-debug.log)) |
| BR-005 Debug, second version (restart before the stale check) | 2/4 steps succeeded (1 failed); 3/4 tests passed (1 failed); 0 leaks: `Server.create` refused the unbound grants ([log](logs/green2-br005-debug.log)) |
| BR-005 Debug, third version | 2/4 steps succeeded (1 failed); 3/4 tests passed (1 failed); 0 leaks: the new refusal helper read the counter after connecting, when the server had already counted the refusal ([log](logs/green3-br005-debug.log)) |
| BR-005 Debug, fourth version | 4/4 steps succeeded; 4/4 tests passed; 0 leaks ([log](logs/green4-br005-debug.log)); native CI then crashed it in ReleaseSafe on macOS: a segmentation fault at a stack address in `Fixture.initWithIo`, reproduced locally ([log](logs/repro-br005-releasesafe.log)). The test called `Server.create` directly, and inlined into the test function its per-session literals (each `Session` embeds a 512 KiB control buffer) exhausted the stack |
| BR-005 ReleaseSafe, final test (broker creation checked through `Fixture.start`) | 4/4 steps succeeded; 4/4 tests passed; 0 leaks ([log](logs/green5-br005-ReleaseSafe.log)) |
| BR-005 Debug, final test | 4/4 steps succeeded; 4/4 tests passed; 0 leaks ([log](logs/green5-br005-Debug.log)); earlier versions' mutant runs are kept as `logs/mutant-*-v1.log` to `-v4.log` |

## Records (`zcr-evidence/1`, verified after recording)

| Record | Run | Binary | Result |
|---|---|---|---|
| [quiet-broker-debug-t15](records/quiet-broker-debug-t15.json) | broker group Debug, started with no other zig process and load below the CPU count | `a52a7f9b…` | exit 0; 5/5 steps succeeded; 29/29 tests passed; 0 leaks ([log](logs/quiet-broker-debug.log)) |
| [quiet-broker-releasesafe-t15](records/quiet-broker-releasesafe-t15.json) | broker group ReleaseSafe, same run | `090a772a…` | exit 0; 5/5 steps succeeded; 29/29 tests passed; 0 leaks ([log](logs/quiet-broker-releasesafe.log)) |

[records/runs.json](records/runs.json) binds each record to its log digest, `source_config_sha256` `4e025464…` ([source-config.json](records/source-config.json)) and `corpus_sha256` `bf70f254…` ([corpus.json](records/corpus.json)). The Zig local cache used a short root, because test socket paths live under it. The runs started at `2026-09-14T06:42:36Z start 15:42  up 19:09, 1 user, load averages: 2.79 23.98 42.21` ([uptime](logs/record_runs.uptime)); other applications were not stopped.

## Task identity

[task/manifest.json](task/manifest.json) (`zcr-task/1`, workspace `fs:16777232:649540255:16777232:649540253:16777232:647053195`, base `9c94517`), [task/authorization.json](task/authorization.json) and [task/preflight.json](task/preflight.json) were issued before any edit. `zcr-dev-guard scope` reported 0 violations at the start ([task/scope-start.json](task/scope-start.json)) and on the code commit against the base ([task/scope-commit1.json](task/scope-commit1.json)).

## Limits

- Writes stay disabled (`"writes":false`), so the unanswered request is a read. A truly uncertain write cannot be staged over UDS, and the no-resend and receipt-lookup rules for an uncertain write remain covered only by the `bridge.Reconnect` unit tests. `bridge.Reconnect` is not wired into `Client.forward`; the bridge has no reconnect path at all.
- The broker restart is simulated in one process with a shared registry, not a killed process. The host rebind is done by the test, not by a supervisor (there is no supervisor yet).
- Not verified: Linux and Intel Mac runtime (native CI on the PR), Windows, actual host launch integration.
