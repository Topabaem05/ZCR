# T10 commit coordinator review

**Final verdict: APPROVE for T11 integration under the documented guard contract. No outstanding blocking findings.** Reviewed final source `f8a3b24f44a02aa882ec72c170ad57296e02c815`, coordinator implementation `02a4ee4f169133022f842cb310b041969c237ba8`, parent `8ff9c2884fece529fab7ccb85ca4282b8d00b221`, and RED scaffold `ab5df134d234792003a9a28aca70d26508b1cfc7` in `/workspace/scratch/3f4ab65dfb82/ZCR-T10`. No implementation files were edited and no suites were rerun by this reviewer.

## Source findings and disposition

No blocking coordinator state/linearization defect was found under the required guard ownership contract. One unsafe documentation allowance was found in `02a4ee4` at `registry.zig:39`: permitting an ordinary same-workspace snapshot while holding the guard can self-deadlock if identity validation fails, because snapshot then waits to retire the workspace until that same guard releases. This finding is resolved by `f8a3b24`: the contract explicitly prohibits ordinary same-workspace Registry calls while held, and four test observations now use mutex-protected internal generation reads instead of violating that consumer contract. T11 confirmed that it uses a pre-acquisition retained snapshot and `guard.next_generation`, and calls only `markApplied`/`release` on the registry during the publication phase.

## Linearization and lifetime assessment

- `acquireCommit` serializes current workspace/session/task/callback authority and fresh expiry checks with reserving a workspace publication slot and the next generation. The global mutex is released before the caller performs filesystem publication.
- Revoke, session unbind, managed-write disable, lease/callback expiry-producing operations, generation changes, rediscovered HEAD changes, and incarnation retirement all wait for the workspace publication slot before mutating that state. The already-admitted publication therefore completes before a competing invalidation returns. Once revocation wins, later commit admission fails through the revoked callback/fence checks.
- After publication waiting releases and reacquires the mutex, ordinary authority paths unlock and repeat filesystem validation. Registration discards discovery obtained before the wait, rediscovers outside the mutex, and rescans entries. Unbind relooks up the binding rather than retaining a slot/task pointer across a condition wait. These preserve identity and session-slot correctness across races.
- Condition waits release the global mutex. The slot belongs to one workspace, and unrelated-workspace state can progress while it is held. No filesystem I/O or subprocess wait was moved under the registry mutex.
- The publishing callback cannot complete until its guard releases: `endCallback` returns Busy for that ticket. Other callbacks may drain. Exclusive deinit rejects live publishing slots, publication waiters, outstanding callbacks, or discovery. Entries stay address-stable and retain handles throughout the guard lifetime.
- `markApplied` publishes the reserved generation once and only for the matching current guard ID. Aborting by releasing without marking does not advance generation. Stale or duplicate guards cannot update or release a later guard. Generation and registry-wide guard-ID overflow refuse admission before installing a slot; neither counter wraps. Waiter state is capped at 64 per workspace.

## Required consumer contract

The owner obtains its retained snapshot and performs preparatory validation before acquiring the guard. Acquire immediately before the filesystem commit phase. Hold the guard through that filesystem publication; call `markApplied` after the irreversible publication succeeds and before releasing; always release on both success and pre-publication failure, then end the callback. While held, use the previously retained snapshot and reserved generation and make no ordinary same-workspace Registry calls. Other-workspace calls remain supported.

A guard pins an already-admitted commit phase. Lease/task expiry or cancellation observed after guard admission waits for that phase to finish; the guard does not promise that an uninterruptible filesystem operation completes before a wall-clock or TTL boundary. Completed revocation prevents subsequent admission. External hostile same-UID filesystem changes remain outside the dedicated-writer operational guarantee.

## Regression assessment

The added tests use real threads and observe publication-condition waiter counts, rather than scheduler sleeps, to show that twelve mutation/expiry/retirement operations wait until guard release. Revocation, unbind, and disable cases execute actual handle-relative filesystem work while the conflicting operation waits. Tests also cover generation abort/apply behavior, duplicate/stale guards, counter exhaustion, owner callback completion, another worktree's progress, identity changes while a commit waits, concurrent unbind relookup, and bounded waiter refusal.

RED source records 13 actual assertion failures against the publication-slot scaffold before invalidation integration, with 38/51 isolation tests passing. The RED binary and log hashes match their recorded artifacts.

## Final evidence verification

Verified all four source hashes and all ten final run records in `evidence/T10/runs.json` against the actual source, binaries, and copied logs. Every record names final source `f8a3b24f44a02aa882ec72c170ad57296e02c815` and records exit 0; all hashes match. Debug and ReleaseSafe each pass 42 T10 tests plus 12 T02 tests (54/54 isolation) and eight separately executed lease tests. Contract verification and the non-test compilation proving test hooks have void type also pass. These are inspected implementer results, not reviewer reruns.

Verified the updated historical-log archive hash, all 32 archived member hashes, and the preserved copy of the prior marker-wave runtime object against its historical record. No historical result was substituted for a final-source PASS.

The coordinator changes remain confined to T10's registry, tests, and owned evidence. Frozen I08/I09 and core contracts are unchanged. Actual macOS/Windows runtime and combined T11 filesystem publication integration remain external gates; Linux T10/T02/module evidence alone does not establish those outcomes.
