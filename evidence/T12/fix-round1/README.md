# T12 review fix round 1

Reviewed base: `5e081eef70a8dbf3bcf6fdd0c49aa9e4a4e9c357`.
Regression RED commit: `e29ddc2c52b3d9bf32ea57e6a9edf252a7c82b30`.
Implementation: `c2c24c76d8289b8769fd4e1cb5c13a10ea197b25`.
Final tested source: `1f1255328038300114cd2f23b6e077416f30b2b7`, tree `d72a361a8f98b422f91bb56ac07256455b2fb0a4`.

Status: both findings fixed and source-specific tests passed; independent re-review and the previously declared external gates remain open. Production writes remain hard false. No push, merge, build/core modification, or historical evidence rewrite occurred.

## Changes

F1: After trusted namespace/state-directory continuity and historical task/domain/policy binding, COMMITTED and ABORTED entries replay their immutable outcomes before current-path inference. They do not claim the target still has their bytes or inode and do not authorize a new write. No ordering is inferred from iteration, content hashes, or generations. PREPARED/APPLIED and unresolved records keep their existing witness, identity, current authorization and reconciliation checks.

F2: Before reporting a terminal entry replayable, recovery preserves its bounded incomplete suffix through the existing forensic-file and directory sync barriers and normalizes the complete prefix. If preservation fails, the report adds uncertainty/quarantine and lookup stays blocked by the torn entry; recovery does not rewrite the proven terminal fact. Complete corrupt frames still fail decoding. Complete UNCERTAIN records remain unresolved.

The source change is confined to recovery.zig; three authorized test files add the required histories, fresh child recovery response, and boundary checks. Final source additionally fixes a test-helper EOF read-limit issue without weakening exact target equality.

## Results

| Command selection | Commit | Exit | Result |
|---|---|---:|---|
| Debug `-Dtest-id=F1` RED | e29ddc2 | 1 | 0/1; historical lookup becomes RecoveryRequired |
| Debug `-Dtest-id=F2` RED | e29ddc2 | 1 | 0/1; terminal report succeeds but lookup remains RecoveryRequired |
| Debug `-Dtest-id=F1` covering | 1f12553 | 0 | 1/1 |
| Debug `-Dtest-id=F2` covering | 1f12553 | 0 | 2/2 |
| Debug write group | 1f12553 | 0 | 65/65: T11 41 + T12 24 |
| ReleaseSafe write group | 1f12553 | 0 | 65/65: T11 41 + T12 24 |

F1 executes real T11/persistent-store commit→commit, abort→commit, and commit→identical-content replacement. The parent retains both publication witness sets and original UUIDs. Each variant then uses two fresh exec'd recovery children, replaying both original receipts, refusing conflicting digests, preserving journal sequences, and proving target metadata and full bytes unchanged. These variants run once in covering Debug and again in both complete configurations: nine archived history cases.

F2 executes real T11 terminal outcomes for both COMMITTED and ABORTED, then injects an interrupted UNCERTAIN append. Two fresh recoveries must agree with lookup, preserve exact forensic suffix bytes, retain the original UUID/sequence, and leave target/sentinel unchanged. Covering plus full configurations yield six normalized-tail fixtures. A second F2 test covers both terminal kinds with failed forensic preservation and with a complete UNCERTAIN frame, requiring report uncertainty, blocked lookup, unchanged journal bytes, and writer quarantine.

The complete Debug/ReleaseSafe groups retain all 40 matrix cases and the original killed-recovery, malformed frame, missing-witness, identity, EACCES, and queued-writer fault tests. The original supplementary kills remain two extra C07 writers plus two recovery processes. `cases.json` contains only the final-source 40-case matrix, not the additional runs at a superseded commit.

## Provenance and preservation

`runs.json` records exact argv, cwd, environment, source/tree, compiler version/SHA-256, installed binary hashes, exit status and stdout/stderr hashes for nine attempts. All stdout streams were empty. Exact stderr is retained under `logs/`. `raw-fixtures.tar.gz` contains 1,402 hashed members from RED, superseded, covering and final attempts; `raw-files.json` supplies member hashes/sizes. Fresh history and normalized terminal-tail results are indexed in `history-and-tails.json`. The current corpus/configuration and source hashes are in `corpus.json` and `handoff.json`.

The RED parents report ProtocolClosed because their recovery children fail the actual I19 lookup with RecoveryRequired. Their archived `child-1.stderr` pinpoints journal.zig lookup, so these are functional recovery regressions, not compile or process-setup failures. Both REDs ran on a clean committed test source before the source fix.

The superseded c2c24c7 covering/full attempts reached successful recovery but failed the new F1 final byte check at its exact-sized read limit (`StreamTooLong` during EOF detection). Final source permits the EOF probe with `size + 1` and still compares every expected byte. Those three failed attempts and binary images remain preserved; historical directory names such as `green-f1` or `final-debug` are not PASS claims. Only the final-source `covering-*` and `verified-*` records are GREEN.

Packaging independently recomputed all installed image hashes, checked executed parents when the protocol emitted their path, checked every final matrix's executed child hash, and verified all retained targets/sentinels against corpus oracles. The new history documents preserve both original and recovered receipts for independent comparison. The previous evidence/T12 files remain byte-for-byte unchanged.

## Gates unchanged

Independent review, actual integrator startup/write tests, actual host retained-handle/protected-grant wiring, genuine kernel ENOSPC, kernel short-count returns, kernel fsync failures, macOS/Windows runtime, power-loss durability, and filesystem/metadata qualification remain open. These fixtures use durable/plain-metadata Linux operations. No test activates production writes. Historical receipt replay is not a current workspace-integrity claim. The conservative 255-operation effective storage cap and non-evicting receipt lifetime remain unchanged.
