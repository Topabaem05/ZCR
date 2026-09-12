# Runtime review fixes: R2 supplemental evidence

This additive package closes the independent review's evidence-link gap without rewriting the historical package. `runs.json` binds each reported direct Debug/ReleaseSafe, MCP launch, filtered/full broker, CLI pressure, and new R1 boundary execution to its full argv, cwd, source identity, config/corpus manifest, log, and binary SHA-256.

`cli/` preserves the exact pressure driver, workspace/task configuration, proofs, and all 17 input files. `manifests/binaries.json` includes every reported installed Debug/ReleaseSafe test artifact, both launch binaries, distinct filtered/full broker binaries, CLI binaries, retained RED binaries, and the R1 binaries.

Historical RED source limits are explicit in `runs.json`: exact binaries and functional failure logs remain, but the dirty pre-fix source/test snapshots were not retained. Their clean base commits are recorded; no final corrected source identity is assigned to them. The new R1 RED has the same disclosed dirty-snapshot limit.

The full native broker attempts remain environment blocked: both ran, each passed 19 deterministic tests and failed 9 AF_UNIX tests at socket creation. They are not PASS.
