# Trusted launcher and native deadline integration review — source approved

**Current spec verdict: APPROVE for source `b5face3`. Current quality verdict: APPROVE for the reviewed source.** The complete launcher/binding and deadline fixes since `14e49c1` were independently reviewed. L1 and L2 below are closed. Final root-run Debug/ReleaseSafe and final-source CLI evidence is still being produced; source approval does not substitute for those pending execution records or actual external-host/platform gates.

## Resolution at b5face3

| Item | Reviewed resolution |
|---|---|
| L1 — live CPU sentinel | Launcher now sets the conservative CPU cap to one. CLI smoke explicitly asserts `health.data.usable_cpu_permits == 1` and continues to exercise batch read under that cap. |
| L2 — deadline misclassification | Scheduler admission uses `check()` before resource inspection and again under the queue mutex. Batch admission, post-join and pre-return checks preserve the exact interrupt reason. Its internal stop boolean remains safe because an expired inherited deadline is checked again after all children join, before cancellation-only bookkeeping is returned. MCP admission and successful-result guards also propagate `DeadlineExceeded`. |
| Trusted excludes | Explicit global and Git info/exclude file handles are passed into both enumeration and search. Their bindings and optional global parent handle outlive server work/output. No-follow regular-file initialization, retained file/parent identity validation and reverse-order unwinding preserve authority and ownership; replacement or creation of an initially absent binding requires a new session. |
| Retained startup identity | Startup compares both the fingerprint and base HEAD from the exact registry snapshot retained for service, closing the known two-discovery mismatch. |
| Authority publication barrier | MCP revalidates supplied authority after engine execution and before returning successful data. A new callback test permits the first check and refuses the second, asserting `E_SCOPE`. |

The new targeted tests cover native deadline-only scheduler refusal without ownership transfer, native batch deadline refusal, native MCP `E_DEADLINE`, and post-execution authority refusal. Root reported the three native deadline tests first reproduced the intended misclassification. This reviewer inspected their assertions and cleanup but did not rerun the suites. The core helper itself remains unchanged and correct.

The earlier CLI fixture at `state/integration/cli-bindings-debug-2` records 18 passed checks, including CPU1, schemas/byte counts, trusted exclude replacement/creation and live expiry. Its transcript SHA-256 was independently recomputed and matches. As root specified, that binary covers the launcher fix corresponding to `5d3731b`, not the later `b5face3` deadline changes; final-source CLI execution remains pending here.

All reviewed current source bytes were checked against `b5face3` and match:

| File | SHA-256 |
|---|---|
| `src/launch.zig` | `62d4aa64ffbe3d7aac328d32e871fa8b83ff488b4ecf87ba178e046191586672` |
| `src/launch_ignore.zig` | `58eff3d9eca3c2fe4b8a4192c1c66596333b14f6e5a2a879ab201bc55d59b127` |
| `src/core/types.zig` | `339def811cdbf97f47184ce86d5577342ab13cba1ba65b68702ab16b736b2ddf` |
| `src/batch/read.zig` | `a0627a93212db8d864deb37037a9b4c27e5bee4948f4602ed4c9da2c7339e6e6` |
| `src/scheduler/executor.zig` | `755e95087f966237fa255a392876f39638be80ac9fa42cbeacf55ac38e8d7aae` |
| `src/protocol/mcp.zig` | `4d01714480e503d94e4f4008c5c44d224b912777d9fb021601e9a0ff1d7747d2` |
| `tests/cli_smoke.py` | `494268b7d807d1b0b98ab07c26b88c8fe7495387235af5712aa3d5fb3401213a` |

No new concrete blocker was found in this fix wave. No source files were edited by the reviewer.

## Historical initial review — L1 and L2 now closed

Initial reviewed integration HEAD: `14e49c1` in `ZCR-work`. Scope: `src/launch.zig`, `src/main.zig`, the native `Cancel` deadline addition, launch/timing tests and `tests/cli_smoke.py`, with shared policy/registry/budget contracts read for context. No source edits or broad test reruns were performed. Root's already-known trusted-exclude wiring and retained registry HEAD comparison are acknowledged pending fixes, not rediscovered findings.

**Initial spec verdict: REQUEST CHANGES. Initial quality verdict: REQUEST CHANGES.** Two additional integration issues were sent to root. The launcher ownership, explicit authority inputs, strict bounded JSON handling and the core deadline helper itself otherwise appear coherent. Root has already agreed to fix L1 and its working candidate now contains the proposed cap; final source and evidence re-review is pending.

## L1 — P2: byte-budget CPU sentinel is exposed as the live scheduler capacity

Location at reviewed HEAD: `src/launch.zig:178`, with `src/memory/budget.zig:60` and `src/protocol/mcp.zig:184,197` as consumers/context.

The launcher passes `memory.capsFor(..., .inflight)` directly into the live Budget. That helper deliberately sets CPU to `maxInt(u8)` (255), because it expects the scheduler to enforce the actual CPU cap. The direct MCP transport reports `budget.caps.cpu` as health's `usable_cpu_permits`, and chooses batch workers from `min(2, budget.caps.cpu)`. The CLI therefore reports 255 usable permits despite owning one engine worker and at most two batch workers; on a host whose hardware ceiling is one, two batch workers also exceed the promised ceiling.

Reproduction: launch an approved native standalone session and call `zcr_health`; inspect `data.usable_cpu_permits` (255). This is not a memory-budget measurement or a real available CPU count. The smoke test validates only the field's schema, which does not catch this false capacity report.

Root's agreed conservative fix is `launch_caps.cpu = 1` until T16/T17 runtime signals are integrated. Add an actual CLI smoke assertion that health reports exactly one permit and retain successful native batch behavior under that cap. The current uncommitted candidate contains the cap; closure awaits the final candidate and checks.

## L2 — P2: some existing native consumers flatten the new deadline into cancellation

Locations at reviewed HEAD: `src/scheduler/executor.zig:92`, `src/batch/read.zig:277` and its worker/finish interruption bookkeeping at `435-438`/`318`, plus `src/protocol/mcp.zig` admission/publication guards using `cancel.isRequested()` (lines 168 and 132 before the pending wiring change).

The new core helper correctly makes `isRequested()` true for either an atomic cancellation request or an expired deadline, and `check()` preserves the reason. Consumers that still translate every true `isRequested()` to `error.Cancelled` now misclassify deadline-only tokens.

Deterministic reproduction: initialize an atomic flag to false and derive `expired = Cancel{ .requested = &flag }.withTimeout(io, 0)`. `expired.check()` correctly returns `DeadlineExceeded`. Submit a valid job carrying `expired` to Executor, or supply it to a valid native Batcher / initialized MCP FrameContext. The old guards return `Cancelled` / logical `E_CANCELLED` despite no cancellation producer ever setting the flag. Their public error sets already include `DeadlineExceeded`. A batch deadline that expires while awaiting the next chunk can likewise set its cancellation-only bookkeeping and return the wrong reason.

Use `check()` at public admission and result-publication boundaries, and retain the exact interruption reason through batch drain rather than a boolean that always becomes cancellation. Add focused API-level deadline-only assertions; the two current timing tests check the helper only and cannot expose consumer misclassification. This finding concerns native deadline propagation; the stdio transport's separate watcher already tracks `expired` and can preserve `E_DEADLINE` independently.

## Positive checks and known integration work

- Launch JSON files have a 1 MiB read bound, JSON syntax/depth/duplicate validation and strict typed decoding; unknown fields and unsupported launch modes are rejected. Approved active state, exact task identifier shape, nonzero fence, unexpired UTC timestamp, contract digest, operation whitelist/uniqueness and relative path policy are validated before serving.
- Startup binds filesystem identity, base commit and approved policy into a fresh registry workspace/session and an immutable policy digest. The authority callback validates the stored registry session and expiry on each tool call. The retained snapshot HEAD comparison already being added by root closes the known two-discovery mismatch.
- The launcher retains parsed configuration, policy arena, registry handles, authorizer, budget and callback userdata across the entire blocking `Server.serve` lifetime. Teardown runs after transport children and output drain. Error unwinding preserves the same ownership order.
- CLI protocol output is isolated from startup diagnostics. Unsupported broker/write/extra-root/network/exec modes are explicitly refused. The native subprocess fixture clearly disclaims actual Codex/Claude host integration and tests response/data schemas, byte counts and startup refusal cases.
- Core `Cancel.withTimeout` uses the monotonic clock, saturating timestamp addition and minimum inherited deadline. `check` correctly gives explicit atomic cancellation precedence while preserving deadline-only failures; borrowed flag and Io lifetimes are documented. No separate helper implementation bug was found.
- Root's in-progress `launch_ignore.zig` was inspected opportunistically: no-follow regular-file binding, retained parent/file identity validation, owned ignore handles and startup/error teardown lifetimes look appropriate. Its final committed source and native tests still need the requested re-review. The new post-execution authority check is appropriate when expiry or binding replacement occurs during engine I/O.

This initial review remains bound to `14e49c1`; it does not claim final candidate test results or artifact provenance.
