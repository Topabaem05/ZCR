# Native storage capture independent review

Reviewed 2026-09-12. Target `5781b6cd6d015f791ff3fbfb287c5402567e9d23` in `/workspace/scratch/3f4ab65dfb82/ZCR-work`, against supplied base `d011a0d`. The checkout was clean at that target when review began. Root later added separate doc-only commit `11b2fdc4953e3a27089c4c4b51cda1b0433b14a8`; the checkout is clean at that HEAD and all three reviewed CI blobs remain byte-identical to `5781b6c`. This review remains pinned to the supplied target and does not widen to the later documentation. The bounded change is limited to `tools/ci/native.py`, `tools/ci/storage_capture.py`, and `tools/ci/test_storage_capture.py`. I read the supplied diff once, made no source or Git mutations, and did not rerun the four unit tests or either historical fixture capture.

**SPEC: APPROVE.** The source change captures generated T12 case/child records and recursive `state`/`state-original` records into per-mode artifacts outside the source tree. It excludes the fixture repository, opens regular files with no-follow/nonblocking flags, rejects changed or oversized files, skips symlinks and other special files, and applies fixture/file/payload bounds. Target and sentinel content is represented only by state, size, and SHA-256. Capture success is explicitly distinct from runtime success. The registered-test command remains independently required, while missing or failed capture produces a failed required check when T12 is present.

**QUALITY: REQUEST EVIDENCE CORRECTION; source is otherwise approved.** I found no blocking correctness or maintainability defect in the three-file implementation. The submitted report overstates the provenance records available for the historical captures, as detailed below. This prevents treating those two archives as cryptographically bound to the claimed historical source and exact collector invocation. It does not turn them into current-runtime evidence. Native execution of the edited driver remains **NOT_RUN**, exactly as scoped.

## E1 — P2 evidence provenance: historical capture command and log hashes are absent

Locations: `state/native-storage-capture/report.md:5`; `state/native-storage-capture/verification.json:9-20,21-38`.

The report directs the reviewer to `verification.json` for the exact collector command and log hashes for the two historical captures. The only command record at lines 9–20 is the four-case unit-test invocation and its stdout/stderr hashes. The Debug and ReleaseSafe records contain a status, counts, archive digest, asserted historical source, and `runtime_rerun=false`; they contain no collector argv/cwd/log identity, input-fixture or corpus identity, or `capture.json` digest. The retained directory likewise contains only the unit-test logs.

The historical commit exists and contains `tests/t12_test.zig` and `tests/t12_child.zig`, but that establishes neither that the retained fixture directories came from that commit nor that these archives were produced by the committed collector. Correct the report's claim or preserve the historical collector invocation/log and a fixture-corpus identity plus manifest digest. A rerun is unnecessary if retained records can establish those links; otherwise state the provenance limitation plainly.

## Source review disposition

- `native.py:203-214` places capture after the registered tests. `Run.finish()` derives failure from both failed checks and nonzero required commands, so successful capture cannot mask runtime failure and capture failure cannot pass silently.
- `storage_capture.py:31-91` writes to a caller-supplied artifact directory, archives only `child-*`, `case.json`, `state`, and `state-original`, and never archives `repo`. Regular-file open and post-read identity checks fail closed on final-component replacement; directory symlinks and special entries are excluded.
- Payload is capped at 64 MiB by default, regular members at 4,096, and fixture directories at 512. Tar member names are derived relative to the fixture root.
- The CI matrix invokes the driver only on Ubuntu and macOS, where the POSIX flags used by `_regular_bytes()` are available.
- At this commit `tests/t12_test.zig` is absent, so the new conditional branch is dormant and the existing registered-test build reports that T12 is not delivered. This is consistent with the stated prospective integrator hook, but it means this checkout cannot supply end-to-end native-driver evidence.

## Evidence independently checked

- Review-start HEAD exactly matched `5781b6cd6d015f791ff3fbfb287c5402567e9d23`, and that commit changes only the three declared CI files. Final HEAD is the clean doc-only follow-up `11b2fdc4953e3a27089c4c4b51cda1b0433b14a8`; the reviewed CI file hashes are unchanged.
- All three current file SHA-256 values match `verification.json`.
- The Python executable SHA-256 matches `verification.json`.
- `tests.stdout.log` and `tests.stderr.log` match their recorded hashes. The retained stderr reports four tests run and `OK`; those tests were not rerun.
- Debug archive SHA-256 is `ac9a48779cdc04dbd32e5466cd71bdf1df12930f006ca7975911ef79859560b9`; ReleaseSafe is `f82af1f7ceb7f5aef21b7e1caab4b56d00aae5514eff194aa0f1aa2123258063`. Both match the verification record and their current capture manifests.
- Each archive has 187 unique regular members across 21 represented fixtures. Every member's size and SHA-256 matches the corresponding current manifest entry. Neither archive contains an absolute/traversal name, `repo` or `.git` component, symlink, directory, or other special tar member. Both manifests say `runtime_pass_claim: false`.
- Every represented fixture has child transcripts and captured state; existing case JSON is retained. Target/sentinel oracle records are present. These checks validate the retained bytes and present manifests, not the unrecorded historical execution provenance.

No approval is implied for a future integrated native run. Publish that run separately, preserving the registered-test exit and capture result as independent facts.

---

## E1 evidence-correction re-review — ADDRESSED

Reviewed the evidence-only correction in `state/native-storage-capture/correction.md`, revised `report.md`, and revised `verification.json`, with the originals preserved as `report.historical.md` and `verification.historical.json`. No source, archive, test-log, or runtime result was reopened or rerun.

**E1 is ADDRESSED.** The revised report no longer says that `verification.json` contains exact historical collector command/log hashes. It accurately identifies the sole recorded command as the four-test unittest invocation and explicitly lists the absent historical collector argv/cwd/logs, fixture-corpus identity, and `capture.json` digests. Both the revised report and JSON now state that the retained archives/manifests establish byte-inspection evidence but do not cryptographically link the archives to the asserted historical source or exact collector invocation. The preserved historical files make the wording change auditable. This is the truthful limitation requested by E1; no historical provenance has been retroactively inferred.

**FINAL SPEC: APPROVE.** The original source verdict is unchanged.

**FINAL QUALITY: APPROVE.** The sole evidence-provenance finding is corrected. Native execution of the edited driver remains **NOT_RUN**, not PASS. Root's later T12 integration at `ad577ab` is outside this bounded re-review; the reviewed CI blobs remain those from `5781b6c`.

---

## Integrated T12 history-capture follow-up — APPROVE

Reviewed 2026-09-12, bounded delta `ad577ab..f8e174a68438a2e23b340dd70402edafea2cb584` from the supplied `state/native-storage-capture/review-history-followup.txt`. The delta changes only `tools/ci/storage_capture.py` and `tools/ci/test_storage_capture.py` with five insertions and two deletions. No test or native-driver execution was rerun.

**SPEC: APPROVE.** The collector now admits the exact top-level generated filename `history.json` beside `case.json` and `child-*`. It therefore retains T12 F1's original receipt-pair history while preserving the existing exclusion of repository source/Git content and the existing regular-file, no-follow, special-file, file-count, payload-byte, identity-change, hashing, and manifest rules. The test fixture adds representative receipt history and requires the archive member explicitly.

**QUALITY: APPROVE.** The change reuses the single generic record path instead of adding a second reader or archive path. The exact-name whitelist does not broaden recursive traversal. No finding remains in this delta.

Evidence was checked without rerun: checkout HEAD is exactly `f8e174a68438a2e23b340dd70402edafea2cb584` and status is clean; both changed-file SHA-256 values match `history-followup.json`; the named committed stdout/stderr logs match their recorded hashes; retained stderr reports four tests run and `OK`. The record explicitly makes no new runtime claim.

**FINAL SPEC: APPROVE. FINAL QUALITY: APPROVE.** The earlier `5781b6c` source review and addressed E1 correction remain approved. Native execution of the edited driver remains **NOT_RUN**.

---

## Native socket-path integration follow-up — APPROVE

Reviewed 2026-09-12, bounded commit `108b9061613cc1405f7417a50b33fa7207eedf33` from the supplied `state/native-storage-capture/review-socket-path-followup.txt`. The clean commit changes only `.github/workflows/native.yml`. This was a workflow/path analysis; no test, socket operation, or native job was run.

**SPEC: APPROVE.** The run step and always-run artifact upload now use the same shortened state directory, `${{ runner.temp }}/z-${{ github.run_id }}-${{ github.run_attempt }}`. Removing the target from this temporary path does not collide across the three matrix entries because each entry runs as an independent hosted job. Target and runner identity continue to flow through the native-driver argv/report, and the uploaded artifact name still includes the matrix target.

The preflight calculation is reproducible from each recorded cache path plus the 34-byte `/.zig-cache/tmp/<16-character fixture>/s` suffix. All six old/new lengths match the JSON exactly: old paths span 113–121 bytes and new paths span 91–98 bytes. The longest new Darwin pathname is 98 bytes, leaving room for termination within Darwin's 104-byte `sun_path` field. The Linux rows are also below their platform limit.

**QUALITY: APPROVE.** The concise workflow comment records why the otherwise opaque shorter prefix is required, and the matching upload-path edit prevents artifact loss. No consistency or identity finding remains in this delta.

**FINAL SPEC: APPROVE. FINAL QUALITY: APPROVE.** All earlier native-capture verdicts remain approved. Actual native execution after integration remains **NOT_RUN / upcoming**, not PASS.
