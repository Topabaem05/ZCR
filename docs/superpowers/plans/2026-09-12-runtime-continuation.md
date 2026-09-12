# ZCR Runtime Continuation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Audit every existing branch, repair verified defects, and implement and verify the remaining mandatory runtime tasks without weakening their release gates.

**Architecture:** Continue from task-t07 (531cfc378950e6ef6ac6f49cb4e2de3de56312cc), which contains integration and every earlier task branch. Preserve the frozen I01–I19 boundaries and use one integrator for build/core/contracts; implement each task in an isolated worktree and validate again after integration.

**Tech Stack:** Zig 0.16.0, Zig std.Io threaded baseline, public POSIX/Darwin APIs, Git. Python is restricted to development verification and packaging.

**Spec:** docs/01-Requirements-and-Traceability.md, docs/02-SDD.md, docs/06-Worktree-and-Task-Isolation.md, docs/08-API-and-MCP.md, docs/12-Performance-and-Test-Plan.md, docs/13-Implementation-Roadmap.md, docs/16-Evidence-and-Open-Gates.md, docs/17-Data-Model-and-Interfaces.md and tasks/T00.md–T25.md.

## Global Constraints

- Zig 0.16.0; protocol zcr/1; MCP 2025-11-25; text_v1 only until actual client evidence supports another profile.
- Raw frame 16 MiB, JSON depth 64, output default 256 KiB / maximum 2 MiB, batch 32 items, edit 8 MiB, global/session queues 64/16, broker sessions 16.
- Correctness → isolation → bounded resources → observability → speed. No skipped tests, fake PASS, or silently widened authority.
- Task worktrees, mutable compiler caches, TMPDIR and artifacts are independent and outside source. Build/core/schema/CI are integrator-owned.
- Every task records RED, implementation, GREEN Debug/ReleaseSafe, failure paths, source/binary/config/corpus digests and review. Old evidence remains historical evidence.
- Runtime never executes arbitrary shell/network/Git mutations. Production writes remain disabled until T12 crash/recovery gates pass.
- Missing Mac/Windows/hardware/client execution is NOT_RUN; cross-compilation is not runtime proof. Optional T18/T20 may remain unselected, but T19 is mandatory.
- Existing user authorization covers the full repository implementation and reversible worktrees/feature branches. No final shared-branch merge or release publication is implied.

## Branch audit (2026-09-12)

| Branch | Relationship to integration | Decision |
|---|---|---|
| main | 33 commits behind | Design baseline; retain history |
| task-t00 | 30 behind | Already integrated |
| task-t01 | 27 behind | Already integrated |
| task-t02 | 22 behind | Already integrated |
| task-t03 | 17 behind | Already integrated |
| task-t04 | 12 behind | Already integrated |
| task-t05 | 7 behind | Already integrated |
| task-t06 | 2 behind | Already integrated |
| integration | 4bcf01d | T00–T06; build already expects T07 |
| task-t07 | 4 ahead, 0 behind | Best continuation source, requires defect fixes |

## Task 0: Repair and revalidate the inherited baseline

**Files:** build.zig; src/batch/read.zig; src/protocol/projection.zig; tests/t07_test.zig; evidence/continuation/; documentation status pages.
**Interfaces:** Preserve I03/I06 and existing JSON schema; plannedCost must validate the same ReadSpec constraints as execution.

- [x] Record clean branch inventory, source baseline and pinned compiler installation.
- [x] Run inherited Debug suite: Linux reveals missing explicit libc linkage in POSIX T04/T05 fixtures; T07 runs 18 passing tests but reviewed edge cases are uncovered.
- [x] Link POSIX test roots with libc and rerun all existing tests; retain baseline failure log.
- [x] Add BA-001 regression: line range count=0 / u32 overflow returns InvalidArgument from plannedCost, never panics.
- [x] Add BA-001 regression: invalid UTF-8 or over-budget earlier line does not turn a valid later batch member into an error; compare each member against a standalone read.
- [x] Add BA-003 regression: projection output-budget errors update emitted coverage/status consistently.
- [x] Implement validated planning and safe merge/fallback behavior; run batch and full Debug/ReleaseSafe tests.
- [x] Review, commit and record remaining inherited gaps (including deadline plumbing) for their owning implementation task.

```sh
zig build test -Dtest-group=batch -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Doptimize=Debug --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build verify-contracts
```

## Execution order and gate policy

After baseline repair, T08, T09 and T10 have independent ownership and can proceed in isolated worktrees. T11 follows T10; T12 follows T11; T13 follows T10; T14 follows T13; T15 joins T08/T09/T10/T13; T16 follows T15. T17/T19 and T21–T25 follow their exact dependencies below. Final approval remains BLOCKED while any mandatory external gate lacks execution evidence; this never prevents completing locally testable implementation work.

Existing task documents already contain the authoritative detailed S01–S06 instructions, owned paths, interface signatures, Given/When/Then tests and completion gates. The entries below bind those specifications to this continuation, so they must be read alongside the named task document rather than replaced by generic implementation assumptions.

## Task 1: T08 — Direct stdio MCP adapter

**Spec:** `tasks/T08.md` (all task-specific instructions and test assertions apply).
**Files:** `src/protocol/mcp.zig`, `src/protocol/framing.zig`, `src/protocol/codec.zig`, `tests/t08_test.zig`, `evidence/T08/`.
**Dependencies:** T02, T07.
**Interfaces — consumes:** I18; contracts/tools.json; I03–I06.
**Interfaces — produces:** MCP initialize/tools/list/tools/call; text_v1 encoded result.
**Required assertions:** MC-001, MC-002, MC-003, MC-004 as specified in `tasks/T08.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=mcp -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=mcp -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 2: T09 — Bounded scheduler와 Darwin GCD

**Spec:** `tasks/T09.md` (all task-specific instructions and test assertions apply).
**Files:** `src/scheduler/queue.zig`, `src/scheduler/executor.zig`, `src/platform/darwin.zig`, `c/darwin_shim.h`, `c/darwin_shim.c`, `tests/t09_test.zig`, `evidence/T09/`.
**Dependencies:** T03, T01.
**Interfaces — consumes:** I07 JobEnvelope; I02 permits; T00 ABI probes.
**Interfaces — produces:** submit I07; QoS adapter and threaded fallback.
**Required assertions:** SC-001, SC-002, SC-003, SC-004 as specified in `tasks/T09.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=scheduler -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=scheduler -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 3: T10 — Workspace identity와 writer lease

**Spec:** `tasks/T10.md` (all task-specific instructions and test assertions apply).
**Files:** `src/workspace/registry.zig`, `src/workspace/identity.zig`, `src/workspace/lease.zig`, `tests/t10_test.zig`, `evidence/T10/`.
**Dependencies:** T02, T01.
**Interfaces — consumes:** I08/I09; Git discovery result; trusted root handles.
**Interfaces — produces:** registerWorkspace I08; acquireWriter I09; workspace generation.
**Required assertions:** IS-001, IS-002, IS-005, IS-008 as specified in `tasks/T10.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=isolation -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=isolation -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 4: T11 — 단일파일 atomic patch/create

**Spec:** `tasks/T11.md` (all task-specific instructions and test assertions apply).
**Files:** `src/fs/edit.zig`, `src/fs/publish.zig`, `tests/t11_test.zig`, `evidence/T11/`.
**Dependencies:** T04, T10.
**Interfaces — consumes:** I03 FileVersion; I09 WriterLease; I19 JournalStore interface.
**Interfaces — produces:** applyPatch I10; createFile I11; commit-point receipt.
**Required assertions:** WR-001, WR-002, WR-003, WR-004, WR-007, WR-009, WR-010, IS-007 as specified in `tasks/T11.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=write -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=write -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 5: T12 — Journal·crash recovery·idempotency

**Spec:** `tasks/T12.md` (all task-specific instructions and test assertions apply).
**Approved continuation design:** [Supervised recovery and historical receipts](../designs/2026-09-12-supervised-recovery.md); production supervisor, native platform and kernel-fault gates remain open.
**Files:** `src/storage/journal.zig`, `src/storage/recovery.zig`, `src/storage/receipts.zig`, `tests/t12_test.zig`, `evidence/T12/`.
**Dependencies:** T11.
**Interfaces — consumes:** I19 journal interface; I10/I11 commit point.
**Interfaces — produces:** recover I12; persistent receipts and ambiguous-state quarantine.
**Required assertions:** WR-005, WR-006, WR-008 as specified in `tasks/T12.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=write -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=write -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 6: T13 — Immutable content·line cache

**Spec:** `tasks/T13.md` (all task-specific instructions and test assertions apply).
**Files:** `src/cache/content.zig`, `src/cache/lines.zig`, `src/cache/association.zig`, `tests/t13_test.zig`, `evidence/T13/`.
**Dependencies:** T04, T10, T03.
**Interfaces — consumes:** I13; ContentHash/FileVersion; I02 budget.
**Interfaces — produces:** cacheGet I13; second-touch cache and shared accounting.
**Required assertions:** ME-004, IS-006 as specified in `tasks/T13.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=memory -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=memory -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 7: T14 — Watcher invalidation와 live fallback

**Spec:** `tasks/T14.md` (all task-specific instructions and test assertions apply).
**Files:** `src/watch/core.zig`, `src/watch/darwin.zig`, `src/watch/linux.zig`, `tests/t14_test.zig`, `evidence/T14/`.
**Dependencies:** T05, T10, T13.
**Interfaces — consumes:** I14; workspace generation; I04 traversal.
**Interfaces — produces:** invalidate I14; uncertain/dirty index state.
**Required assertions:** WA-001, WA-002, WA-003, WA-004, WA-005, WA-006 as specified in `tasks/T14.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=watch -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=watch -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 8: T15 — 명시적 broker와 다중세션 budget

**Spec:** `tasks/T15.md` (all task-specific instructions and test assertions apply).
**Files:** `src/broker/server.zig`, `src/broker/bridge.zig`, `src/broker/auth.zig`, `tests/t15_test.zig`, `evidence/T15/`.
**Dependencies:** T08, T09, T10, T13.
**Interfaces — consumes:** I18 framing; I07 scheduler; I08 registry; I13 cache.
**Interfaces — produces:** authenticated UDS broker; group resource accounting.
**Required assertions:** BR-001, BR-002, BR-003, BR-004, BR-005 as specified in `tasks/T15.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=broker -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=broker -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 9: T16 — Pressure·thermal·LLM 공존 governor

**Spec:** `tasks/T16.md` (all task-specific instructions and test assertions apply).
**Files:** `src/governor/controller.zig`, `src/governor/pressure.zig`, `c/darwin_power_shim.h`, `c/darwin_power_shim.m`, `tests/t16_test.zig`, `evidence/T16/`.
**Dependencies:** T09, T13, T15.
**Interfaces — consumes:** I15 ResourceSignals; I02 accounting; I07 permits.
**Interfaces — produces:** updatePolicy I15; hysteresis and model_coexist profile.
**Required assertions:** SC-005, SC-006, ME-005, ME-006 as specified in `tasks/T16.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=scheduler -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=scheduler -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 10: T17 — Linux x86-64 backend

**Spec:** `tasks/T17.md` (all task-specific instructions and test assertions apply).
**Files:** `src/platform/interface.zig`, `src/platform/linux.zig`, `src/platform/linux_pressure.zig`, `tests/t17_test.zig`, `evidence/T17/`.
**Dependencies:** T04, T05, T09, T12, T14.
**Interfaces — consumes:** I03/I04/I07/I10–I12; common platform types.
**Interfaces — produces:** Linux baseline implementation; cgroup-aware effective limits.
**Required assertions:** ME-008 as specified in `tasks/T17.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=memory -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=memory -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## T18: Optional scope decision

Windows 확장 — 선택 is not selected for this continuation. Advertise no support and record NOT_SELECTED; retain its specification in tasks/T18.md.

## Task 12: T19 — ARM64/x86 SIMD 선택 가속

**Spec:** `tasks/T19.md` (all task-specific instructions and test assertions apply).
**Files:** `src/search/dispatch.zig`, `src/search/simd_arm64.zig`, `src/search/simd_x86.zig`, `tests/t19_test.zig`, `evidence/T19/`.
**Dependencies:** T06, T17.
**Interfaces — consumes:** scalar oracle; I05 exact match semantics.
**Interfaces — produces:** ISA-dispatched scanner; fallback and feature probes.
**Required assertions:** PF-005 as specified in `tasks/T19.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=perf -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=perf -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## T20: Optional scope decision

Tree-sitter outline — 선택 is not selected for this continuation. Advertise no support and record NOT_SELECTED; retain its specification in tasks/T20.md.

## Task 14: T21 — 재현 가능한 전체 벤치마크 하네스

**Spec:** `tasks/T21.md` (all task-specific instructions and test assertions apply).
**Files:** `bench/runner.zig`, `bench/corpus.zig`, `bench/trace.zig`, `bench/report.zig`, `tests/t21_test.zig`, `evidence/T21/`.
**Dependencies:** T07, T09, T12, T13, T15, T16, T17.
**Interfaces — consumes:** T00 baseline; functional oracle; all runtime telemetry.
**Interfaces — produces:** paired trace evidence; p50/p95/CI/E2E comparison.
**Required assertions:** PF-002, PF-003, PF-004, PF-006, PF-007 as specified in `tasks/T21.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=perf -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=perf -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 15: T22 — Bounded telemetry와 health

**Spec:** `tasks/T22.md` (all task-specific instructions and test assertions apply).
**Files:** `src/observe/metrics.zig`, `src/observe/health.zig`, `src/observe/trace.zig`, `tests/t22_test.zig`, `evidence/T22/`.
**Dependencies:** T08, T10, T15, T16.
**Interfaces — consumes:** I17 HealthSnapshot; budget/scheduler counters.
**Interfaces — produces:** health I17; redacted traces and session status.
**Required assertions:** OB-001, OB-002, OB-003, OB-004 as specified in `tasks/T22.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=observe -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=observe -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 16: T23 — Codex/Claude 실제 라우팅 검증

**Spec:** `tasks/T23.md` (all task-specific instructions and test assertions apply).
**Files:** `src/host/routing.zig`, `integration/codex.md`, `integration/claude.md`, `integration/traces/README.md`, `tests/t23_test.zig`, `evidence/T23/`.
**Dependencies:** T08, T12, T21, T22.
**Interfaces — consumes:** MCP tools and policy; actual installed clients.
**Interfaces — produces:** host compatibility evidence; approved routing instructions.
**Required assertions:** MC-005, MC-006 as specified in `tasks/T23.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=mcp -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=mcp -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 17: T24 — 패키징과 실제 지원 행렬

**Spec:** `tasks/T24.md` (all task-specific instructions and test assertions apply).
**Files:** `release/package.zig`, `release/support-matrix.json`, `release/SBOM.json`, `release/README.md`, `tests/t24_test.zig`, `evidence/T24/`.
**Dependencies:** T17, T22, T23.
**Interfaces — consumes:** actual platform test evidence; dependency manifest.
**Interfaces — produces:** signed/verified release artifacts as configured; truthful support matrix.
**Required assertions:**  as specified in `tasks/T24.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=dev -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=dev -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Task 18: T25 — 최종 통합·격리·성능 release gate

**Spec:** `tasks/T25.md` (all task-specific instructions and test assertions apply).
**Files:** `release/acceptance.md`, `release/evidence-index.json`, `release/risks.md`, `tests/t25_test.zig`, `evidence/T25/`.
**Dependencies:** T24, T21, T19, T12.
**Interfaces — consumes:** all mandatory task evidence; requirements traceability.
**Interfaces — produces:** go/no-go decision; released capabilities and residual risks.
**Required assertions:** PF-008, DV-006 as specified in `tasks/T25.md` and tests/catalog.json.

- [ ] S01: bind clean task worktree, base/contract hashes, approved ownership and dependency evidence.
- [ ] S02: implement the specified executable assertions; record the intended missing-feature/behavior failure before implementation.
- [ ] S03: implement the task-owned modules against the exact frozen signatures; request shared changes from the integrator.
- [ ] S04: run the task tests, resource/fault/cancellation cases, and preserve logs and binary hashes.
- [ ] S05: run Debug and ReleaseSafe plus impacted regression and scope checks; obtain independent spec/quality review.
- [ ] S06: commit source/evidence/handoff, integrate and rerun; explicitly retain unavailable platform/client gates as NOT_RUN.

```sh
zig build test -Dtest-group=perf -Doptimize=Debug -Dinstall-tests=true --prefix "$ZCR_STATE/out-debug"
zig build test -Dtest-group=perf -Doptimize=ReleaseSafe -Dinstall-tests=true --prefix "$ZCR_STATE/out-safe"
zig build verify-contracts
```

## Final acceptance

- [ ] All mandatory requirements have implementation/test/evidence links; no PLANNED table is misrepresented as completion.
- [ ] Full Debug and ReleaseSafe suites and contracts pass on the final integrated source.
- [ ] MCP subprocess transcript validates real binary dispatch, malformed inputs, cancellation, backpressure and policy refusal.
- [ ] All enabled write capabilities have actual kill/restart recovery evidence; no unsupported platform capability is advertised.
- [ ] Final source has independent whole-branch review and fixed material findings.
- [ ] A feature branch and reviewable draft PR contain the plan, code, evidence and exact outstanding external gates.
- [ ] T25 release gate is COMPLETE only if all mandatory evidence exists, otherwise explicitly BLOCKED with reproducible next commands.


## 2026-09-12 구현 체크포인트

- 전체10개 원본 브랜치·고유 소스·설계 및 작업 문서 감사를 완료했다. 원본 main/integration은 변경하지 않았다.
- T11source09422d4는 독립 승인 후 통합했다. 작업 소스의 Debug/ReleaseSafe 각각41write tests, 통합7bd5be8 Debug41tests가 통과했다. 생산 쓰기는 T12 및 플랫폼 복구 게이트 전까지 비활성이다.
- T14source2ca8e31은 독립 승인 후 통합했다. 각Debug/ReleaseSafe/fault19tests, 통합988dde8 Debug19tests가 통과했다. Darwin 실제FSEvents 수명·이벤트 전달은 미검증으로 유지한다.
- [실제3플랫폼CI](../../../evidence/continuation/native-ci-34681109500/README.md)는 이전tree39978457에서 각모드221/222tests가 통과했고 T01계약시험 및 당시 미통합T11/T14/T15로 전체FAIL이다. T01은 승인된 nativeI19 네번째필드를 검사하도록7115d63에서 수정, 로컬Debug19/19가 통과했다. 이후소스의PASS로 이 증거를 재사용하지 않는다.
- T12 초기 검토의 두 결함을 수정한 source1f12553/evidence4759605가 독립 승인됐다. Debug/ReleaseSafe 각각65/65와40 writer SIGKILL 사례를 보존했고, ad577ab에 통합한 실제 소스에서도 Debug65/65가 통과했다. 생산 supervisor, Mac, 실제 kernel fault 및 power-loss 게이트는 남아 있다.
- 캐시·브로커·임시 출력 예산 지적과 후속 실제 취소 경로를 source95352af/evidenceec9e5ad에서 수정하고 독립 승인 후 dae7ddc까지 통합했다. 실제 CLI 압력 검사와 원본 요청 ID 취소 응답의 실행 증거를 보존했다.
- [후속 실제3플랫폼 CI](../../../evidence/continuation/native-ci-34692959158/README.md)는 공개9d6d8e55/tree1c7fbe50에서 Linux 각모드285/285, 두Mac 각모드232통과/12건너뜀을 기록했다. Mac T11컴파일 오류와 당시T12/T15미통합으로 전체FAIL이다. 총4164개 archive/source/binary 검증을 기록했다.
- T16 스케줄러·캐시 선행API source8bad59b/evidencef5de460은 독립 승인 후7b915f8에 통합했다. 작업 소스의 각모드 scheduler20통과/1플랫폼건너뜀, memory34통과를 확인했다. Governor 정책·신호·실행 경로 연결, T17/T19/T21–T25와 실제클라이언트·모델·최소OS 게이트가 남아 있다.

- Darwin T11은 독립 승인 후53b4686/c80508b에 통합했다. Linux41/41 각모드와 두Mac 대상 semantic compile을 기록했으며 실제Mac 실행은 후속 CI 대상이다. T12 Darwin 포트를 별도 작업 트리에서 진행한다.
- [통합108b906 실행](../../../evidence/continuation/integrated-108b906/README.md): 각Debug/ReleaseSafe338통과/9실패, 실패는 제한된 로컬 환경의 broker AF_UNIX 사례다. 각모드 build/contracts/codec10/실제CLI19는 통과했다. 전체 등록 시험은 FAIL로 보존하며 hosted CI에서 소켓·Mac 경로를 검증한다.
