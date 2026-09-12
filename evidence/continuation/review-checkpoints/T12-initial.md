# T12 independent task-scoped review

Reviewed on 2026-09-12. Worktree: `/workspace/scratch/3f4ab65dfb82/ZCR-T12`.

**SPEC verdict: BLOCKED — two important source findings require resolution, including a root design ruling on terminal history.**

**QUALITY verdict: REQUEST CHANGES — the recorded single-operation crash evidence is sound, but recovery mishandles terminal history and can report terminal recovery success while the corresponding lookup remains unresolved.**

This is a T12 source/evidence review, not final whole-branch approval. Neither verdict enables production writes. No implementation files were changed, no full suite was rerun, and no source-traced finding below is represented as a newly executed reproduction.

## Review basis and scope

Requirements were read before the source diff: `state/T12-design.md`, including the approved publication/state-directory witness amendment, and `tasks/T12.md`; repository startup requirements and relevant I19/I12, recovery, retention and identity documentation were also inspected. The source diff package `state/T12/t12-review-988dde8-5e081ee.txt` was read once. Subsequent reads were bounded checks for exact source locations, T11 lifecycle/quarantine, retained registry identity, and evidence provenance.

Base: `988dde8ed35141a8fff2b813f0988a9f346582e2`.
Source: `8d241f687effb78c3416c3d733d18283a5956ffb`.
Source tree: `3f9c9b52c0ae250b276d49a2fd703527502c9d1f`.
Evidence: `5e081eef70a8dbf3bcf6fdd0c49aa9e4a4e9c357`.

The reviewed checkout is clean. Changed paths are the three storage files, three authorized T12 test files, and `evidence/T12/`. Root build/core and T11 source are unchanged from the approved base.

## Blocking findings

### F1 — Important: subsequent legitimate writes invalidate immutable historical receipts during recovery

Primary locations: `src/storage/recovery.zig:141` and `src/storage/recovery.zig:145`. Admission counterpart: `src/storage/journal.zig:428`. Outcome: `src/storage/recovery.zig:103`, `src/storage/recovery.zig:124`, and `src/storage/journal.zig:404`.

`Adapter.prepare` allows a new key on a path whose earlier entry is COMMITTED or ABORTED. Recovery nevertheless scans every retained entry and requires each COMMITTED entry's published temp identity/hash to equal the *current* target; every ABORTED entry must still see its old target identity/hash or ABSENT. These requirements cannot hold for normal successive edits of the same file.

Concrete source trace, with valid retained root/Git/common/state and publication witnesses for both operations:

1. K1 commits a patch from original A to temp/target B and stores its durable terminal receipt.
2. K2 is admitted on the same path because K1 is terminal; K2 commits B to C and stores another terminal receipt.
3. A supervised restart loads both chains. K2's target check can succeed. K1's `new_target` is false because the current target is C, not B.
4. Recovery appends UNCERTAIN to K1 and quarantines the workspace. Lookup of K1's identical key/digest now returns RecoveryRequired instead of its previously persisted receipt.

A stored ABORTED attempt followed by a valid commit has the same problem. Even an identical-content later replacement changes inode identity, so hash equality does not solve it. Retaining all descriptors prevents identity reuse but cannot make the current target simultaneously equal two historical publication objects. Directory iteration order does not resolve the conflict.

This is an observable idempotency/history and availability defect, not a claim that recovery overwrites source. `docs/08-API-and-MCP.md:86` requires retained same-key/same-digest receipt replay. The design's section 5 explicitly says to compare COMMITTED with the current target; applying that row to every retained operation conflicts with allowed subsequent keys. Therefore this also needs a **root design ruling**, not an owner silently ignoring the approved matrix.

Requested resolution: distinguish immutable historical terminal outcomes from current-path reconciliation. A proven historical receipt should remain replayable when a later authorized write supersedes its target. Current-path quarantine can be represented separately. Any supersession proof must use authenticated publication history/identities and must not infer order from directory iteration, hashes, or PREPARED generation plus one. Add focused sequential-commit and abort-then-commit restart cases, retaining both sets of witnesses and checking both original receipt UUIDs. Source approval remains blocked pending the root ruling and implementation/evidence.

### F2 — Important: a terminal prefix with a torn suffix is reported recovered without resolving the torn entry

Primary locations: `src/storage/recovery.zig:141` and `src/storage/recovery.zig:145`; deferred tail processing is at `src/storage/recovery.zig:149`. Report/lookup disagreement: `src/storage/recovery.zig:109`, `src/storage/recovery.zig:119`, `src/storage/journal.zig:404`.

The terminal COMMITTED/ABORTED branches return before checking `entry.torn`. The loader can legitimately produce a complete terminal prefix with a torn suffix: `uncertain()` is allowed to append UNCERTAIN to a terminal entry, and a recovery process can die partway through that append. On another recovery, with valid witnesses and matching target observations, `reconcile` returns immediately for the terminal prefix. The report counts the entry as committed/aborted, reports no uncertainty, and does not quarantine through the report's uncertainty path. The same entry still has `torn = true`, so I19 lookup returns RecoveryRequired.

The same contradiction is directly visible for any accepted terminal prefix plus a bounded incomplete final frame. A successful terminal report must not conceal an unresolved tail that prevents receipt replay. This is independent of F1 and does not require two successful writes.

Requested resolution: handle torn bytes before terminal-success returns, preserving forensic data with the required sync barriers, or explicitly report/quarantine the unresolved entry. The chosen policy must account for a partially appended UNCERTAIN transition. Add a focused terminal-prefix/torn-recovery-tail case asserting report/lookup agreement and repeat recovery behavior. The current killed-recovery test starts at PREPARED after C07, so it does not cover this terminal-prefix branch.

## Strengths and satisfied constraints

- Recovery contains no patch reapplication, temp-to-target publication, target rollback, invented request key, or source unlink. Optional cleanup is conservatively omitted.
- UNCERTAIN lookups return RecoveryRequired; they do not manufacture `applied=false`. PREPARED-only uncertainty has no false receipt. Known postpublication failures preserve applied truth through the T11 integration.
- The adapter binds a full domain/incarnation/task/key and expected digest. Receipt persistence checks the persisted UUID, old/new hashes, generation consistency, and durability monotonicity. There is no global last-request slot.
- Framing is bounded to 16 KiB, checksummed, chained and sequenced, with bounded parsing and validation of typed metadata before path use. Complete corruption is rejected rather than treated as absent.
- State files use descriptor-relative nofollow/nonblocking access, restrictive ownership/mode checks, single-link regular-file checks, exclusive creation and sync barriers. Recovery checks fresh identity discovery and trusted namespace continuity before reconciliation.
- The stronger fixture handshake is present: after PREPARED and before publication, point 12 causes the supervisor to acquire parent/temp/original descriptors, with ABSENT for create. The supervisor retains these and the private state directory across killed writer and fresh recovery processes. Root/Git/common witnesses and fresh boot/incarnation checks are also present. A production supervisor remains a separate gate.
- T11's callback is retained before lookup; prepare errors preserve uncertain temps; publication records APPLIED while holding the guard; postpublication persistence/durability errors invoke matching guard quarantine before release. No ordinary same-workspace registry call was introduced by I19 persistence while that guard is held. The queued filesystem publication test asserts rejection after quarantine.
- The hard `production_writes_enabled = false` gate in `src/fs/edit.zig:9` remains. Recovery never enables managed writes. Fresh Registry IDs/boot nonces and rejection of stale session/lease identities remain intact.

## Evidence verification

The following were independently recomputed/read from existing artifacts; none were regenerated by running the covered suites:

| Check | Result |
|---|---|
| Evidence checksums | All 21 entries in SHA256SUMS.json match |
| Owned source hashes | All six match handoff and reviewed source |
| Build/core/config/corpus/archive hashes | Match handoff |
| Contract digest | Recomputed `bc75e601b8d3f6e5f5b1d52084f8cd9ca16ea81eda11c25e6c42494f5816bab6` |
| Compiler image | SHA-256 matches recorded Zig 0.16.0 compiler |
| Installed binary images | T11-test, T12-test and T12-child match in both modes |
| Actually executed images | Parent paths in logs and child paths in raw case documents match recorded installed images |
| Raw archive | All 590 member sizes and SHA-256 values match raw-files.json |
| Required matrix | Exactly 40 distinct mode × patch/create × C01–C10 cases |
| Raw cases/manifests | All raw-case and canonical manifest hashes match |
| Pipe evidence | All 120 matrix transcripts decode; acknowledgments and both results match raw case JSON |
| Freshness | Recovery current WorkspaceIds/boot nonces differ from writer and from each other in all 40 cases |
| Publication witnesses | Point-12 prepublication handshake is present in all C05–C10 matrix cases |
| Receipt truth | Stored results have correct UUID/digest, applied and durable flags; first/second result objects agree |
| Target/sentinel oracles | All 40 retained targets/absence and sentinels independently match expected complete bytes/hash/length |
| Debug and ReleaseSafe logs | Each reports exit 0 and 62/62 tests: T11 41, T12 21 |
| Additional recovery kills | Both archived fixtures contain writer point 12 then 7, fresh recovery point 11, and two subsequent fresh successful recoveries |

The required writer kill assertion calls `std.posix.kill(pid, .KILL)` and compares `child.wait` against `.signal = .KILL` before producing a case document (`tests/t12_test.zig:144`, `tests/t12_test.zig:190`). This is actual observed process termination, not acknowledgment-only proof. Logs and case PIDs agree with the matrix. The extra recovery-kill PIDs are not separately persisted; their source assertion and raw point-11 transcript are present. This is a disclosed provenance limitation, not a reason to relabel the required 40-case matrix missing.

The initial committed functional RED is identifiable. Later dirty-source RED snapshots are unavailable and are correctly labeled supplemental history. The retained misleading Zig `failed command:` stderr line does not override successful process exits and explicit 62/62 summaries.

## Caps and retention assessment

`journal.zig:18` reserves 32 × 16 KiB = 512 KiB per admitted operation, covering journal frames plus bounded forensic suffixes. `journal.zig:190` reserves another frame allowance for the namespace, so the default 128 MiB limit admits at most 255 operations. The separate 10,000-entry ceiling is unreachable under that default credit policy.

The requirements make 10,000 an upper limit, not a promised minimum operating capacity; they permit refusal at another safe cap. Never evicting entries meets minimum 24-hour/workspace receipt retention and keeps borrowed key storage valid through Store.deinit, including clock rollback. Thus the conservative 255-operation policy is **not itself a source blocker under the stated bounds**. It is a substantial declared operational limitation: capacity never replenishes, and the source provides no retention reclamation. It must remain explicit before production approval. Low-cap/configuration refusals and borrowed lifetime were tested; a populated 10,000-entry test was not executed and must not be claimed. The tests alter old/future recorded clocks; they demonstrate non-eviction, not a functioning expiry algorithm.

## Individually open external/integration gates

1. Resolve F1/F2, review the changes and produce source-bound evidence for the affected cases.
2. Combined startup/recovery/write integration on the actual integrator source and binaries is not established by this isolated checkpoint.
3. Actual host launch supervisor wiring must retain root/Git/common/state and per-publication witnesses and supply protected one-use grants. The fixture supervisor proves its executed test lifecycle only; cold start remains quarantined.
4. Genuine kernel ENOSPC before and after publication: NOT_RUN.
5. Genuine kernel short-count write return: NOT_RUN. Seven-byte requested writes exercise looping, not a kernel short return.
6. Genuine kernel fsync failure: NOT_RUN. Injected fsync errors are separate deterministic evidence.
7. macOS Apple Silicon runtime: NOT_RUN.
8. macOS Intel runtime: NOT_RUN.
9. Windows runtime: NOT_RUN. The concrete store rejects non-Linux; no cross-compilation is runtime proof.
10. Power-loss durability and filesystem/platform qualification: NOT_RUN. SIGKILL establishes process-crash behavior only.
11. Other durability modes and ACL/xattr/filesystem combinations are not broadly qualified by the durable/plain-metadata Linux matrix.
12. Production capabilities and writes remain disabled. No fake store, manually constructed negative fixture, in-process exception, or existing process-crash result closes the above gates.

The single-operation crash matrix and artifact provenance are credible. They do not establish correct multi-operation retained history or terminal-prefix torn-tail recovery; those are the source-approval blockers identified here.
