Legacy FS/search continuation — source a5a24a3d7f0f9bc4a840cd0a6668e70ac3a6632f

The scoped remediation and native Linux tests are complete. Parent integration review and production exclude wiring remain separate gates. This is not a claim that every project task or macOS gate is complete.

Base: 9897f27a18c66c310ae6dda3ee854f7fdcdcfa3d
Branch: codex/legacy-search-audit
Worktree: /workspace/scratch/3f4ab65dfb82/ZCR-legacy
Source tree: 7e757018542321e65cd11cd5b85d01e0a00538e8
Contract digest: bc75e601b8d3f6e5f5b1d52084f8cd9ca16ea81eda11c25e6c42494f5816bab6
Toolchain: Zig 0.16.0, native Linux x86_64, dedicated state/cache/TMP/output.

All seven files in src/fs and src/search and all three T04–T06 test files were read in full. Hashes, line counts, and git blobs are in handoff.json/read_inventory. ignore.zig and scalar.zig needed no edits. Docs 00–17, AGENTS, README, tasks 00–25, catalog and historical T00–T07 handoffs were read during the preceding requirements audit; the parent owns the all-branch/task ledger. Shared build/core/contracts changes in this branch are exact authorized cherry-picks of integrator ab26dca and 5025059, locally 95a7a11 and 51ff311.

Changes and evidence:

- Streaming: Searcher uses Traverser.enumerateSearchCandidates. Only .search capabilities may use this internal entry; public files enumeration still enforces max 10,000 returned paths. A real 10,001-file regression proves the final match is found, and FS004 now covers real 200,000-file enumeration without an all-path index.
- Trusted ignores: Traverser.trusted_excludes contains optional borrowed global_exclude and git_info_exclude Io.File handles. Global rules are lowest priority, info/exclude next, then root/nested .gitignore. The caller must pin handle lifetime and rebind after atomic path replacement; parsing reads a stable version of the pinned identity each walk. No repository config, HOME/global path or model-supplied path gains authority. Bind both the file traverser and searcher.traverser.
- Ignore failure closure: unreadable, oversized, nonregular, changing ignore sources prevent traversal of the affected subtree and appear in explicit incomplete coverage. Local opens use O_NONBLOCK|O_NOFOLLOW and fstat to reject regular-to-FIFO races; post-read local path identity and size/mtime/ctime are checked. Borrowed handles remain open for their caller. Deterministic replacement/FIFO regressions pass.
- Regular reads: metadata.openRegular retains its signature; openRegularWithFault/OpenFault are deterministic test hooks. Native nonblocking no-follow opens plus post-open regular-type/identity checks reject FIFO replacement without waiting for a writer. Linux FD tests count /proc/self/fd rather than a constant.
- Search consistency: files with zero matches undergo the same metadata/path revalidation and one retry before completeness is claimed. The no-match-to-matching mutation regression confirms two final matches with one retry.
- Cancellation/deadlines: Reader derives effective Cancel.withTimeout once from validated 1..60,000 ms ReadSpec, retaining earlier parent deadlines. Retry, scan, interrupted short-read loop, bounded readExact and publication check it. Traversal/search/context preserve DeadlineExceeded separately from Cancelled and check final publication. Real 40 ms hook delays exceed 20 ms request deadlines without a producer toggling cancellation. All error paths release FD/arena/reservations.

RED commits and failures are separately recorded in handoff.json. Actual behavioral REDs cover omitted search candidates, unreadable ignore exposure, missing no-match retry, after-scan cancellation, ignored read deadlines and lost deadline reason. Missing TrustedExcludes/IgnoreFault/OpenFault compile errors are labeled missing intended API/test hook, not runtime failures. FS004 was an undersized fixture gap; expanding it is not claimed to have exposed a formerly unbounded allocator.

Final clean-source verification:

| Group | Debug | ReleaseSafe |
|---|---:|---:|
| io (T04 plus core deadline tests) |15/15|15/15|
| fs (T05) |15/15|15/15|
| search (T06) |15/15|15/15|
| batch regression (T07) |18/18|18/18|

All eight commands exited 0. Each run includes exact command argv, clean source commit/tree, config SHA, binary paths and SHA, fixture definition digest, output log and SHA. Every generated test binary, including T04-deadline-test, is hashed. Earlier 8050416 green runs are retained under pre-deadline files with their own source identity; they do not certify this final source. verify-contracts and scoped zig fmt --check passed. The test runner may render stderr as a 'failed command' diagnostic in FS004 logs; its final summary and process exit are 0 with 15/15 tests passed.

FS004 created 1,000 and 200,000 empty files on disk; all emitted paths were checked for validity, range and uniqueness with a test-only bitmap. Both corpora use 3,745,880 tracked live and peak bytes, zero skipped, complete=true. Large canonical corpus SHA is 8516686afc53e0500c9119dc68e4d62c60ab6e601af8d43a7f282bb90db6d26b. Sorted traversal forces its 64-entry/4 KiB path cache fallback. The bitmap is outside runtime accounting, is never used by production, and is not an all-path runtime index. This fulfills the FS004 memory/coverage fixture, not T21's 2 GiB performance or Apple hardware targets.

Native permission tests are genuine: this namespace maps only uid 0/gid 0, with CapEff=CapBnd=0 and NoNewPrivs=1, so there is no CAP_DAC_OVERRIDE/READ_SEARCH. chmod 000 produces actual access denial. Earlier attempts to switch uid were host setup failures and are excluded from RED/PASS evidence.

Independent reviewer review_legacy found FIFO-open races, missing local-ignore post-read path checks and context cancellation, all addressed. A second child review could not start because of the thread limit; root must perform the requested rereview. No remote writes were made.

Remaining limits/gates:

- Production trusted-exclude discovery/binding and refresh policy belong to the integrator, and must be reviewed and tested on the integration binary. The module default is no optional trusted handles; test binding alone does not prove launcher support.
- checked_live regular read snapshots retain the existing identity/size/mtime model; changes deliberately preserving that tuple can evade it. This is not immutable snapshot or transaction consistency. Ignore-file snapshots additionally compare ctime.
- Deadlines are cooperative between bounded operations. O_NONBLOCK prevents the demonstrated FIFO wait; it does not promise interruption of arbitrary kernel filesystem stalls.
- Apple Silicon/macOS/APFS and external host/client tests remain NOT_RUN here. Linux PASS and historic macOS artifacts cannot certify a new final Mac binary.
- T18 Windows and T20 parser are optional; all other tasks T00–T25, including T19, remain subject to the parent consolidated plan and gates. No PLANNED design table was converted to runtime PASS.

Source commit sequence:

- a339344 — test(search): expose omitted candidates beyond files result limit
- 03fca3e — test(fs): specify trusted excludes and fail-closed ignore read errors
- 89eb368 — fix(fs): stream search candidates and bind trusted exclude handles
- a5ea0fa — test(search): require no-match version revalidation
- 3452614 — fix(search): revalidate files with no matches before completion
- a044679 — test(fs): inject ignore replacement and FIFO races
- a6209a0 — fix(fs): reject ignore FIFO races and revalidate loaded paths
- 978c217 — test(io): specify FIFO races and post-scan cancellation
- 8050416 — fix(io): refuse FIFO open races and drain cancelled context reads
- 95a7a11 — test: specify native deadline inheritance and cancellation behavior
- 51ff311 — feat(core): propagate monotonic deadlines through native cancellation
- 7388ea9 — test(io): expose ignored read deadlines and lost search deadline reason
- a5a24a3 — fix(io): enforce native deadlines and retain interruption reasons

Catalog IO-001–IO-006, FS-001–FS-006 and SR-001–SR-006 each map to named executed tests in handoff.json/catalog_coverage.
