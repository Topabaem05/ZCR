# T13 independent review — APPROVE

Reviewed source commit `8a4d74fe6f87a1f5427c6d0f94dd0b01fe082efd` in `/workspace/scratch/3f4ab65dfb82/ZCR-T13`, against base `98c722ebc906321b94bc3e9c8b60522f3305faa7`. No blocking correctness, security, accounting or lifetime finding in the reviewed implementation under its documented ownership preconditions. This is approval of the T13 module source, not a claim of completed application integration or platform runtime gates.

## Coverage

Read all 1,030 lines in the three owned implementation modules and entire 14-test suite:

| File | Lines | SHA-256 |
| --- | ---: | --- |
| `src/cache/content.zig` | 445 | `a3ceaa5c9e67c2a26528e260815010e1e0799b9b800cf9c5411d65c409993de3` |
| `src/cache/association.zig` | 106 | `69cb402708d851060c5bc5fda6a6b77e6ef47fefced33b6556bfe646d0d358f4` |
| `src/cache/lines.zig` | 49 | `6e17fa2885df645fb8dce77941d7e459b7cacb8177b3552d34c974e691f2c73e` |
| `tests/t13_test.zig` | 430 | `d78f7c4ec7c3c647d82ada2acd6158642a1f1871bfc151ac3a5c42a7a8507e85` |

Read T13 requirements/ownership, frozen I13 and related core types, cache keys and lock/lifetime rules in docs/17, cache/memory requirements in docs/05, workspace/domain/incarnation isolation in docs/06, and checked-live full-hash requirements in docs/07 and docs/09. Checked relevant T02 authorizer, T03 budget and T10 session/registry behavior. README, docs/01, docs/02, docs/12 and docs/13 supplied the enclosing invariants and gates.

## Findings

No requested source changes.

- **Authority and identity:** `Session.authority` validates the existing registry session and boot nonce, live workspace/root identity, task and policy binding before a cache lookup. It accepts only read-like capabilities and calls the actual authorizer again. Immutable content keys include security domain plus SHA-256; mutable associations additionally contain complete workspace identity (including incarnation), generation, file identity and exact relative path. Domain forgery cannot pass registry session equality. Associations are hints and cannot bypass current path existence, authorization or full hashing.
- **Budget ownership:** Store/control tables are reserved once from the caller-supplied shared content budget. Content and sparse checkpoints share one accounted allocation. Each verifier reserves scratch, FD and CPU credits from the caller-supplied shared verification budget; there is no independently constructed per-call budget. Reservation and allocation failures unwind through defers. Four workspaces can pin one immutable allocation while per-session cumulative pin usage remains bounded; metadata tables have fixed charged capacities.
- **Full-hash correctness:** checked-live access opens each component without following symlinks, compares opened identities, hashes all bytes with an 8 MiB bound, checks file size/mtime/ctime and path identity afterwards, and revalidates authority/generation. `observe` separately hashes supplied bytes against the verified current file before copying/publishing. Matching mtime and size alone never produces a hit. LF checkpoints use a fixed newline-policy version, preserve raw BOM/CRLF bytes, and start every 128 lines. No persistent or cross-version cache is introduced.
- **Concurrent pins/eviction:** ready/loading/pin/association transitions share the cache mutex. Loading entries and entries with live pins are ineligible for eviction. A pin protects both the content allocation and its association slot. Invalidation retains pinned associations until drain. Content frees and filesystem I/O occur after releasing the cache mutex. Token ownership/hash/pointer/length checks prevent stale or foreign token release; unpin remains available after cancellation/revocation. Borrowed index use explicitly requires retaining the pin.
- **Validation quality:** the suite covers actual domain and session refusals, same-size/same-mtime content replacement, four-workspace shared accounting, cumulative pin budgets and saturation, exact resource refusal, bounded second touch/probation, allocation-failure enumeration, cancellation/deadline cleanup, a deterministic final-open symlink race, concurrent pin/evict behavior, sparse-index oracle boundaries and workspace retirement. Fixture mutations use an explicit `/usr/bin/git` and fresh environment map, so inherited Git redirection controls do not enter setup.

## Teardown and integration preconditions

`Store.deinit` is **exclusive teardown**, not a general concurrent destruction barrier. The host must stop new callers and join every public Store/Session call (including eviction, stats, invalidation, unpin and index borrowing) before destruction. `active_calls` tracks observe/cacheGet and `Busy` also protects retained pins; it does not track an eviction while that operation frees detached storage outside the mutex. The implementation owner confirmed this external quiescence requirement and is adding it explicitly to handoff/API integration notes. Under that precondition, the unlocked eviction/free sequence is safe. Calling deinit concurrently with a live eviction is outside the supported lifetime contract and must not be introduced by integration.

Concurrent cache operations also need an allocator that supports their concurrency. Store, registry, authorizer, cancellation storage and supplied budgets outlive all calls and outstanding pins. Runtime integration must consume one shared verification budget and preserve these lifetimes.

The frozen I13 adapter intentionally maps errors that its error set cannot represent to a cache miss; the checked entry point retains precise cancellation/version/I/O errors. Parent/root has accepted that adapter. Callers using I13 must recheck cancellation before fallback, as documented. Full rehash per hit is a conservative correctness choice; no cache speedup is established by these tests.

## Evidence independently checked

This review performed no source edits and no suite reruns. It independently checked producer-recorded source/config, installed binary and log digests against the actual files, and read the test implementation and reported run output:

- `green-debug`: exit 0, 26/26 memory tests (14 T13 + 12 T03); 64 source/config hashes, both installed binary hashes, and log hash independently matched. Record SHA-256 `74c2aaeccf59def399c121c25d7beb63963f3bcf3414155441faec577272f84e`.
- `green-safe`: exit 0, 26/26 memory tests (14 T13 + 12 T03); 64 source/config hashes, both installed binary hashes, and log hash independently matched. Record SHA-256 `c733656976d04566b10aee8559d8d05d921992b37928c272f2df57970f0ed6e8`.
- `fault-debug`: exit 0, 26/26 memory tests (14 T13 + 12 T03); 64 source/config hashes, both installed binary hashes, and log hash independently matched. Record SHA-256 `7f14d04867ea9be3d925241041bd3b8b0ca5da8dd7fa29d231fc568bdd4260b2`.

The records use the reviewed clean source commit. Native producer logs report 26/26 tests in Debug, ReleaseSafe and fault-debug. These are inspected producer executions, not reviewer reruns. Final evidence packaging was still in progress when the review began; this approval remains bound to the four source hashes above, which the owner reports unchanged.

Remaining gates: root integration/build/runtime wiring and actual macOS/Windows runtime remain outside this review. No broad missing-module suite was run.
