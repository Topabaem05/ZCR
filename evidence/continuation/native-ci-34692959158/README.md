# Native checkpoint 34692959158

Overall result: **FAIL**. [Actual GitHub Actions run](https://github.com/Topabaem05/ZCR/actions/runs/34692959158), PR1 head9d6d8e55, source tested as GitHub merge commitb6475a04. The tested tree1c7fbe5048241cc82d0bc8b1170f7f8ab20d48bd exactly matches locald0f35ef. Each source checkout was clean before and after.

| Native runner | Debug registered tests | ReleaseSafe registered tests | Remaining failure |
|---|---|---|---|
| Ubuntu24.04 x86_64 | 285/285 passed | 285/285 passed | Registered T12 and T15 files absent at this checkpoint |
| macOS15 Apple Silicon | 232 passed,12 skipped | 232 passed,12 skipped | T11 fchmod expects u16 but source supplies u32; T12/T15 absent |
| macOS15 Intel | 232 passed,12 skipped | 232 passed,12 skipped | Same T11 compilation error; T12/T15 absent |

The skipped watcher cases do not establish native Darwin watcher lifecycle support. T11 did not execute on Mac; resolving its compile error alone will not implement its currently Linux-only publication paths. The previous T01 I19 field-count regression is fixed and executes successfully on all three targets in both modes.

Builds, frozen contract verification, codec tests and native standalone CLI checks passed on all targets. The Linux registered-test results include the integrated T11 atomic publisher and T14 watcher in both modes. These module results do not enable production writes or substitute for T12 persistent recovery.

The raw report, command logs, source/config/corpus snapshots, CLI transcripts and baseline results are retained per target. download-verification.json proves downloaded ZIP SHA256, every artifact member hash/size, every binary inside both compressed archives, and every recorded source blob against the exact local checkpoint. All4164 comparisons passed. Verification validates provenance; it does not change the failed CI result.

The original ZIPs contain the recorded binaries and remain downloadable through GitHub Actions while the14-day artifact retention lasts. index.json records their immutable IDs and digests. This directory retains reports and logs rather than embedding hundreds of megabytes of historical executables. verify_artifact.py can revalidate the original ZIP against the preserved source commit when the source-history bundle has been imported.

Actual Codex/Claude routing and sandbox tests, model E2E/performance, macOS11 and full APFS crash/power-loss qualification remain NOT_RUN. T12, T15, runtime-cache and governor follow-up work is not included in this checkpoint's passing counts.
