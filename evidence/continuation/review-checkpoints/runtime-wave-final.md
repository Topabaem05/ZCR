# Runtime review fix-round 1

Reviewed 2026-09-12, limited to prior R1/R2 and delta `c61ac06201b34e62d51e805bb71a6ca2fee8457e..d15a9d7a2466cda90a0d739af25e3ae78b1ce509` in `ZCR-runtime-fixes`.

**SPEC: REQUEST CHANGES for one residual R2 evidence mismatch below. R1 is addressed.**

**QUALITY: REQUEST CHANGES for the same evidence mismatch. The bounded production/test fix is approved at source; no new Important runtime breakage was found.**

The remaining correction is evidence-only. No broad source review or suite replay is requested.

## Identity and review method

Read the prior `state/reviews/runtime-wave-review.md` findings, supplied `review-c61ac06-d15a9d7.txt`, and appended implementer report. Read the fix diff once and examined only its evidence links and the changed production boundary. No source/Git/index mutations, subagents, native socket attempts, or covered-suite reruns occurred. Only this report was written.

Verified clean HEAD `d15a9d7a2466cda90a0d739af25e3ae78b1ce509`, tree `80375ed118fd8b3e0295dc26cc5b9894982f93a1`. Frozen fix source `95352af44fd4c84574e3ae4e190f00654f8ec520` resolves to tree `364ec8fcc24b9c35782d8f2ef9cd38d293f5dab7`. Scoped `git diff --check` exited 0. The delta contains `src/broker/server.zig`, `tests/t15_test.zig`, and additive `evidence/continuation/runtime-review-fixes/r2` artifacts; earlier evidence remains unchanged.

Global constraints remain Zig 0.16.0, protocol zcr/1, MCP 2025-11-25, raw frame 16 MiB, JSON depth 64, output default 256 KiB / maximum 2 MiB, broker sessions 16. The wave changes none of those constants, authority grants, production write policy, or shared Budget/CPU/pin ownership.

## R1 — addressed: test executes the production saved-cancellation submit/error completion

Production `dispatchBuffered` now invokes `submitPreparedFrame` at `src/broker/server.zig:378`. The helper at lines 631–651 owns envelope reservation/allocation, copies the saved cancellation into the real cancel flag, submits to the actual executor, destroys/releases only rejected envelopes, and distinguishes `error.Cancelled` at the production catch. The native dispatch and the deterministic test share this implementation.

The replacement test at `tests/t15_test.zig:628` obtains a saved marker from `BufferedCancellations.observe`, starts its cancel flag false, and passes the marker through the production helper. It checks that the callback did not execute, original JSON-RPC ID 2 and `E_CANCELLED` are emitted, completion state becomes 2, and frame credit stays live while output is pending. It then invokes the same completion release helper used by production (`server.zig:654–658`) and checks exact Budget byte restoration. The missing target file supplements the callback assertion. This directly fixes the earlier disconnected submit/helper test.

Unlike the prior test, reinstating a catch-all resource error inside the shared production helper now fails the regression. The retained RED log records a real `Executor.submit` cancellation followed by `submitPreparedFrame` returning `ResourceExhausted`, with 0/1 passing. Its displayed intermediate test used a slightly different prepared-frame argument shape; the complete dirty RED snapshot was not retained. That limit is disclosed and does not turn the final source's shared call path into a fixture-only test.

Both existing new Debug and ReleaseSafe direct logs report 1/1 passing. Their binary/log identities match the supplemental records. Native dispatch assertions were not weakened.

The extraction preserves accepted-job ownership and callback userdata. Rejected envelope credit is released before cancellation encoding. Normal completion retains the arena/output credit, while encoding failure returns through the existing dispatch cleanup/resource-error path. The temporary job-state zero during synchronous cancellation encoding is confined to the broker thread; it does not introduce an executor callback or additional CPU reservation. No new Important ownership, cancellation identity, resource bound, or isolation defect was found.

## R2 — mostly addressed, OPEN for one mismatched interpreter digest

Location: `evidence/continuation/runtime-review-fixes/r2/runs.json:21` (`python.sha256`; interpreter path at line 20).

The supplemental record names `/opt/codex/runtimes/codex-primary-runtime/dependencies/python/bin/python3`, also the explicit executable in both CLI-pressure argv records, but its SHA-256 does not match that retained executable:

| Value | SHA-256 |
|---|---|
| Recorded | `fa67443583172c407a69af5027407d34f68c87a59768951c252e77a19bca9395` |
| Actual named executable | `fa67443527ed9647f760d807e2a38f26340757123e643c4639cf273ed15d5ea7` |

The actual path resolves to `python3.12`, and its reported version is the recorded 3.12.14. Independent repeated hashing produced the actual value above. This is the only mismatch among 171 supplemental hash/link checks. It means the package cannot currently claim all recorded executable identities verify, even though all Zig test/CLI binaries match and their functional results remain useful.

Correct the interpreter identity from retained evidence and regenerate the `runs.json` entry in `artifacts.sha256`. If the historical interpreter cannot be established, explicitly record that limit instead of assigning the current digest to an unverified historical execution. This is a residual evidence-contract defect, not a claim that CLI checks or runtime code failed.

All substantive omissions identified by old R2 are otherwise repaired: 23 executable identities now include both optimization modes, launch binaries, distinct broker full/filtered binaries, retained REDs, focused tests, and the contract tool. The package preserves the CLI driver, configuration, both proofs, and all 17 tiny/warm inputs. The 25 run records explicitly link commands/cwd, binary, log, config/corpus and source identities; dirty RED records now identify only known bases and their source limitations. The contract-digest execution has a retained tool identity and matching output log.

## Evidence verification and limits

Independently checked:

- All 39 entries in supplemental `artifacts.sha256`: match.
- All 23 retained executables in supplemental `binaries.sha256`: match.
- Additional structured checks: 171 hashes/links checked, 170 match and the Python digest above does not; 16 source/config Git-blob IDs and hashes match; 41 source/tree cross-links match.
- All 25 run records were inspected for linked identities, result counts and disclosed source status. CLI driver/config/proof copies and all 17 fixture files byte-match the retained state files.
- Both source manifests match their exact historical/fix Git commits. Config remains linked to unchanged build/config/contract bytes. Zig toolchain digest matches `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c`.
- New direct boundary logs each contain `All 1 tests passed`; RED preserves 0/1 and real error stack. Contract log contains digest `bc75e601b8d3f6e5f5b1d52084f8cd9ca16ea81eda11c25e6c42494f5816bab6`.

The 39-file artifact manifest verifies the bytes of `runs.json`; it does not independently validate each claim inside that file. This explains why its successful hash check coexists with the interpreter mismatch.

Historical full memory/MCP/broker/CLI executions remain explicitly bound to source `5ad79b1`; the new focused boundary runs are bound to `95352af`. They have not been relabeled as full-suite executions of the newer source. Historical RED dirty snapshots, including the intermediate new RED, remain unavailable; known clean bases plus binary/log records are preserved without claiming exact source reproducibility. Empty successful focused-build logs still cannot independently establish their recorded exit, while non-empty direct logs provide covering evidence. These disclosed historical limits need not trigger suite replay.

Both prior full broker attempts remain 19 passed, 0 skipped, 9 failed at socket creation per configuration. The actual UDS assertions remain **NOT_RUN / environment blocked**, never PASS. The new seam does not close real coalesced/queued UDS cancellation, concurrent broker cache sharing, session/backpressure/control/half-close native gates. Native macOS/Windows and actual Codex/Claude execution remain **NOT_RUN**. Production writes stay disabled and no write/receipt integration gate is closed.

---

## Final scoped R2 identity correction — approved

Reviewed 2026-09-12 at clean evidence HEAD `ec9e5ad9d19d58fc0e96fe2f0ca8e3f8fa37d52f`, tree `fcf6985a7886a685cd24315e0ebc9b03e40a902d`. This final disposition supersedes the REQUEST CHANGES verdicts above solely for their remaining Python-identity finding.

**Final SPEC: APPROVE for the bounded runtime fix wave and its scoped evidence corrections.**

**Final QUALITY: APPROVE for the same scope. R1 and R2 are addressed; no Important finding remains in the reviewed fix diffs.**

Read only `review-d15a9d7-ec9e5ad.txt` and the appended identity-correction report, then checked the named executable and dependent evidence entries. `r2/runs.json` now records Python SHA-256 `fa67443527ed9647f760d807e2a38f26340757123e643c4639cf273ed15d5ea7`, independently recomputed from its exact named path. Its new file digest `e594cdf57cb30e63b6e41cfb799f02d9ea7e306bb1c2a496ef9f9a69e43e2344` matches the sole changed entry in `r2/artifacts.sha256`.

Compared the previous/new JSON objects and manifest lines: the Python digest is the only semantic JSON change, and `runs.json` is the only modified artifact-manifest entry. Git confirms only these two evidence files changed; scoped `git diff --check` passed. Frozen production/test source remains `95352af44fd4c84574e3ae4e190f00654f8ec520`. No suites were rerun and no source was edited. Earlier verified links are unchanged; this review does not claim a second execution of the implementer's complete verification series.

The prior disclosed historical evidence limits remain: unavailable dirty RED source snapshots and empty focused-build logs are not promoted to complete independent historical proof. The corrected digest resolves the identified retained-executable mismatch, not those disclosed historical limits.

Approval is a source and bounded evidence-review verdict, **not an all-native or release gate PASS**. Actual broker UDS assertions remain NOT_RUN / environment blocked, with the preserved full attempts showing 19 passed and 9 failed per configuration. Native macOS/Windows and actual Codex/Claude execution remain NOT_RUN. Production writes remain disabled. No additional runtime/client/write gate is closed by this evidence-only correction.
