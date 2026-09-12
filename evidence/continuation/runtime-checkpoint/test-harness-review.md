# T00–T03 test harness review

**Verdict: APPROVE. No actionable blocking findings.** Reviewed source `16ad06115b3bd67fc00c192cbf54ef69429171a2`, RED `40ab5c7ac0e4127c87a20ff830b457a1276f05f2`, and evidence commit `1bdd428ec39a47679a49481d89ce0b32587d3d91` in `/workspace/scratch/3f4ab65dfb82/ZCR-tests`. Review scope is T00–T03 test changes and their evidence. No source edits or test reruns were performed.

## Git fixture isolation

T00/T01/T02 fixture subprocesses filter every inherited key with a case-insensitive `GIT_` prefix before installing their explicit fixture settings. This removes workspace/index/config/template redirection, stale indexed config settings, and unknown future Git controls. Non-Git host values are preserved. Fixture mutations select an absolute `/usr/bin/git` or `/bin/git`, so the intentionally unusable inherited PATH cannot select a different fixture executable. The T00 workspace probe uses sanitized settings and a trusted PATH.

The replacement environment disables system/global configuration, hooks, signing, external attributes/excludes, and interactive prompts; it supplies fixed author/committer identities and an empty owned template directory. Git object/worktree discovery controls cannot survive from the inherited map. All targeted mutations operate on fresh owned repositories.

Each regression uses a real disposable sentinel repository and attempts init/config/add/commit with hostile Git settings pointing to that sentinel. Checks include unchanged sentinel HEAD, index bytes, configuration bytes, and files; T01/T02 also preserve full status. They verify target-specific configuration, stripped redirection variables, preserved non-Git values, and the trusted executable. This exercises actual redirection rather than only checking a sanitizer's returned keys.

## Ordering and added boundary coverage

- T03's child gate remains closed during the first `ChildrenPending` assertion. The test checks the child count, live reservation and live allocation before publishing `write_buffer` through the release/acquire gate. Deferred cleanup joins the child before releasing its context, with token fallback for spawn failure. This removes the scheduler-dependent refusal assertion while preserving real concurrent drain behavior.
- FD and CPU coverage independently sets the selected cap to 3 and the other cap to 32, keeping byte/output capacity ample. Each test checks oversized refusal without state changes, exact-cap admission, cumulative refusal with identical accounting, partial release and replacement admission, then zero final usage and reservation count. The two resource limits are exercised independently.
- The restricted-read test uses existing allowed and outside files, including component-prefix lookalikes. Exact OutOfScope assertions on read/batch_read and enumeration cannot pass merely because a target is absent.
- The hardlink test creates a real alias to the immutable build file inside an allowed writable subtree after authorizer initialization, checks inode/link count, demonstrates an ordinary neighbor is writable and the alias readable, then requires alias patch refusal. It is genuine identity-boundary coverage.
- The digest oracle specifies four literal tracked paths in independent sorted order and literal expected contents, including nested and space-containing names. It constructs the required hash framing without calling implementation listing/sorting/framing helpers. An untracked contract file remains excluded when its bytes change.

Independent T03 subreview also found no blocking ordering, cleanup, or cap-coverage defect. The added scope/hardlink/digest/resource tests are correctly classified as coverage additions, without claiming they exposed prior runtime defects.

## Evidence verification

Verified all 52 recorded source hashes, source commit tree, canonical source-manifest hash, contract digest, archived driver/build-options hashes, and current Zig/Git binary hashes. All match. All eight final Debug/ReleaseSafe run records name the reviewed source, record compilation and execution exit 0, and match both actual binary and copied log hashes.

Per mode, logs contain 12 T00, 19 T01, 15 T02, and 14 T03 passes: 60 total, with no skips. The three RED binaries/logs also match their records and show actual sentinel-HEAD assertion failures. RED metadata candidly records execution from the dirty regression state at the earlier base; its exact tested source hashes match the subsequently committed `40ab5c7` blobs, so the RED source is recoverable and not misrepresented as a clean-base run.

The full baseline-to-evidence diff is limited to the four authorized test files and `evidence/continuation/test-harness/`; `git diff --check` passes and the review worktree is clean. Runtime modules, contracts, build registration, and configuration are unchanged by these commits.

Full integration-runner execution and actual macOS/Windows runtime remain NOT_RUN in this branch, as the evidence states. Root should retain those integration gates when applying the reviewed commits.
