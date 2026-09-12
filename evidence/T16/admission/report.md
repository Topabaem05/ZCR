# T16 native admission prerequisite — implemented, runtime gates open

Base: `dae7ddcb5c489ec79d36474be3f945ddfd378d48`. Functional RED: `7121f72`. Frozen source: `8bad59b79bc8df00d25a8d0db60f94bd9c1f4c05`; exact tree: `4fb9e150525f9001afd8c8f5eca7aa642945d77f`. Worktree: `/workspace/scratch/3f4ab65dfb82/ZCR-T16-admission`. Contract digest remains `bc75e601b8d3f6e5f5b1d52084f8cd9ca16ea81eda11c25e6c42494f5816bab6`.

Source changes are limited to `src/scheduler/executor.zig`, `src/scheduler/queue.zig`, `src/cache/content.zig`, `tests/t09_test.zig`, and `tests/t13_test.zig`. Packaging uses only `evidence/T16/admission`. No build/core/config/contracts/launch changes, subagents, push, merge, capability broadening, or production write enablement.

## Native behavior and integration API

`Executor.setAdmissionLimits(core.AdmissionLimits) error{InvalidArgument}!void` publishes CPU, I/O, bulk and speculative admission under the existing mutex. Initialization ceilings and Options remain unchanged. Zero/above-initialization CPU or I/O rejects without publication. Submission gates and queue insertion use the same mutex; rejected envelopes and reservations remain caller-owned. Memory/cache fields belong to the runtime owner.

Accepted grants are never cancelled, mutated, repriced or released early. Saturating remaining permits and explicit original-hard-cap queue allowances permit accepted oversized chunks to drain alone only from zero active CPU. Slot iteration retains the initialized capacity. A currently oversized grant prevents additional starts even when only its non-short grant exceeds target and short CPU capacity would otherwise remain. Existing protected handles, service turns and dependency promotion survive. Accepted bulk/maintenance/idle drain, while fresh disabled classes refuse with Busy. Fresh jobs above current resource caps refuse with ResourceExhausted.

`Executor.admissionSnapshot()` reports `cpu_target`, `non_short_cpu_target`, `io_target`, both admission flags, actual CPU/non-short/I/O use, `outstanding_legacy`, `outstanding_over_target`, and `target_effective`. The snapshot counts the bounded live set under lock on every read, including after successive tighten/restore/promote transitions, rather than retaining queue handles or counter watermarks. Active slots retain immutable grant metadata because completion frees its envelope before locking; snapshots never dereference that retired envelope. Effective means both aggregate resource use within target and no accepted entry still requiring a resource or disabled-class exception.

`Store.setTarget(u64) error{InvalidArgument}!void` publishes a persistent content target and reclaims outside the Store lock. The host must invoke it outside a global policy lock because the call performs reclamation. Optional `Options.max_content_bytes` supplies an immutable original content ceiling, copied separately at creation. With no explicit ceiling the target starts at u64 maximum, while the existing Budget remains the allocation authority. A target above an explicit original ceiling is invalid. Raising the target neither changes Budget limits nor restores retired entries.

Cache `Stats` adds `target_bytes`, `loading_bytes`, and `unreclaimable_excess` (pinned ready bytes plus loading claims, less target with saturation). Existing `content_bytes` remains ready content, distinct from fixed `control_bytes`. New content claims include sparse checkpoints and are counted under lock before Budget reservation/allocation. Exceeding the target bypasses caching. Failed loads relinquish claims; successful loads transfer claims to truthful ready charges. Existing loading grants and pins retain their bytes/reservations. Publish and unpin trigger renewed reclamation against the current target. Authority, generation, rooted full-file verification, shared verification Budget identity and borrowing behavior are preserved.

## Functional RED and covering execution

Both RED binaries actually ran at commit `7121f72`: scheduler failed `ExpectedProspectiveRefusal` because fresh bulk was accepted; cache failed `expected 0, found 23` because eviction allowed refill. These were behavioral failures, not missing-API compile failures. The RED-only feature-detection fallback was removed in the implementation commit.

| Frozen-source execution | Pass | Skip | Exit |
|---|---:|---:|---:|
| Scheduler Debug | 20 | 1 | 0 |
| Memory Debug (T03 Budget 16 + T13 cache 18) | 34 | 0 | 0 |
| Scheduler ReleaseSafe | 20 | 1 | 0 |
| Memory ReleaseSafe (T03 Budget 16 + T13 cache 18) | 34 | 0 | 0 |
| Separate native Darwin GCD gate, Debug | 0 | 1 | 0 |

The four covering runs provide **108 passed executions**, 2 platform skips, 54 distinct passing cases. The separate GCD gate is **NOT_RUN**, not PASS: this host is Linux. The build runs compile and install the same test artifacts whose digests are recorded. No unrelated groups were run.

Focused new scheduler evidence covers CPU3 active plus CPU3 queued under CPU6/non-short4, tightening to CPU1, unchanged original reservations through held callbacks, exactly-once completion, fresh CPU1 acceptance after effectiveness, restore/re-tighten/promote, non-short-only exclusive drain, protected oversized service turns under eight fitting short refills, accepted bulk/maintenance/idle retirement versus fresh refusal, invalid setters preserving state, and two latch-ordered submit/publication histories with caller credit predating publication. New synchronization uses condition-variable latches without sleeps. Prior scheduler concurrency/fairness/cancellation/failure cases are included in the covering run.

Focused cache evidence covers persistent zero-target refill prevention; pinned bytes remaining readable; a content allocation held after claim/Budget grant while target falls to zero; truthful loading/unreclaimable accounting; fresh insertion refusal both before and after held-load publication; publication reclaiming the finished entry while preserving pins; last unpin reclaiming the remaining content; invalid targets preserving state; restoration without Budget inflation or resurrected entries; and allocation failure returning the exact target claim and Budget reservation so a subsequent insertion succeeds. The shared verification Budget pointer/charges and content/control charges are asserted. Existing full cache authority, generation, pin, cancellation, allocation-failure and borrowed-credit tests all ran.

## Reproducible identity and artifacts

All exact commands, exits, per-binary and per-log SHA-256 values, source/config/corpus file manifests, RED artifacts, and covering totals are in `evidence/T16/admission/proof.json` and `/workspace/scratch/3f4ab65dfb82/state/T16-admission/proof.json`. Config digest is SHA-256 of sorted per-file SHA-256/path lines over config, contracts and both build files. Corpus digest uses the full T03/T09/T13 test sources that construct deterministic in-process and temporary Git/file fixtures; random temporary directory names are not corpus inputs.

- Zig 0.16.0 executable SHA-256: `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c`.
- Configuration SHA-256: `8ee64385152d70c10ea3c147a79aa6dac487d746049c248bfec96bd15e2d0686`.
- Covering corpus SHA-256: `778167fde0d813f5a7f56bef378a39ea4ac4870b2ac963a184f9bdb53e063625`.
- T09 Debug binary SHA-256: `2cfe63a555b0ab738584429530db04cbdfaac9a697151ff7f086d9f6918f0d19`.
- T09 ReleaseSafe binary SHA-256: `3f6853f87a24e1f6ea641e4111d1a0b58433f13d0e99fe203d5854611ca517e2`.
- T13 Debug binary SHA-256: `0c8a117925d7cf0b486e7ada594d72b762c19332cb36c5077ea658d621b355ea`.
- T13 ReleaseSafe binary SHA-256: `1fb714e9002b90544cda761238dd8a11cbec962c6cdad72f7472fe926ccc076d`.

Every command used task-isolated `state/T16-admission/cache`, `global-cache`, `tmp`, and `artifacts`. Source was frozen before covering runs. `git diff --check` passed before source commit. Packaging commits add evidence only and are not represented as new source execution proofs.

## Remaining gates and specification caveat

This implements only the approved prospective-admission prerequisite. It does **not** complete T16, pure governor policy/hysteresis, runtime signal collection, native Mac pressure/QoS behavior, or actual launch/protocol/Budget/cache/executor owner wiring. Native Darwin GCD execution and independent source/evidence review remain open. The integrator must rerun appropriate actual integration binaries after applying this source.

The accepted original-grant drain exception means a reduced CPU1 target is not immediately effective while CPU3 legacy work remains. Existing callbacks are cooperative; blocking kernel I/O or callbacks that ignore cancellation preclude a finite wall-clock convergence guarantee. Idle precedence remains unchanged, so external producers must quiesce (or drain must close admission) for a global lifetime barrier. No callback cancellation token was cast away from const, no nested executor or worker permit wait was introduced, and existing live Budget/Reservation/ReservedAllocator objects must continue to be used by later runtime integration.
