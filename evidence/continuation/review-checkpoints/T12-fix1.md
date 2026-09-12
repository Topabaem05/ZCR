# T12 fix round 1 — independent scoped re-review

**SPEC verdict: PASS for the scoped F1/F2 fixes under the amended root ruling.**

**QUALITY verdict: APPROVE the fix source. No new Important or Critical breakage was found in the fix diff.**

| Original finding | Verdict |
|---|---|
| F1: subsequent writes invalidate historical terminal receipts | ADDRESSED |
| F2: terminal torn suffix produces successful report but blocked lookup | ADDRESSED |

This review closes the two source-review findings. It does not grant final task/branch completion, integrator approval, host/platform support, or production write enablement.

## Scope and exact identities

Reviewed the original findings, root's terminal-history/torn-suffix amendment in `state/T12-design.md`, `state/T12/review-fix-brief.md`, the appended fix section of `state/T12/report.md`, and the source/evidence diff package `state/T12/fix-round1/review-5e081ee-4759605.txt`. Review was confined to those fixes and potential new Important breakage in their diff. Untouched original scope was not reopened.

- Fix base: `5e081eef70a8dbf3bcf6fdd0c49aa9e4a4e9c357`.
- Committed regression source: `e29ddc2c52b3d9bf32ea57e6a9edf252a7c82b30`.
- Implementation commit: `c2c24c76d8289b8769fd4e1cb5c13a10ea197b25`.
- Final tested source: `1f1255328038300114cd2f23b6e077416f30b2b7`.
- Final source tree: `d72a361a8f98b422f91bb56ac07256455b2fb0a4`.
- Evidence HEAD: `475960557b751a2a238477bb08dd51f689e1823b`.
- Worktree: `/workspace/scratch/3f4ab65dfb82/ZCR-T12`; clean at review.

Only `src/storage/recovery.zig`, the three authorized T12 test files, and new `evidence/T12/fix-round1/` artifacts change. Build/core, journal framing/persistence implementation and earlier evidence remain unchanged. No source files were edited by this review. No covered suite was rerun.

## F1 — ADDRESSED

At `src/storage/recovery.zig:87`, complete COMMITTED/ABORTED entries now take a historical-outcome path before publication-witness callbacks or current target observation. The invalid current-target-equality branches were removed from `reconcile`. The historical path is reached only after the existing trusted grant, namespace/domain/policy, state-directory and fresh workspace continuity checks (`src/storage/recovery.zig:59`, `src/storage/recovery.zig:68`), and the historical task approval check (`src/storage/recovery.zig:82`).

This implements root's explicit ruling: an authenticated terminal receipt proves an earlier execution outcome, not perpetual ownership of the path's current inode/bytes. The fix infers no ordering from traversal, hashes or generations. It introduces no source mutation and grants no new write authority. Pending/unresolved entries continue through publication-witness validation at `src/storage/recovery.zig:99` and existing current authorization/reconciliation.

The regression at `tests/t12_test.zig:941` performs actual T11/persistent-store commit→commit, abort→commit, and commit→identical-content replacement. `RetainPublication` acquires each descriptor set after PREPARED and before publication (`tests/t12_test.zig:916`). Both sets are retained through two fresh exec'd recovery children (`tests/t12_test.zig:925`). The test compares both original receipts, UUIDs, counts and sequences, then target metadata, exact bytes and sentinel. The new child response performs real I19 lookups and conflicting-digest checks (`tests/t12_child.zig:84`).

All nine archived final-source history fixtures — three variants in covering Debug and in each full build mode — match their recorded original and twice-recovered receipts. Their two recovery boot nonces and runtime identities differ. Retained target bytes and sentinel hashes independently match the expected corpus. The same-content variant correctly tests replacement identity without relying on a changed hash.

These histories execute the writer through the parent test fixture and use fresh recovery subprocesses; they are not represented as additional killed-writer cases.

## F2 — ADDRESSED

The historical terminal path calls `preserveTail` before counting a replayable terminal result (`src/storage/recovery.zig:88`). It reuses the existing exact-suffix forensic preservation, file/directory sync and active-prefix normalization. A preservation failure adds report uncertainty and a quarantined path, then continues without terminal-success accounting or rewriting the historical outcome (`src/storage/recovery.zig:92`). The existing report-level quarantine remains at `src/storage/recovery.zig:135`; I19 lookup remains blocked by the torn entry.

Only COMMITTED/ABORTED enters this path. A complete UNCERTAIN frame is not normalized into success. Complete corruption still fails through unchanged loading/decoding. The source no longer returns terminal success with `entry.torn` unresolved.

The test at `tests/t12_test.zig:989` covers actual committed and aborted T11 outcomes followed by deterministic interruption of an UNCERTAIN append. Two fresh recovery children must replay the original receipt/sequence, agree with lookup, retain the exact forensic suffix and exact valid active prefix, and leave target/sentinel unchanged. All six archived normalized-tail fixtures match those assertions and their indexed hashes. Independently decoded active logs have complete checksummed terminal frames; the preserved suffixes are shorter than their declared final-frame lengths.

The separate test at `tests/t12_test.zig:1028` covers both terminal kinds with conflicting forensic evidence that prevents preservation and with a complete UNCERTAIN append. It asserts one uncertain/quarantined path, zero terminal-success counts, blocked lookup, unchanged journal bytes and rejected writer admission. These are deterministic fault/negative tests; the original actual killed-recovery regression remains separately included in the full groups.

## New-diff quality assessment

No new Important/Critical finding. The implementation change is small and confined to recovery dispatch. Historical and pending semantics are visibly separated; the failure branch preserves the proven terminal fact while refusing to call it replayable. Existing error propagation/quarantine still applies if report allocation fails. The final helper adjustment uses `size + 1` for an EOF probe while retaining full-byte equality at `tests/t12_test.zig:980`; it does not weaken the target assertion. The fixture's reusable lease remains subject to the actual Editor/Registry validation and changes no production behavior.

`src/fs/edit.zig:9` remains `production_writes_enabled = false`; no fix changes that file or enables production writes.

## Evidence checks performed

Evidence directory: `/workspace/scratch/3f4ab65dfb82/ZCR-T12/evidence/T12/fix-round1`.

| Check | Independently verified result |
|---|---|
| New checksum manifest | All 18 listed artifacts match SHA-256 |
| Earlier evidence | All 21 original checksum entries still match |
| Raw archive | All 1,402 member lengths and hashes match `raw-files.json` |
| Source and configuration | Four changed-source hashes, build/core hashes and corpus/archive hashes match handoff |
| Run provenance | All nine run source/tree mappings, compiler hashes, installed binary hashes/sizes and stderr hashes match |
| Executed images | Logged parent images, where paths are emitted, match recorded parent digests; all 40 raw matrix child-image paths match final binaries |
| Required matrix | Exactly 40 distinct final-source mode × patch/create × C01–C10 rows; case/manifest hashes match |
| Matrix transcripts | Acknowledgments and first/second recovery results match raw documents; fresh identities/nonces and point-12 witness handshakes are present |
| Matrix receipt/target truth | UUID/digest, applied/durable flags, twice-recovered results and retained target/sentinel oracles agree |
| F1 history fixtures | Nine matching documents, transcript pairs and original/replayed receipt pairs |
| F2 normalized tails | Six matching transcript pairs, exact suffix hashes/lengths, valid terminal prefixes and target/sentinel oracles |
| Final groups | Debug and ReleaseSafe each report exit 0, 65/65 tests: T11 41 + T12 24 |
| Focused final-source selections | F1: 1/1; F2: 2/2, both exit 0 |

Exact principal digests:

- Corpus/config: `7a07adabcd109bbf86f65aeb0a4c8f4d1bd49a1c012990cb02cf18b6113b4ec6`.
- Raw archive: `1451d927a637012e6af19e3d35b09e48244173ac14e698229fe92e1a69f3247f`.
- Unchanged contract: `bc75e601b8d3f6e5f5b1d52084f8cd9ca16ea81eda11c25e6c42494f5816bab6`.
- Compiler: Zig 0.16.0, SHA-256 `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c`.

| Final run | Stderr SHA-256 | T12 child SHA-256 |
|---|---|---|
| verified-debug | `c1db7dede74ca0a9bef8e98630f49a3372185e1eef64ba03d7de6f79e2a2e010` | `d88e71b8fc9fea59eafeea63a08db41badf04ddad0bb72ba4a3b8bf44b835e57` |
| verified-releasesafe | `1c5d0581922debe35a90d80e69bd240c13f18516660ae981f62962e2cd813d07` | `551e16b569e27ec130627f549451a693228022dbaa6e821b2f625b301ed88335` |

`runs.json` retains exact argv/cwd/cache/TMP/output paths, binary digests and exit classifications for all attempts. The two RED child stderr files show functional RecoveryRequired failures at I19 lookup. The parent ProtocolClosed is downstream of those failures. Both REDs belong to the committed regression source before the implementation change. The three superseded fixed-source attempts are preserved as failures, not promoted to PASS; the final tested source fixes their exact-size read EOF helper issue. Recorded stdout digests are the empty-stream digest.

## Limitations and gates retained

This approval is limited to F1/F2 and new breakage in their fix diff. It does not reopen or waive untouched requirements.

- Combined startup/recovery/write verification on the actual integrator commit remains required.
- Actual host supervisor/protected one-use grant wiring with retained root/Git/common/state and required pending-publication witnesses remains required; cold start remains quarantined.
- Genuine kernel ENOSPC before and after publication remains NOT_RUN.
- Genuine kernel short-count write returns and fsync failures remain NOT_RUN; deterministic injected failures are not kernel-fault proof.
- macOS Apple Silicon, macOS Intel and Windows runtime remain NOT_RUN.
- Power-loss durability and filesystem/platform/metadata qualification remain NOT_RUN; SIGKILL proves process-crash behavior only.
- Historical receipt replay does not certify current workspace integrity or authorize new writes. The host must obtain current validation separately.
- The unchanged conservative effective capacity is at most 255 retained operations, with no eviction; no new 10,000-entry population proof is claimed.
- Production writes remain hard false. No test result here enables them.
