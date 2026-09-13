# Mac write path: T11 provenance attribute and T12 Darwin storage

**Date:** 2026-09-13 · **Host:** Apple M2 8 GB, macOS 26.6.2 (25G83), APFS, Zig 0.16.0 · **Production writes:** still disabled.

Exact commands, exit codes, source/tree, contract digest and test binary SHA-256 values are in [report.json](report.json). Each result applies only to its source commit and this host.

## Branches

| Branch | Commits | Scope |
|---|---|---|
| `claude/t12-darwin-storage` | `7f877f7` | T12 journal metadata, durable sync, tests, fixture cleanup |
| `claude/t11-macos-provenance` | `f2e83d5`, `026a335` | T11 publication attribute check, new WR-007 test |
| `claude/mac-write-path` | merge of both on `f1c388a` | combined verification |

## Results on this host

The reviewed source is `ea41ca3` (tree `ea7f602c…`), which includes the PR #2 review fixes. `report.json` `runs` and `test_binaries_sha256` come from builds of that commit; earlier runs are kept under `historical_runs` with their own sources.

| Run | Source | Result |
|---|---|---|
| **write group Debug** | **`ea41ca3`** | **68/68 pass (T11 43, T12 25), 0 leaks** |
| **write group ReleaseSafe** | **`ea41ca3`** | **68/68 pass (T11 43, T12 25), 0 leaks** |
| x86_64-linux-gnu write tests | `ea41ca3` | T11, T12, T12-child compile and install; not executed |
| earlier: write group Debug and ReleaseSafe, combined before review fixes | `5142fae` | 66/66 each, 0 leaks |
| earlier: write group Debug, T12 port only | `7f877f7` | T11 10/41, T12 14/24, 0 leaks |
| baseline: write group Debug, unmodified `main` | `f1c388a` | 11/65 pass, 54 fail, 168 leaks |
| mcp group Debug, `main` | `f1c388a` | 29/29 pass (MC-004 passed) |
| x86_64-macos under Rosetta, combined before test fix | `6354a52` | 60/66; see below |
| x86_64/aarch64 Linux | `6354a52` | test binaries compile and install; not executed (foreign target) |

For comparison, the macOS 15.7.9 CI run of `88546e8` (evidence/merge-20260913) had T11 41/41 and T12 1/24 with 168 leaks in both modes.

## What was wrong

1. **T12 was Linux-only.** `journal.Store.init` and `journal.metadata` returned `Unsupported` off Linux, T12 tests called `statx` and `mknodat`, and `Fixture.init` leaked every completed step when the store was refused.
2. **T11 refused every file on macOS 26.** Every file and directory a process creates carries `com.apple.provenance`. `publish.noAttributes` refused any extended attribute, so all patches and creates failed before publication. The macOS 15.7.9 runner did not show this.

## Changes

- `journal.metadata` on macOS uses `fstat` with the device mapping of `policy.paths`; BSD file flags on store files are `RecoveryRequired`.
- `journal.sync` on macOS uses `F_FULLFSYNC`; a refusal is `DurabilityFailed`, with no `fsync` fallback.
- `publish.noAttributes` on Darwin allows the name `com.apple.provenance` and still refuses every other attribute and every ACL. Linux is unchanged.
- `publish.Temp.copyMetadata` on Darwin reads the provenance value of the original and the temp file and refuses before the commit point unless both are equal or both are absent. The kernel gives the temp this process's value and ignores attempts to set or copy another, so a different value cannot be preserved (PR #2 review).
- `journal.privateState` on Darwin refuses an extended ACL on the store root and on every store file opened or created, because owner and mode checks do not show an ACL that grants another account access (PR #2 review). Linux is unchanged.
- T12 tests use `policy.paths.statHandle` and `mkfifo`; `Fixture.init` has an `errdefer` chain.

## Probes

Sources and output are in [probes/](probes/); `results.txt` records the run.

| Probe | Observation |
|---|---|
| `probe.c` | `fcntl(F_FULLFSYNC)` returns 0 on an APFS file and directory |
| `prov.c` | new files from a shell and a native binary carry an 11-byte `com.apple.provenance`; `fremovexattr` and `fsetxattr` return 0 and leave it unchanged |
| `prov2.c` | with a value read (read-only) from another app's file, `fsetxattr` and `fcopyfile(COPYFILE_XATTR)` return 0 and the target keeps this process's value |

Apple has not documented the attribute. Background: [Apple Developer Forums 723397](https://developer.apple.com/forums/thread/723397), [Michael Tsai](https://mjtsai.com/blog/2023/03/16/ventura-adds-com-apple-provenance/) quoting Howard Oakley, [astra.pizza](https://astra.pizza/posts/2026-03-14-provenance-xattr/).

## Rosetta x86_64 run (not Intel hardware)

On `6354a52`, T11 was 39/42 (8 leaks) and T12 21/24 (4 leaks). One T11 failure was the wrong test expectation fixed in `026a335`. The other five failed while `workspace/identity.zig` ran `git` through `std.process.run` (or, for WR-005, in the recovery child that does so). `identity.zig` maps every non-memory run error to `IoFailure` and uses a 5 s timeout, so the real error name is hidden. The Rosetta baseline on `main` fails 54/65 for the T11/T12 reasons above and cannot isolate this.

`probes/git_spawn_probe.zig` runs the same four git commands with the same environment, limits and 5 s timeout, 5 rounds each. Native: 20/20 exit 0, slowest 331 ms. x86_64 under Rosetta: 20/20 exit 0, slowest 147 ms ([native](logs/probe-run-native.log), [Rosetta](logs/probe-run-x86_64-macos.log)). A single translated process spawning git is therefore fine; the failures only appeared inside the full test run. **The cause stays open.** Candidates not yet tested: concurrent T11 and T12 binaries under Rosetta, or state left by earlier tests in the same binary. Surfacing the real `std.process.run` error in `identity.zig` would let the next run name it.

## T08 MC-004

The macOS 15 CI failure (`entered and accepted_during_retirement`, Debug only) did not reproduce in a single run here. The test uses two 250 ms wall-clock windows.

`probes/mc004_stress.sh` built the six MC-004 tests from `main` `f1c388a` in Debug (binary `cc4f2983…`) and ran them 15 times idle and 15 times with 8 busy loops on the 8 CPUs ([summary](logs/mc004-stress-summary.log), [per-run logs](logs/mc004-stress-runs.tar.gz)):

| Condition | Result |
|---|---|
| idle | 15/15 pass |
| 8 busy loops | 12/15 pass; runs 9, 11, 12 fail |

All three failures are `MC-004 retiring tool id is detached before gated arena teardown` at the combined assertion (line 559), the same test and line as CI. The other five MC-004 tests passed every run, including the other 250 ms window. This reproduces the CI failure under CPU load and supports a wall-clock window too short for a loaded Debug build. It does not yet show which of the two conditions failed, and it does not rule out a real ordering problem that load exposes. No MC-004 code or test was changed here.

## Not verified

Native Intel Mac hardware, macOS 11–12, power loss and kernel fault injection, host supervisor, real clients, and Linux runtime of this branch (left to the PR's native CI).
