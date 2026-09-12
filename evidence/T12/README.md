# T12 source and execution evidence

Source: `8d241f687effb78c3416c3d733d18283a5956ffb`, tree `3f9c9b52c0ae250b276d49a2fd703527502c9d1f`, base `988dde8ed35141a8fff2b813f0988a9f346582e2`. This is an implementation checkpoint awaiting independent review and external gates, not production write approval.

The owned implementation consists of `src/storage/{journal,receipts,recovery}.zig` and `tests/t12_{test,child,fixtures}.zig`. Root-owned build/core and T11 publication code are unchanged from the approved base. I19 remains request-bound; the concrete I12 recovery adapter requires a fresh runtime identity and protected supervisor continuity. The supervisor must retain private state-directory and per-publication parent/temp/original descriptors as well as root/Git/common witnesses. A file identity or checksum alone does not authorize recovery.

## Executed results

| Configuration | T11 | T12 | Writer matrix | Recovery append killed |
|---|---:|---:|---:|---:|
| Debug | 41/41 | 21/21 | 20/20 | 1 |
| ReleaseSafe | 41/41 | 21/21 | 20/20 | 1 |

Every writer matrix row verifies an acknowledgment from a real exec'd T11 writer using the persistent T12 store, then observes `child.wait` report SIGKILL. Patch and create run C01–C10 in each configuration, using 768 KiB old/new fixtures and durable requests. Parent checks complete target bytes and the unrelated sentinel after death. Two fresh recovery processes reconcile the same receipt UUID/digest/state/sequence; the adapter replays identical requests and refuses conflicting digests. The separate killed-recovery test additionally kills one C07 writer in each configuration: total 42 killed writers and 2 killed recovery processes. C04 leaves the incomplete PREPARED uncertain, with no fabricated receipt. C01–C03 leave no authenticated record and preserve orphan temps.

The additional negatives cover namespace/boot/task/domain/policy mismatches, stale sessions and leases, inode replacement, no-op identity disambiguation, moved/recreated roots and parents, changed Git markers, missing publication witnesses, replaced private state directory, symlinks/FIFOs/hardlinks and decoys, checksum/sequence/version/length/receipt-chain corruption, concurrent same-key admission, cap refusal, retained borrowed output under old/future timestamps, and successive torn recovery sequences. Actual kernel EACCES is asserted before PREPARED, after publication, and before receipt persistence. Injected write/fsync errors and queued-writer quarantine are deterministic fault tests. Seven-byte write chunks exercise full-write looping but are not proof of a kernel returning fewer bytes than requested.

`zig build verify-contracts --summary all` exited 0. `zig fmt --check` on all six owned files and `git diff --check` exited 0. The production gate in `src/fs/edit.zig` remains hard false.

## Commands and provenance

Exact argv, cwd, environment, elapsed time, exit status, source/tree hashes, compiler digest, and installed test/child binary digests are in `Debug/run.json`, `ReleaseSafe/run.json`, and `handoff.json`. Each final command is:

```sh
ZIG_GLOBAL_CACHE_DIR=/workspace/scratch/3f4ab65dfb82/state/T12/final-<mode>/global-cache \
ZIG_LOCAL_CACHE_DIR=/workspace/scratch/3f4ab65dfb82/state/T12/final-<mode>/cache \
TMPDIR=/workspace/scratch/3f4ab65dfb82/state/T12/final-<mode>/tmp \
/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig build test \
  -Dtest-group=write -Doptimize=<Debug|ReleaseSafe> -Dinstall-tests=true \
  --prefix /workspace/scratch/3f4ab65dfb82/state/T12/final-<mode>/out --summary all
```

Here `<mode>` is `debug` or `releasesafe`. `run_final.py` records the exact commands and can rerun them in this workspace. Compiler version is 0.16.0, SHA-256 `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c`. Contract digest is `bc75e601b8d3f6e5f5b1d52084f8cd9ca16ea81eda11c25e6c42494f5816bab6`.

`cases.json` gives 40 exact matrix rows, PIDs, receipt results, source and child digests, and per-case manifest hashes. `raw-fixtures.tar.gz` retains case documents, bounded binary pipe transcripts, child stderr, and journal/forensic bytes; `raw-files.json` lists all 590 members and their SHA-256 digests. `recovery-kills.json` identifies the two extra killed-recovery fixtures. The raw recovery-kill transcripts preserve acknowledgment point 11; the parent test's OS termination assertion establishes SIGKILL, but those two extra recovery PIDs are not separately written to an artifact. The target corpus is defined and hashed in `corpus.json`; the packaging check independently verified all 40 retained targets and sentinels against it and matched executed child images to the recorded binaries.

The Zig build test protocol emits a `failed command:` diagnostic when reporting test stderr containing stage messages, even on a passing run. Both final process exits are 0 and both build summaries explicitly report 62/62 passed; retain the complete logs without editing that diagnostic.

`historical-red/` preserves the original functional RED and three subsequent functional regressions. Only the initial RED has a committed source identity (`f75b69b`); subsequent RED source snapshots were dirty and are not promoted to exact-source evidence. Their retained binary hashes are recorded when the original images remain available. `final-precommit-debug.log` is supplemental; final PASS applies to the later committed-source runs.

## Limits and gates

- Independent review and integrator startup/recovery/write tests remain required. Actual host launch wiring is not implemented or validated here.
- Genuine kernel ENOSPC before/after publication was not run; no shared-disk exhaustion was attempted. Genuine kernel short-count and fsync failure need a controlled external fixture. Injected failures are labeled separately.
- macOS/Windows runtime and power-loss durability are not tested. The concrete store currently refuses non-Linux. SIGKILL proves process-crash behavior only, on the recorded Linux configuration.
- The matrix uses durable requests. It does not establish every persistence mode or unsupported ACL/xattr path on every filesystem.
- Entries are never evicted; caller-borrowed receipts remain valid until Store.deinit. This exceeds 24-hour minimum retention and makes clock rollback harmless. Worst-case reservation of 16 frames plus 16 forensic suffixes per operation is 512 KiB, so the 128 MiB cap refuses new work after at most 255 operations, before the separate 10,000-entry ceiling. Config/low-cap refusals were tested; a populated 10,000-entry store is not claimed.
- Exact temp cleanup is intentionally omitted. Recovery preserves all temps, including unrecorded decoys, and never publishes, reapplies, or rolls back source bytes. UNCERTAIN blocks receipt success and leaves writes quarantined. Recovery never re-enables production writes.

No push or merge was performed by this task. The source commit and evidence commit are separate so review can bind every executed binary to the source commit without a self-referential evidence hash.
