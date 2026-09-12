# Independent T16 admission prerequisite review

Reviewed 2026-09-12. Reviewer: independent scoped SPEC + QUALITY review. No source edits, subagents, or duplicate test executions.

- Approved base: `dae7ddcb5c489ec79d36474be3f945ddfd378d48`.
- Reviewed frozen source: `8bad59b79bc8df00d25a8d0db60f94bd9c1f4c05`.
- Source tree: `4fb9e150525f9001afd8c8f5eca7aa642945d77f`.
- Functional RED: `7121f72580ced349fbc4f728d81afb931315f8b9`.
- Evidence-only HEAD: `f5de46093c0bdac5d475321f8d5f2f5e0df55c1a`.
- Contract digest: `bc75e601b8d3f6e5f5b1d52084f8cd9ca16ea81eda11c25e6c42494f5816bab6`.

Authority: `state/T16-admission-brief.md`, `state/T16-runtime-design.md`, task manifest and repository AGENTS.md. Read task T16, required repository design context, owned diff, scheduler execution/queue selection, cache load/pin/reclaim paths and necessary direct callees. Review does not extend into the remaining governor implementation.

## SPEC verdict: PASS for the approved native prerequisite

No blocking discrepancy found in the scoped source. This verdict does not mark T16 complete or close native/runtime integration gates.

The setter validates immutable CPU/I/O ceilings without changing Options and publishes all scheduler policy fields under the same mutex as submit acceptance and queue insertion. Refusal preserves caller envelope/reservation ownership. Accepted callbacks and queued promotions remain valid. Saturating remaining permits avoid underflow; original-hard-cap allowances exist only at zero active CPU; oversized active metadata prevents subsequent starts that would defeat exclusivity. Pump retains initialized slot capacity and queue protection/service turns. Disabled classes reject new submissions but do not permanently strand accepted jobs.

Snapshots scan the bounded live set rather than retaining handles or transition counters. Active grant metadata survives the interval after envelope destruction and before completion reacquires the mutex. Target effectiveness requires aggregate use within target and no remaining over-target/disabled-class exception. This supports successive tighten/restore transitions without stale handles or revoking live grants.

Cache target claims serialize with new content admission, include checkpoint bytes, and remain distinct from fixed control charges. Claims transfer to ready ownership on publication and unwind on failure. Reclaim selects/removes under Store locking, then frees/releases after unlocking. Publication and unpin trigger convergence; pins and existing loading grants survive tightening. Raising targets cannot exceed an explicit original content ceiling, inflate Budget, or resurrect an evicted association. Shared verification Budget and authority/generation/full-file hash paths remain intact. Store lifetime retains the existing requirement that its owner outlive all calls and stop callers before teardown.

No production write activation, capability broadening, nested executor, permit wait inside callbacks, cancellation-const cast, or live grant repricing was introduced. No arbitrary application callback is synchronously invoked by the locked pump; existing asynchronous adapter execution and worker callback lifetime are preserved.

## QUALITY verdict: PASS with two nonblocking notes

No correctness or ownership defect requiring source revision was identified. The following bounded improvements are optional and do not invalidate the reviewed execution evidence.

| Severity | File / line | Finding and bounded improvement |
|---|---|---|
| P3, nonblocking | `src/cache/content.zig:395` | `lines.count(bytes)` now scans the entire immutable input while holding the Store mutex; the prior calculation was outside it. An allowed 8 MiB input can unnecessarily delay target publication, pin operations and other cache calls. Compute `n`, `text_start` and `charge` before taking the final claim lock; keep availability validation and counter publication locked. No behavior change is needed. |
| P3, nonblocking | `tests/t09_test.zig:823` | The latch test deliberately completes submit before setter, or setter before submit starts. It proves both ordered histories and older-credit refusal, but cannot detect a future regression that checks policy before acquiring the acceptance mutex. If strengthening this regression later, add a narrowly scoped deterministic test seam that holds a submission at the admission boundary while publication competes, and assert the resulting ownership/order. Do not describe the existing test as an overlapping race test. Current source locking is correct by inspection and the implementation report accurately calls these two latch-ordered histories. |

## Evidence verdict: PASS for recorded Linux executions

Read `state/T16-admission/report.md` and `evidence/T16/admission/proof.json` after evidence completion notification. Independently verified, without test reruns:

- Frozen source/red commit trees, clean worktree, and evidence-only changes from reviewed source to evidence HEAD.
- Config manifest (18 files), corpus manifest (3 files), source manifest (48 files), RED corpus manifest (3 files), each file digest/size against its exact Git commit and each aggregate manifest digest. Unrelated source bytes were hashed for provenance only, not broadened into source review.
- All seven recorded RED/covering/native-gate run log digests/sizes and all referenced installed binary digests/sizes; source-tree/config/corpus associations in the run records.
- Zig executable digest/size and stated fixed Zig 0.16.0 toolchain identity.
- Contract digest and identical committed versus state proof/report/log copies.
- RED logs show actual behavioral failures: fresh bulk accepted and cache refill of 23 bytes after eviction. Covering logs explicitly show installed/run artifacts sharing the compiled test dependency.

| Recorded run | Passed | Skipped | Exit |
|---|---:|---:|---:|
| Scheduler Debug | 20 | 1 | 0 |
| Memory Debug, including shared Budget | 34 | 0 | 0 |
| Scheduler ReleaseSafe | 20 | 1 | 0 |
| Memory ReleaseSafe, including shared Budget | 34 | 0 | 0 |
| Separate native Darwin GCD gate on Linux | 0 | 1 | 0 |

The four covering runs yield 108 passing executions and two platform skips, with 54 distinct passing cases. Separate native GCD execution is **NOT_RUN**; successful Linux test-process exit with one skip is not native execution proof. Focused cases cover held CPU3 grants, exclusive legacy drainage, protection/fairness, old classes versus fresh refusal, invalid setters, publication ordering, persistent target refill prevention, held loading completion, pins, failure cleanup and exact Budget charge/release accounting. Prior relevant scheduler and cache tests remain included.

## Gates retained

Actual native macOS GCD execution remains open. The approved prospective ruling permits accepted legacy grants to exceed the lowered target exclusively; CPU1 is not effective until the snapshot says so. Cooperative callbacks and blocking kernel I/O provide no finite wall-clock convergence bound, and continuous foreground producers can defer idle work until producers quiesce or drain closes admission.

Governor policy/hysteresis, signal collection, host admission serialization, and actual launch/protocol/Budget/cache/executor wiring remain separate required T16 work. Integrator execution must use the resulting actual integration binary. This prerequisite review neither authorizes new ownership nor changes production capability/write policy.
