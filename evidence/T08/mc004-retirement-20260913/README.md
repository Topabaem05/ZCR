# T08 MC-004: load-sensitive retirement test and wall-clock waits

**Date:** 2026-09-13 · **Host:** Apple M2 8 GB, macOS 26.6.2 (25G83), Zig 0.16.0 · **Base:** `main` `f1c388a` · **Source:** `ae5e4a4` (tests `bd54afe`, `ae5e4a4`)

Exact commands, exit codes, source/tree, contract digest and binary SHA-256 values are in [report.json](report.json). `runs` and `test_binaries_sha256` come from builds of `ae5e4a4`; the evidence commit on top changes only `evidence/T08/`. Earlier `bd54afe` runs are kept under `historical_runs`. Each result applies only to its binary and this host.

The bundle lives under `evidence/T08/` as `tasks/T08.md` requires (PR #3 review).

## 1. Retirement test failed under load

### Symptom

`MC-004 retiring tool id is detached before gated arena teardown` failed in the macOS 15 Debug CI run of `88546e8` at `try testing.expect(entered and accepted_during_retirement)`. On this host, the `main` binary passed 15/15 idle and 12/15 with 8 busy loops (`evidence/mac-write-path-20260913/` on the `claude/mac-write-path` branch, PR #2).

### Cause (confirmed)

The test's second condition was wrong, not the transport.

1. A successful `tools/call` calls `validate_authority` twice: in `execute` before the tool runs (`src/protocol/mcp.zig:192`) and after it (`mcp.zig:155`).
2. The first call therefore leaves the counter at 2 before the retirement hook is entered.
3. The test then sent the reused id, waited "until the counter is at least 2" (already true, so no wait), and required the counter to be **exactly** 2.
4. The check passed only if the test thread read the counter before the server's reader and worker threads admitted and executed the second call. Under CPU load the server threads sometimes ran first, the counter was 4, and the test failed even though the server behaved correctly.
5. The same check also passed when the server wrongly rejected the reused id as a duplicate, because a rejected request is never validated and the counter stays at 2.

### Probes

Probes ran on copies of the tree, never in the task worktree. Sources are in [probes/](probes/).

| Probe | Binary | Result |
|---|---|---|
| original test + [`instrument_diag.py`](probes/instrument_diag.py) (prints counter at read time, final counter, duplicate rejection, ok responses), 8 busy loops | `40df75b3…` | 16/20 pass. All 4 failures: `entered=true validated_at_read=4 validated_final=4 dup=false ok_count=2`. All 16 passes read 2. ([logs](logs/diag-original-test-loaded-20.tar.gz)) |
| [`mutant_detach_after_hook.py`](probes/mutant_detach_after_hook.py): hook runs before the slot's id is detached, so the reused id is a duplicate | `31ad7b6c…` | **original test passes 6/6** ([log](logs/build-mutant-origtest.log)) |
| same mutant + instrumentation | `ad26389f…` | passes; `validated_final=2 dup=true ok_count=1` ([log](logs/build-mutant-diag.log)) |

### Fix (`bd54afe`)

- The authority hook counts only validations made while the first slot's teardown is held by the retirement hook (`entered` and not `allow`). The first call's two validations finish before its response is written and its slot released, so they are never counted.
- Both waits end on an event (`entered`; two gated validations), bounded only by the shared 10 s hang guard.
- After the server thread exits, the test reads every response and requires no JSON-RPC `error` and two successful `ok:true` responses for `reused-string-id`.

On the mutant the new test fails at the `error == null` check, because the second response is `Duplicate active request id` (`ca536324…`, [log](logs/red-mutant-newtest.log)).

## 2. Remaining wall-clock waits (`ae5e4a4`)

| Test | Before | After | Check |
|---|---|---|---|
| `MC-004 stdout failure stops even when peer keeps stdin open` | waited for `serve` to return inside a 250 ms window | waits for the same event with stdin still open, bounded by the 10 s hang guard | [`mutant_ignore_output_failure.py`](probes/mutant_ignore_output_failure.py) (reader ignores the failure flag): new test **fails** at `stopped_before_eof` (`21e70c1a…`, [log](logs/red-mutant-stdout.log)) |
| `MC-004 real partial pipe input cancellation and slow output drain without interleaving` | slept 30 ms and assumed the writer had blocked on the full output pipe | polls the pipe's write end until it stops reporting `POLLOUT` (pipe full, so the only writer is blocked in a kernel write) and asserts the stall happened before draining | [`control_no_pipe_stall.py`](probes/control_no_pipe_stall.py) (1 KiB response fits in the pipe): new test **fails** at `stalled` (`75cbb600…`, [log](logs/red-control-smallfile.log)); the former 30 ms test **passes** with no stall (`8ca01b67…`, [log](logs/control-smallfile-oldtest.log)) |

The fixed 5 ms authority delay in the partial pipe test only keeps requests in flight; it is not a window and is unchanged.

## 3. Open: deadline test does not verify its claim

`MC-004 deadline watcher interrupts before filesystem work and output failure drains` uses a 15 ms authority delay so the deadline watcher fires before the request's cancellation check. A mutant whose watcher marks the request expired but never cancels it still **passes** the test (`7579459e…`, [log](logs/mutant-deadline-origtest.log)): the read of `missing` runs, and the worker still replaces the result with `E_DEADLINE`. The test therefore does not show the interrupt happens before filesystem work.

An event-based check needs the test to see the watcher's cancellation, and no hook exposes it today. That means a change to `src/protocol/mcp.zig` (T08-owned), which this test-only change does not make. The test is unchanged.

## 4. Open: runtime-cache tests failed once under load (not MC-004)

In run 10 of the ReleaseSafe mcp binary under 8 busy loops, the last four runtime-cache tests failed in a row with `IoFailure` and no trace (ReleaseSafe):

- `BR-001 runtime cache four workspace queries share one allocation and drain pins`
- `BR-001 runtime cache hit preserves read version line output and truncation semantics`
- `BR-001 runtime cache Reader truncation equals the filesystem oracle and unpins before result use`
- `IS-006 runtime cache host configuration rejects foreign facades and independent budgets`

The other 9 runs passed all 27 tests. This PR does not change these tests. Their `CacheHarness` creates git repositories with `/usr/bin/git` and snapshots workspaces through `workspace.Registry`, whose git runs map errors to `IoFailure`. That matches the Rosetta-only `identity.zig` failures recorded in PR #2, but the cause is **not confirmed** here.

## Results on `ae5e4a4`

| Run | Binary | Result |
|---|---|---|
| MC-004 Debug | `83461adf…` | 6/6 ([log](logs/ae5-mc004-debug.log)); identical to the pre-commit build ([log](logs/green2-mc004-debug.log)) |
| stress, [`mc004_stress.sh`](probes/mc004_stress.sh) loop, Debug MC-004 | `83461adf…` | idle 10/10, 8 busy loops **30/30** ([logs](logs/stress-ae5.tar.gz)) |
| stress, ReleaseSafe mcp group binary, 8 busy loops | `T08-test bdf2473c…` | 9/10. All MC-004 tests passed in every run. Run 10 failed four runtime-cache tests, not MC-004 (see section 4) ([logs](logs/stress-ae5.tar.gz)) |
| mcp group Debug | `T08-test 9c792e73…` | 29/29, 0 leaks ([log](logs/ae5-mcp-Debug.log)) |
| mcp group ReleaseSafe | `T08-test bdf2473c…` | 29/29, 0 leaks ([log](logs/ae5-mcp-ReleaseSafe.log)) |

Earlier on `bd54afe` (retirement fix only): MC-004 Debug 6/6, stress idle 10/10 and loaded 30/30, mcp group Debug and ReleaseSafe 29/29 with matching rebuild digests ([logs](logs/)). The stress loops ran as inline shell with the same structure as `mc004_stress.sh`.

## Not verified

- Linux and Intel Mac runtime (left to the PR's native CI); macOS 15 runners.
- `POLLOUT` on a full pipe was observed on this host only; Linux behaviour is expected to match (a full pipe clears `POLLOUT`) but is checked only by CI.
