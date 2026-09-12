# T07 continuation repair report

Status: DONE_WITH_CONCERNS; implementation and local tests complete, independent review/integration pending.

Base: `9897f27a18c66c310ae6dda3ee854f7fdcdcfa3d`. RED source: `4ff110105218ba3da8b7881f65d901a237083793`. GREEN source: `fa80da7edde09fff635ec79db21300323f7a10d5`.

Worktree: `/workspace/scratch/3f4ab65dfb82/ZCR-T07`. Branch: `codex/t07-corrections`. Contract digest: `8aa53314410fe471f0e070c522766684286f60e1ad4d9785c292bb709ea370a4`.

Changed source files: `src/batch/read.zig`, `src/protocol/projection.zig`, `tests/t07_test.zig`. New evidence is confined to `evidence/T07/continuation-2026-09-12/`; historical evidence is untouched.

## Repair and reasoning

`plannedCost` now calls the same request validator as execution before range arithmetic or store sizing. Zero/count overflow, invalid first/count bounds, item output bounds, and malformed IDs follow one validation path. The `u32` maximum starting line with a count of one remains valid.

Batch deduplication now requires the full read specification to match, including range, output limit, and deadline. Reading unequal ranges as one union lets invalid UTF-8 or an over-budget earlier line fail a later valid item. Even equal ranges with unequal output limits can fail the smaller item on bytes it would not return alone, so those remain independent too. Per-item authorization, shared output reservation, memory admission, worker bounds and cancellation drainage remain in place.

Projection adds only replaced successful batch items to emitted `coverage.skipped`. Existing item errors remain counted once; truncation, completeness, reason text and exact serialized byte accounting remain consistent.

## RED evidence

Seven targeted runs failed for the intended behavior before the implementation changed: zero-count and overflowing ranges aborted on integer overflow; planning accepted invalid bounds; later valid members received E_UNSUPPORTED or E_OUTPUT_BUDGET; unequal-cap same-range reads returned E_UNSUPPORTED for the smaller item; projection reported skipped=1 instead of 3. Full stdout/stderr, compiled binary hashes and exact source snapshots are recorded in test-runs.json and source-snapshots.json.

The regression source commit records the exact tested bytes, with no implementation change. The test execution happened before committing those bytes.

## Verification

| Run | Exit | Result |
| --- | ---: | --- |
| red-zero | 1 | Build Summary: 2/4 steps succeeded (1 failed); 0/1 tests passed (1 crashed) |
| red-overflow | 1 | Build Summary: 2/4 steps succeeded (1 failed); 0/1 tests passed (1 crashed) |
| red-validation | 1 | Build Summary: 2/4 steps succeeded (1 failed); 0/1 tests passed (1 failed) |
| red-utf8 | 1 | Build Summary: 2/4 steps succeeded (1 failed); 0/1 tests passed (1 failed) |
| red-long-line | 1 | Build Summary: 2/4 steps succeeded (1 failed); 0/1 tests passed (1 failed) |
| red-different-limits | 1 | Build Summary: 2/4 steps succeeded (1 failed); 0/1 tests passed (1 failed) |
| red-projection | 1 | Build Summary: 2/4 steps succeeded (1 failed); 0/1 tests passed (1 failed) |
| green-batch-debug | 0 | Build Summary: 4/4 steps succeeded; 24/24 tests passed |
| green-batch-safe | 0 | Build Summary: 4/4 steps succeeded; 24/24 tests passed |
| failure-batch-debug | 0 | Build Summary: 4/4 steps succeeded; 24/24 tests passed |
| regression-all-debug | 0 | Build Summary: 29/29 steps succeeded; 109/109 tests passed |
| regression-all-safe | 0 | Build Summary: 29/29 steps succeeded; 109/109 tests passed |
| verify-contracts | 0 | Build Summary: 3/3 steps succeeded |

Batch Debug/ReleaseSafe: 24/24 each. Full Debug/ReleaseSafe: 109/109 each. Explicit fault-enabled batch: 24/24. Frozen contracts: pass. The standard evidence tool verified both batch binaries against the clean GREEN source commit.

## Exact commands and exits

All build commands used task-local ZIG_GLOBAL_CACHE_DIR, ZIG_LOCAL_CACHE_DIR and TMPDIR recorded in source-snapshots.json. Build test fixtures and artifact prefixes are outside the source worktree.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug '-Dtest-id=zero line count' -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-red-zero --summary all` — exit 1; log `logs/red-zero.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug '-Dtest-id=overflowing line range' -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-red-overflow --summary all` — exit 1; log `logs/red-overflow.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug '-Dtest-id=validates request constraints' -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-red-validation --summary all` — exit 1; log `logs/red-validation.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug '-Dtest-id=adjacent invalid UTF-8' -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-red-utf8 --summary all` — exit 1; log `logs/red-utf8.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug '-Dtest-id=adjacent long line' -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-red-long-line --summary all` — exit 1; log `logs/red-long-line.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug '-Dtest-id=same range with different output' -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-red-different-limits --summary all` — exit 1; log `logs/red-different-limits.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug '-Dtest-id=budget replacements in coverage' -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-red-projection --summary all` — exit 1; log `logs/red-projection.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-green-batch-debug --summary all` — exit 0; log `logs/green-batch-debug.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-green-batch-safe --summary all` — exit 0; log `logs/green-batch-safe.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug -Dfault-injection=true -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-failure-batch-debug --summary all` — exit 0; log `logs/failure-batch-debug.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Doptimize=Debug -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-regression-all-debug --summary all` — exit 0; log `logs/regression-all-debug.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-regression-all-safe --summary all` — exit 0; log `logs/regression-all-safe.log`.

- `/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build verify-contracts --summary all` — exit 0; log `logs/verify-contracts.log`.

- `/workspace/scratch/3f4ab65dfb82/state/T07/zig-local-cache/o/71d264f4ddceef9514d28550df2f37ff/zcr-dev-evidence preflight --worktree /workspace/scratch/3f4ab65dfb82/ZCR-T07` — exit 0; log `logs/clean-source-preflight.log`.

- `/workspace/scratch/3f4ab65dfb82/state/T07/zig-local-cache/o/71d264f4ddceef9514d28550df2f37ff/zcr-dev-evidence record --worktree /workspace/scratch/3f4ab65dfb82/ZCR-T07 --task T07 --label green-batch-debug --command '/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=Debug -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-green-batch-debug --summary all' --exit 0 --binary /workspace/scratch/3f4ab65dfb82/state/T07/out-green-batch-debug/bin/T07-test --out /workspace/scratch/3f4ab65dfb82/state/T07/evidence-green-batch-debug.json` — exit 0; log `logs/record-green-batch-debug.log`.

- `/workspace/scratch/3f4ab65dfb82/state/T07/zig-local-cache/o/71d264f4ddceef9514d28550df2f37ff/zcr-dev-evidence verify --worktree /workspace/scratch/3f4ab65dfb82/ZCR-T07 --evidence /workspace/scratch/3f4ab65dfb82/state/T07/evidence-green-batch-debug.json` — exit 0; log `logs/verify-green-batch-debug.log`.

- `/workspace/scratch/3f4ab65dfb82/state/T07/zig-local-cache/o/71d264f4ddceef9514d28550df2f37ff/zcr-dev-evidence record --worktree /workspace/scratch/3f4ab65dfb82/ZCR-T07 --task T07 --label green-batch-safe --command '/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test -Dtest-group=batch -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix /workspace/scratch/3f4ab65dfb82/state/T07/out-green-batch-safe --summary all' --exit 0 --binary /workspace/scratch/3f4ab65dfb82/state/T07/out-green-batch-safe/bin/T07-test --out /workspace/scratch/3f4ab65dfb82/state/T07/evidence-green-batch-safe.json` — exit 0; log `logs/record-green-batch-safe.log`.

- `/workspace/scratch/3f4ab65dfb82/state/T07/zig-local-cache/o/71d264f4ddceef9514d28550df2f37ff/zcr-dev-evidence verify --worktree /workspace/scratch/3f4ab65dfb82/ZCR-T07 --evidence /workspace/scratch/3f4ab65dfb82/state/T07/evidence-green-batch-safe.json` — exit 0; log `logs/verify-green-batch-safe.log`.

Additional source gates: pinned Zig formatter and `git diff --check` exited 0 before the source commit. Source/config/corpus/manifest/toolchain and every installed test binary are SHA-256 fingerprinted. No shared build, core or contract files changed.

## Self-review and remaining gates

The changes retain request/result arena lifetimes and finish/drain paths; no new allocation, asynchronous owner or resource bypass was introduced. Exact duplicates still share copied immutable result data. The inherited report field `merged` stays available with value zero.

- Deadline plumbing remains inherited and deferred to the next cross-cutting task: ReadSpec.deadline_ms is carried but T04 does not enforce it, and I06 has no explicit cancellation/deadline parameter. This repair only prevents grouping unequal deadline values; no public API changed.
- Unequal ranges and output caps no longer coalesce, so some requests perform more reads. The existing 32-item fixture uses 28 jobs instead of 25, retains one exact duplicate, and stays within the same memory/output/concurrency caps.
- macOS, Windows, host-client integration and performance/energy measurements are NOT_RUN in this Linux session.
- The inherited openFdCount helper only enumerates macOS /dev/fd; Linux OS-level descriptor counts are NOT_RUN. Linux tests do verify cancellation/drain and zero tracked allocation lifetime.
- Independent spec/quality review and integration-binary validation belong to the integrator and remain pending at this handoff.

## Integration

Apply both source commits and the evidence packaging commit on the integrator branch, then review the scoped diff and run the integration build. Source assertions, emitted status and evidence make no claim that unavailable platforms or deadline enforcement were validated.
