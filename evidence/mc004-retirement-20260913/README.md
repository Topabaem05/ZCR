# T08 MC-004 retirement test: load-sensitive failure

**Date:** 2026-09-13 · **Host:** Apple M2 8 GB, macOS 26.6.2 (25G83), Zig 0.16.0 · **Base:** `main` `f1c388a` · **Source:** `bd54afe`

Exact commands, exit codes, source/tree, contract digest and binary SHA-256 values are in [report.json](report.json). Each result applies only to its binary and this host.

## Symptom

`MC-004 retiring tool id is detached before gated arena teardown` failed in the macOS 15 Debug CI run of `88546e8` at `try testing.expect(entered and accepted_during_retirement)`. On this host, the `main` binary passed 15/15 idle and 12/15 with 8 busy loops (`evidence/mac-write-path-20260913/` on the `claude/mac-write-path` branch, PR #2).

## Cause (confirmed)

The test's second condition was wrong, not the transport.

1. A successful `tools/call` calls `validate_authority` twice: in `execute` before the tool runs (`src/protocol/mcp.zig:192`) and after it (`mcp.zig:155`).
2. The first call therefore leaves the counter at 2 before the retirement hook is entered.
3. The test then sent the reused id, waited "until the counter is at least 2" (already true, so no wait), and required the counter to be **exactly** 2.
4. The check passed only if the test thread read the counter before the server's reader and worker threads admitted and executed the second call. Under CPU load the server threads sometimes ran first, the counter was 4, and the test failed even though the server behaved correctly.
5. The same check also passed when the server wrongly rejected the reused id as a duplicate, because a rejected request is never validated and the counter stays at 2.

## Probes

Probes ran on rsync copies of the tree, never in the task worktree. Sources are in [probes/](probes/).

| Probe | Binary | Result |
|---|---|---|
| original test + [`instrument_diag.py`](probes/instrument_diag.py) (prints counter at read time, final counter, duplicate rejection, ok responses), 8 busy loops | `40df75b3…` | 16/20 pass. All 4 failures: `entered=true validated_at_read=4 validated_final=4 dup=false ok_count=2`. All 16 passes read 2. ([logs](logs/diag-original-test-loaded-20.tar.gz)) |
| [`mutant_detach_after_hook.py`](probes/mutant_detach_after_hook.py): hook runs before the slot's id is detached, so the reused id is a duplicate | `31ad7b6c…` | **original test passes 6/6** ([log](logs/build-mutant-origtest.log)) |
| same mutant + instrumentation | `ad26389f…` | passes; `validated_final=2 dup=true ok_count=1` ([log](logs/build-mutant-diag.log)) |

The failing runs show the server admitted and completed the reused id during retirement (`dup=false`, two ok responses). The mutant shows the original assertion cannot detect the defect its name describes.

## Fix (`bd54afe`, `tests/t08_test.zig` only)

- The authority hook counts only validations made while the first slot's teardown is held by the retirement hook (`entered` and not `allow`). The first call's two validations finish before its response is written and its slot released, so they are never counted.
- Both waits end on an event (`entered`; two gated validations). The bound is a 10 s hang guard that turns a hang into a failure; passing does not depend on it.
- After the server thread exits, the test reads every response and requires no JSON-RPC `error` and two successful `ok:true` responses for `reused-string-id`.
- Assertions: `entered`, exactly 2 gated validations, 2 accepted responses, no serve failure.

No product source changed. This replaces the 250 ms windows with events and a stronger assertion; it does not lengthen a time limit to pass (docs/18).

## Results

| Run | Binary | Result |
|---|---|---|
| new test on mutant (RED) | `ca536324…` | FAIL at the `error == null` check: the second response is `Duplicate active request id` ([build log](logs/red-mutant-newtest.log), direct run exit 1) |
| new test, MC-004 Debug | `d832bf76…` | 6/6 ([log](logs/green-mc004-debug.log)) |
| new test stress, [`mc004_stress.sh`](probes/mc004_stress.sh) loop | `d832bf76…` | idle 10/10, 8 busy loops **30/30** ([logs](logs/new-test-stress-idle10-loaded30.tar.gz)) |
| mcp group Debug | `T08-test 5d6ec026…` | 29/29, 0 leaks ([log](logs/mcp-Debug.log)) |
| mcp group ReleaseSafe | `T08-test 1581876c…` | 29/29, 0 leaks ([log](logs/mcp-ReleaseSafe.log)) |
| rebuild from clean `bd54afe` | same digests | MC-004 6/6, mcp Debug and ReleaseSafe 29/29; every digest matched ([logs](logs/)) |

The GREEN and group builds ran on the worktree with only `tests/t08_test.zig` modified before commit; the rebuild from the clean commit reproduced identical binaries. The stress loops ran as inline shell with the same structure as `mc004_stress.sh`.

## Not verified

- ReleaseSafe under CPU load; Linux and Intel Mac runtime (left to the PR's native CI); macOS 15 runners.
- The other MC-004 tests still use 250 ms wall-clock windows. They passed every run here, including under load, and are unchanged.
