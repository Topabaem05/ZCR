# T11 Darwin publication — independent SPEC / QUALITY review

Review date: 2026-09-12. Worktree: `/workspace/scratch/3f4ab65dfb82/ZCR-Darwin-publication`.

| Item | Verified value |
|---|---|
| Base | `11b2fdc4953e3a27089c4c4b51cda1b0433b14a8` |
| Source commit | `d8e7ac519f3eca4b282840c8bc4c072a0d591739` |
| Source tree | `a047bd09308d1fb46764a09970bc0fad7ec06d0c` |
| Evidence HEAD | `ef891f0936af9042a85b4fee6ab0b7b383fe70bb` |
| SPEC verdict | PASS for the approved bounded source continuation; native platform acceptance remains OPEN |
| QUALITY verdict | PASS for source review and verified Linux evidence; native SDK linking/runtime remain NOT_RUN |
| Blocking findings | None identified in the reviewed change |
| Production write gate | `false`, unchanged |

This accepts the source for integrator-owned native CI follow-up. It does not establish Darwin support completion, macOS 11 execution, native durability, T12 recovery, or production write authorization.

## Scope and review method

Read the dispatch, brief, manifest, handoff, supplied source diff once, repository AGENTS and mandatory task/design documents, and recorded evidence. Subsequent reads were restricted to concrete risks: native declarations and errno mapping; policy device identity; parent/temp identity reconciliation; metadata refusal and ownership; editor preflight, receipt, fence and quarantine paths; test selection; and artifact provenance. No source or Git mutation, build, test rerun, or subagent was performed. This review file is the sole written output.

Read-only Git checks confirmed clean status including untracked files, both ancestry relationships, and eight changed paths within the manifest: two approved source/fixture files and six Darwin evidence files. No build, core, policy, editor, journal, interface, contract or gate change is present.

## Source findings and resolved risk checks

No actionable source defect was found. File references below are relative to the reviewed worktree.

- `src/fs/publish.zig:35`: Darwin uses `std.c.fstat`/`std.c.Stat`, with the pinned compiler's Intel `fstat$INODE64` selection. Device conversion exactly matches `src/policy/paths.zig:199`: bitcast the native signed device to an equal-width unsigned value before widening. Regular-file type, one link, ordinary mode bits, nonnegative size and zero native flags are required. Linux statx checks remain intact.
- `src/fs/publish.zig:69`: Linux and Darwin xattr declarations have separate target-specific signatures. Darwin enumeration uses four arguments and `XATTR_SHOWCOMPRESSION=0x20`; any attribute refuses publication. ACL inspection is independent: an allocated extended ACL is released with `acl_free` and refused; null is accepted only with `ENOENT`. The downloaded approved Libc implementation supports this absent-ACL convention. Other errors fail closed, and no Linux `acl_get_entry` convention is imported.
- `src/fs/publish.zig:193`: create uses the public five-argument `renameatx_np` with only `RENAME_EXCL=0x4`, and both names remain relative to the same opened parent descriptor. There is no overwrite fallback. `src/fs/publish.zig:205` retains identity reconciliation before interpreting syscall failure; an observed published temp returns through the applied path, while ambiguous temp identity requires recovery. The pinned Darwin errno enum maps `ENOTSUP` to `.OPNOTSUPP=45`, so the retained unsupported mapping covers the documented filesystem refusal.
- `src/fs/publish.zig:103`, `src/fs/edit.zig:258`: existing component/parent identity validation, final source/version checks and commit fence stay in place. The managed-writer threat boundary remains explicit; no hostile external-writer CAS claim is introduced.
- `src/fs/publish.zig:297`: supported mode remains bounded to `0o777` (new files use `0o600`), making the inferred target-width `@intCast` into `fchmod` safe. Mismatched owner/group refuse replacement. Both original and temp attributes are checked before publication.
- `src/fs/edit.zig:222`, `src/fs/publish.zig:220`: directory sync is preflighted before journal preparation/publication for durable requests; unsupported sync fails before commit. `src/fs/edit.zig:267` retains applied outcome after publication, postcommit sync error reporting and quarantine at line 294. Strongest durability stays Unsupported at line 90; `production_writes_enabled` remains false at line 9.
- `tests/t11_test.zig:484`, `:493`, `:573`: fixtures use the six-argument Darwin `fsetxattr` and native extended ACL creation APIs, with owned ACL cleanup. Both primitive and editor refusal preserve target bytes; editor refusal also asserts no journal preparation and no temp residue. The native synthetic principal's actual acceptance is still a runtime gate.
- `tests/t11_test.zig:531`, `:898`: assertions now check published identity/mode/uid/gid and the original receipt ID/generation/applied state on replay after uncertain replace and create. The unchanged `src/fs/edit.zig:111` returns the matching original receipt. All 41 baseline test names remain, with no skips added; race, fence, cancellation, lifetime and quarantine assertions are retained.

Public API checks used the supplied Apple OSS reference contents under `state/darwin-api` and the pinned Zig 0.16.0 declarations. These establish source agreement, not native symbol resolution or filesystem behavior.

## Evidence audit

The audit recomputed 55 referenced file hashes, with zero mismatches, including source/config/corpus/contract inputs, compiler, manifest, command records, logs, both Linux binaries and historical native archive/report/verification. All four aggregate hashes matched. The six committed evidence-file hashes also match the handoff.

| Evidence | Verified SHA-256 |
|---|---|
| Source path aggregate | `ae42f7b963de8f54cc7b9b079d2b8b579037c67569cbc263be33e3525072735c` |
| Config | `d1ec42953d3539408653ebb4ce5aa291205785f7cabd6f2a16bd5568c7455594` |
| Corpus | `c80d7e39d32a04f573b44c8fda9eff119bd10e072ab659929c63b3cfcd5baca2` |
| Contract | `bc75e601b8d3f6e5f5b1d52084f8cd9ca16ea81eda11c25e6c42494f5816bab6` |
| Linux Debug binary | `3ab73e40b85ae6c5f78cf4392440d0c96add47ce02de75a65ea821dc2ecd0006` |
| Linux ReleaseSafe binary | `16ee5265dd442d55e0d066c1617ed699f99c7a1f3fe74767efab2b6249a92bb9` |
| Each Linux test log | `58c63313f6b21ec5ac9001badb80460a77f55b74deaedd21f578407e81176281` |
| `evidence/T11/darwin/results.json` | `5b98620ae0f868f304f0f7a866bdd5d5e2c6c1ef7737e488f89c3ae3c45fb5e1` |

Exact argv/cwd/environment/exit records in `results.json` match their state command artifacts. The runner selects the actual T11 root, pinned compiler and this worktree's modules, with isolated cache/global-cache/tmp paths and no filter. The relevant module graph agrees with `build.zig`; the unavailable aggregate write group is disclosed because this base lacks T12 source.

| Recorded verification | Audit conclusion |
|---|---|
| Linux Debug / ReleaseSafe | Each has compile exit 0 and binary execution exit 0; each log contains 41 individually passing T11 cases and “All 41 tests passed.” No skips. |
| ARM64 / Intel macOS 11 targets, Debug / ReleaseSafe | Four compiler exits 0, explicitly `-fno-emit-bin`, no run command or binary. Semantic checks only; no SDK linking or native execution proof. |
| Historical Apple Silicon RED | ZIP `b8990f3ed500ec69f93e3313f3442fb5d1d5f3c9b8991e62e1e4da86d6267300` verified; committed RED logs exactly match extracted original logs. Native report binds source `b6475a041b9cbee8263eb2d91138f544d3c04862`, distinct from brief checkpoint `9d6d8e55`. T11 failed compilation at fchmod's u32/u16 mismatch; no T11 runtime result. |

## Required native follow-up

1. Integrate the reviewed source into native CI, link against actual Apple SDK/libSystem, and execute all 41 T11 assertions without skips on Apple Silicon and Intel macOS in Debug and ReleaseSafe. Bind new evidence to the exact integrated source/tree, binary, compiler/SDK/OS/filesystem, commands and logs.
2. Confirm native ACL and xattr fixtures really install their metadata and refuse before journal prepare/rename while retaining original bytes. Confirm ordinary published mode/owner/group/identity, plain and durable replace/create, existing-create refusal and the simultaneous no-replace race.
3. Execute the retained fence/version, cancellation, callback-drain, quarantine and uncertainty tests; confirm original applied receipt replay after uncertain replace/create and truthful applied/durability failure after postcommit sync errors. Do not soften failed native assertions into skips.
4. Independently exercise filesystems lacking directory-sync or exclusive-rename capability and prove precommit refusal with target retention and appropriate temp handling. The standard 41-test result alone does not close this filesystem capability gate.
5. Keep actual macOS 11 runtime, APFS power-loss, strongest/F_FULLFSYNC behavior, T12 Darwin persistent-state validation and real crash/recovery evidence separately NOT_RUN until executed. Keep the production write gate false.
