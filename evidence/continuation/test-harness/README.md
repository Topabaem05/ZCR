# Test harness audit correction

Scope: tests/t00_test.zig, tests/t01_test.zig, tests/t02_test.zig, tests/t03_test.zig and this evidence directory. Integrator-authorized test-only correction; no build, runtime module, core, contract or configuration source edits.

Base: `98c722ebc906321b94bc3e9c8b60522f3305faa7`.
RED commit: `40ab5c7`.
Test/fix source commit: `16ad06115b3bd67fc00c192cbf54ef69429171a2`.
Branch/worktree: `codex/test-harness-audit`, `/workspace/scratch/3f4ab65dfb82/ZCR-tests`.
Contract digest: `bc75e601b8d3f6e5f5b1d52084f8cd9ca16ea81eda11c25e6c42494f5816bab6`.

## Changes and failure evidence

T00/T01/T02 mutating fixture processes now remove every inherited `GIT_*` variable, preserving other host environment values. They choose `/usr/bin/git` or `/bin/git` explicitly, bypassing inherited PATH for fixture mutations. Fixed author/committer identities, disabled system/global configuration, disabled hooks and commit/tag signing, an empty trusted template directory, disabled external attributes/excludes and disabled terminal prompts isolate Git setup. The fixture Git probe also uses a sanitized environment and trusted search directories.

Each suite has an isolated sentinel regression. Hostile `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_CONFIG`, config injection and template settings point only to a disposable sentinel repository. The target fixture performs init/config/add/commit; assertions preserve sentinel HEAD, index bytes, config bytes and files (T01/T02 additionally preserve full status), and check target isolation. Unexpected future Git settings and stale config keys cannot survive the prefix filter. An unusable inherited PATH is preserved without being selected as the fixture executable. All three regressions compiled and failed before the fix because sentinel HEAD changed; their runtime RED logs and exact source/binary hashes are in `red/`. No hostile setting targeted a user or project repository.

The following are coverage additions or harness determinism fixes, with no claim of a prior runtime RED:

- T03 holds the child gate closed for the first `ChildrenPending` assertion, verifies ownership remains live, then releases the gate and permits at most 2,000 drain attempts with 1 ms waits. All paths join the child and clean up its token/arena. This removes the previous scheduler-dependent requirement that release happen to race a still-running child.
- T03 independently exhausts FD and CPU reservations while other caps remain ample: oversize refusal, exact cap, cumulative refusal with unchanged counters, partial release/regrant and complete release to zero.
- T02 authorizes a restricted read subtree and refuses existing outside siblings and path-prefix lookalikes, including batch-read and enumeration boundaries.
- T02 creates a real hardlink to an immutable build file inside the writable subtree after authorizer initialization, verifies matching inode and link count, allows an ordinary neighbor, and refuses patching the alias. This ran on Linux without a skip.
- T01 uses four explicitly sorted tracked contract paths (including nested and space-containing paths), independent literal bytes and hash framing, plus an untracked contract file whose mutation does not affect the digest.

No runtime defect was exposed by the additional boundaries. No assertions were weakened to accommodate implementation behavior.

## Validation

| Direct suite | Debug | ReleaseSafe |
| --- | ---: | ---: |
| T00 | 12/12 | 12/12 |
| T01 | 19/19 | 19/19 |
| T02 | 15/15 | 15/15 |
| T03 | 14/14 | 14/14 |
| Total | 60/60 | 60/60 |

All eight final compilations and runs exited 0 at the clean committed source above. No test skips. Zig 0.16.0, Linux x86_64. `zig fmt --check` and `git diff --check` passed. `provenance.json` records the source tree, source hashes, toolchain/Git binary hashes, configuration/corpus binding and isolated paths; each `green-*.json` records exact compile/run argument arrays, execution directory, exit code, source commit, binary hash and log hash. `results.json` indexes the runs. Repository contract/config verification ran within T01.

The archived `run.py` is the exact local direct-test driver used. Invocation pattern:

```sh
python3 /workspace/scratch/3f4ab65dfb82/state/test-harness/run.py T00 Debug green-T00-Debug
python3 /workspace/scratch/3f4ab65dfb82/state/test-harness/run.py T00 ReleaseSafe green-T00-ReleaseSafe
```

Repeat the same commands with T01, T02 or T03 and the matching label. The JSON files contain fully expanded Zig module arguments. Tests compile with `--test-no-exec` in this worktree, then execute with cwd `/workspace/scratch/3f4ab65dfb82/state/test-harness` because Zig's `testing.tmpDir` roots fixtures at cwd rather than the configured compiler cache. Caches, temporary files, binaries and execution logs remain under that state root. The runner removes parent Git environment controls before launch; hostile maps are injected only inside the regressions. A copy of the minimal build-options source is archived alongside the driver.

## Remaining gates

Actual macOS runtime and Windows runtime: NOT_RUN. T00's explicit unavailable-probe behavior on Linux does not constitute Darwin execution. The full integrated build runner is NOT_RUN in this isolated branch because other registered task sources are absent; focused module-wired tests avoid modifying integrator-owned build registration. Integration/review remains with root. These records attest the source commit above; the final evidence-only commit does not change any tested source hashes.
