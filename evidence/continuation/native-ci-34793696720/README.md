# Native CI 34793696720: main `a15b127`

**Run:** [34793696720](https://github.com/Topabaem05/ZCR/actions/runs/34793696720), `workflow_dispatch` on `main` at `a15b127` (merge of PR #3 after PR #2). Result: **success** on ubuntu-24.04, macos-15 and macos-15-intel.

This bundle keeps each platform's `report.json` from the job artifact, the registered-test logs, the artifact names, sizes and digests ([artifacts.json](artifacts.json)) and the job conclusions ([run.json](run.json)). The results apply to source `a15b127` only.

## Registered tests

| Platform | Debug | ReleaseSafe | Skips |
|---|---|---|---|
| x86_64 Linux ([report](x86_64-linux-report.json)) | 356 PASS / 3 SKIP / 0 FAIL | 356 PASS / 3 SKIP / 0 FAIL | T09 1, T11 1, T12 1 (platform-specific) |
| Apple Silicon, macOS 15 ([report](aarch64-macos-report.json)) | 347 PASS / 12 SKIP / 0 FAIL | 347 PASS / 12 SKIP / 0 FAIL | T14 12 |
| Intel Mac, macOS 15 ([report](x86_64-macos-report.json)) | 347 PASS / 12 SKIP / 0 FAIL | 347 PASS / 12 SKIP / 0 FAIL | T14 12 |

No allocation leaks were reported. On both Macs T08 is 27/27, T11 43/43 and T12 25/25 in both modes. Every recorded command (contracts, registered tests, codec tests, CLI subprocess, capability build and runtime) exited 0 on all three platforms, and each report's status is `PASS`. Logs: [registered-logs.tar.gz](registered-logs.tar.gz).

## What this closes and what stays open

- T12 on Darwin (PR #2) and the MC-004 retirement failure (PR #3) no longer fail on native Mac CI. See `evidence/mac-write-path-20260913/README.md` and `evidence/T08/mc004-retirement-20260913/README.md`.
- Each report still lists these external gates as `NOT_RUN`: G05 complete APFS ACL/xattr/crash-durability qualification, G07/G08/G13 actual host client and sandbox integration, G11 macOS 11 Intel runtime, and G12 paired model coexistence and end-to-end performance.
- Open findings not covered by this run: the MC-004 deadline test does not observe the watcher's cancellation (T08), and runtime-cache tests failed once with `IoFailure` under heavy local CPU load (T10/T13).
- Production writes stay disabled and release status stays `BLOCKED`.
