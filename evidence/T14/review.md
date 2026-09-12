# T14 independent spec and quality review

Reviewed 2026-09-12. Source: `2ca8e314a7c06c611a2e7e315470dd21737ce0a0`, tree `17d5f6fd328c6282081fb4cbfe0afebfd983becb`; base `d83a8993640dfd90e1b478bab2ac378b947af378`. Evidence-only packaging commit: `fdc30a2d8e89b2fc637fb5025db40c21b3017a11`.

**Spec verdict: APPROVE for the delivered I14 invalidation, reconciliation, and checked-live fallback scope.** WA-001 through WA-006 are implemented with native Linux evidence. The documented native Darwin, Windows, and root-integration gates remain open; this approval does not close them.

**Quality verdict: APPROVE.** No blocking correctness, lifecycle, authority, resource-bound, or false-completeness finding was identified in the three watcher modules or their tests. The Linux backend received an additional independent read-only pass. No repository test suite was rerun.

## Source assessment

- `Runtime.start()` installs the root watch before scanning. Reconciliation refreshes recursive coverage, drains known events, scans live files, polls again, checks the event epoch, and validates authority before generation publication. A concurrent invalidation prevents publication through the locked epoch check.
- The fixed dirty queue owns path bytes. Callback ingestion performs bounded metadata work under the Index mutex, with no filesystem/cache operation under that lock. Queue saturation, malformed/dropped events, root changes, and cursor wrap promote the workspace to full uncertainty. Saturating epoch arithmetic cannot silently wrap into a valid publication token.
- Linux uses bounded recursive watch registration, verifies no-follow directory identity, retires stale watch descriptors, and treats reuse/churn conservatively. The 128-directory cap, 10,000-file traversal cap, incomplete coverage, continuing events, and maximum reconciliation passes leave `complete=false` and uncertain state; they are not bypassed to make tests pass.
- Checked-live enumeration and search candidates always invoke the existing live traverser, even if watcher hints still say `live`. Returned skip/truncation details remain those of the actual traversal. Scope and reason slices are copied out of the soon-to-be-destroyed traverser into Runtime-owned storage with a documented borrowing lifetime.
- Runtime construction and live work validate the registry session, workspace/task/policy labels, current root descriptor identity, and requested scope. Invalidations grant no authority. Registry/cache calls and source I/O occur outside the Index lock. Actor-side cache invalidation detaches mutable associations while immutable pins remain valid.
- Runtime control and native FD credit are reserved before allocation; temporary watch work and traversal reserve the caller's work budget. Every examined failure path releases owned grants and traverser resources. Teardown is explicitly exclusive: callers and callback borrowers must already have stopped/joined. The `Busy` guard is correctly documented as misuse detection rather than a concurrent destruction barrier.

## Darwin assessment and required integration constraints

The adapter uses a stable address and a single owning native thread, a private CFRunLoop mode, copied relative paths, a 512-event callback limit, and bounded collapse to root-change/overflow uncertainty. Resource ownership is explicit through stop/invalidate/release. Its source ordering and watch-before-scan design are consistent with Apple's [FSEvents lifecycle and reconciliation guidance](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).

`synchronized()` deliberately returns false because no bounded native delivery barrier is proven. Consequently, an empty run-loop pump cannot cause a clean-index publication. This is a legitimate conservative fallback, not a skipped assertion or a claim of native runtime support.

Integration must preserve these documented requirements:

1. Keep Registry, Authorizer, budgets, trusted exclude handles, cache, and Runtime storage alive through their last uses.
2. Serialize actor operations; on Darwin, keep start/refresh/poll/stop on the **same native thread**, not merely a serial queue that may migrate across threads.
3. Stop and join Runtime/Index borrowers before exclusive deinit; copy returned coverage slices before admitting another live walk or reconcile.
4. Use the caller's shared control/work budgets. Do not synthesize independent per-request caps.
5. Revalidate/rebind trusted external ignore handles through the existing host contract. A watcher cannot make a stale approved handle current.
6. Keep checked-live traversal authoritative and preserve uncertain/incomplete results. Kernel watcher memory and framework-internal allocations are not proved to equal the tracked Zig heap count.

## Independently verified evidence

Read and verified the 12 final records in `evidence/T14/runs.json`, their source commit/tree, every recorded source-file/log/binary/probe hash, and the behavioral RED log/binary. The verification covered **542 hash comparisons** with no mismatch. Detailed verification is saved in `state/reviews/t14-evidence-check.json`.

| Evidence | Observed result |
|---|---|
| Watch Debug | 19/19 pass, exit 0 |
| Watch ReleaseSafe | 19/19 pass, exit 0 |
| Watch fault-debug | 19/19 pass, exit 0 |
| Filesystem regression | 15/15 pass, exit 0 |
| Memory regression | 28/28 pass, exit 0 |
| Isolation regression | 57/57 pass, exit 0 |
| Contract verification | exit 0 |
| Darwin callback logic on Linux | 2/2 pass in each optimization mode |
| Darwin arm64/x86-64 objects | compile exit 0; no SDK-link/runtime claim |
| Production hooks-absent object | compile exit 0 |
| Behavioral RED `e1e20ab9c06c67a9a41ae3da845570f9df9b6b69` | three intended WA-001/003/005 assertion failures, 0/3 pass, exit 1 |

Primary native test executable identities:

| Mode | SHA-256 |
|---|---|
| Debug / fault-debug | `c444e9833d240788cec39c2f9ae7c38e1eb8629e5477273802786d15b4c9aa33` |
| ReleaseSafe | `10ed1027c60f6fbab630f49313361b23caa064d082031ec9785d9fe3bb2fd9b1` |

Source identities:

| File | SHA-256 |
|---|---|
| `src/watch/core.zig` | `106b77d82f1b963416638b740b217bd321c6c877d2728c63dbe1e94263dc8080` |
| `src/watch/linux.zig` | `6081678633239f54bb425896fa71f91015a6e0bd4ea17e06e6b1245671a1efa0` |
| `src/watch/darwin.zig` | `135c405a6743213052194962284044c0f5ec62704d7380c6c94b509a393d5a62` |
| `tests/t14_test.zig` | `f16d35d67d5ea45c92d3e1e612604360f8d1077117e9cfb8c1a59b89c96df6f8` |

Native macOS SDK linking, stream delivery/teardown, delivery-barrier behavior, and resource measurements remain **NOT_RUN**. Windows and actual host integration remain **NOT_RUN**. Root must test its actual integrated source/binary. Cross objects and Linux callback fixtures are not substitutes for those gates. No atomic snapshot, complete cached candidate oracle, or watcher performance claim is approved.
