# T08 independent review — final fix wave approved

**Current spec verdict: APPROVE for the scoped T08 source changes. Current quality verdict: APPROVE.** All three initial findings below are closed by `48d2e8b61a83af444f0914379f8bc75f169413f3`. The complete delta `5482a70..48d2e8b` was independently reviewed. Final evidence commit is `774ccfe8b18114d3f7054a8db5c265f6c05b2437`; the worktree is clean. Actual launcher/schema integration, trusted excludes, the shared core deadline extension and unexecuted host/platform gates remain separate integrator work, not unresolved findings in this review.

## Final resolution

| Finding | Resolution | Targeted evidence |
|---|---|---|
| R1 — request-ID lifetime | `release` changes state to `retiring` and clears ID/raw/response references while holding the same mutex as ID readers. Cleanup starts only after existing readers release that lock, and `acquire` cannot reuse the slot until cleanup finishes and state becomes `free`. Control backing stays alive through all thread joins. | Gated retirement test admits another same-string-ID request while the old slot is detached and teardown is paused. |
| R2 — output-failure shutdown | The exclusive stdin reader now checks failure between public POSIX `poll` calls with a 20 ms timeout. On readiness the sole reader consumes available pipe bytes; EOF/error also wakes the path. Output failure no longer requires peer EOF, and the input loop reaches child joins and reservation release. | Open-input-pipe/read-only-output test asserts shutdown occurs before closing input. |
| R3 — minimum control budget | Four 512 KiB control backing buffers and 64 KiB output credit are reserved at connection startup. Control acquisition uses its own fixed buffer rather than reserving fresh ordinary Budget bytes. Buffers and the startup reservation outlive all slots and are released on normal or failed shutdown; initialization failures unwind their allocations. | Native 32 MiB pressure test reserves all remaining ordinary credit, receives health successfully, releases pressure, then receives ping. |

No new blocker was found. Windows is explicitly unsupported for direct serve pending its platform work; no runtime portability claim is inferred from POSIX source review. Existing slow-output, cancellation, native-budget and codec/regression tests remain relevant, and no broad suite was rerun by this reviewer.

## Final independent artifact checks

The source commit resolves to recorded tree `32e0f1c7db627bfcdf45a8acf475b41e8be718bb`. Current bytes of all four owned source/test files exactly match that commit. All six recorded binary SHA-256 values and all six output-log SHA-256 values were independently recomputed and match. Every record identifies the final source commit/tree. Recorded suites comprise 15 MCP, 10 codec and 24 T07 tests in each of Debug and ReleaseSafe (98 executions total); this review verified artifacts rather than rerunning those suites.

| Final source file | SHA-256 |
|---|---|
| `src/protocol/mcp.zig` | `953cba2a4ed12fe5071ff65c1b1af6e0f480da6b8e956c53fde1efb728942264` |
| `src/protocol/framing.zig` | `893d41b3fbed837ec856596bbe9ba04ec5d22d8a122b00fb39f1231197e20aeb` |
| `src/protocol/codec.zig` | `f3af32c8682d0afa0b39bcbc39edeb7bd92beef8946fc0c335671c90444188c0` |
| `tests/t08_test.zig` | `b136134593756a6707b6699d67157b2a4c41148dae831e5dde151fb15e989be2` |

## Historical initial review — findings now closed

Scope: `src/protocol/mcp.zig`, `src/protocol/framing.zig`, `src/protocol/codec.zig`, `tests/t08_test.zig`, task T08 and shared AGENTS/docs08/docs09/docs17 contracts. Reviewed source commits `e742d64fbd40bda605e932a5b4b300a986eea600` and `5482a7022fd20ce4b284b17ac48e7c93bfe33280`, source tree `29f2b6c66a06692df151157d8b37a3edcd1117a0`. Integrator build/CLI changes are excluded. No source edits or broad test reruns were performed.

**Spec verdict: REQUEST CHANGES.** The adapter implements the pinned version negotiation, policy-bound enabled discovery, disabled patch/create, real I03-I06 engine calls, text_v1 output, strict syntax/tool preflight and request-local cancellation. However, failed-output shutdown does not drain while input remains open, and the promised independent minimum control budget is not reserved.

**Quality verdict: REQUEST CHANGES.** A concrete request-ID use-after-free race exists at slot release. The current happy-path and finite-input output-failure tests do not cover it or the open-input shutdown failure. The following is the complete initial fix wave; no additional source blocker was found in framing, codec validation, result schema construction or engine authority dispatch.

## R1 — P1: slot release frees IDs while duplicate-ID readers can still access them

Locations: `mcp.zig:689-695` (`Transport.release`), `mcp.zig:628-632` (duplicate active-ID scan), `mcp.zig:782-786` (writer release).

`release` destroys the slot's arena and releases its reservation before locking the transport mutex or changing the slot state. A completed writer leaves that state as `writing` throughout arena destruction. Meanwhile, the input thread holds the transport mutex while scanning `queued`, `running`, `ready` and `writing` slots and invokes `codec.requestId(other.id)` / `id.eql(other_id)`. `other.id` borrows memory from the arena just freed: strings require comparison, and retained integer lexemes also require parsing.

Concrete interleaving: request A with a string ID finishes writing; its writer unlocks at line 785 and begins `release`. A concurrent request B enters the duplicate-ID scan at line 628. A's state is still `writing`, so B dereferences A's freed ID at lines 631-632. This is possible with ordinary sequential client requests because A's response reaches the client before arena teardown finishes. Existing allocator timing can hide the race.

Fix by removing the slot from all ID-reader-visible states under the same mutex before freeing, while keeping it unavailable for reuse until destruction completes, or by protecting destruction and all ID reads with one synchronization regime. A deterministic regression should gate an allocator/free boundary after response completion and overlap another request's ID scan; assert no freed-memory access and no slot reuse before cleanup ends.

## R2 — P1: stdout failure cannot interrupt the open stdin reader

Locations: `mcp.zig:524-541` (blocking input loop), `mcp.zig:774-780` (output error), `mcp.zig:545-555` (cleanup reachable only after input loop).

An output failure sets `failed`, cancels request flags and wakes the transport condition. The input owner is blocked in `input.readStreaming`, not on that condition; no cancellation/wakeup path reaches it. `run` cannot join children or release the reserved frame/parser/slot memory until another input read returns.

Exact bounded reproduction: create an input pipe, keep its writer open, and pass a read-only file descriptor as `Server.serve`'s output. Send one valid initialize frame followed by a newline, then send nothing else. The writer fails deterministically with a write error, but the reader blocks waiting for more bytes forever. Closing the input writer later allows cleanup, demonstrating that shutdown incorrectly depends on peer EOF. A partial next frame produces the same failure. A CLI subprocess equivalent uses an open stdin pipe and read-only stdout FD, with a deadline on process exit.

Provide an explicit input wake/cancellation mechanism on transport failure, then join and release children without requiring client EOF. The existing test at `tests/t08_test.zig:298-321` uses a finite regular input file and therefore cannot expose this case. Distinguish actual output error from a client merely reading slowly; this finding is about failure cleanup, not requiring arbitrary slow writes to be abandoned.

## R3 — P2: dedicated control slots do not reserve control memory

Locations: `mcp.zig:493-501` (initial persistent credit), `mcp.zig:652-675` (`acquire`), `mcp.zig:600-610` (admission-error handling).

Control slots are separate array entries, but acquiring one still reserves fresh parser/scratch memory from the ordinary shared Budget at line 675. Initial transport credit does not reserve the per-control arena allowance. When normal admitted owners exhaust remaining credit, health and minimal error responses cannot acquire control memory. A diagnostic call takes the non-tool branch and propagates `ResourceExhausted` out of dispatch, terminating the input loop instead of retaining a minimum response path.

Deterministic pressure reproduction: start the transport with the native 32 MiB Budget and finish handshake. Using another legitimate owner of that shared Budget, reserve its remaining available byte credit temporarily; send `tools/call` for `zcr_health`. `acquire(true, raw.len)` fails despite all four control slots being free, and `serve` stops accepting input. The same condition can occur when engine/request reservations leave less than the control arena's required credit. No malformed request or queue-limit bypass is needed.

Docs08 section 8 explicitly requires a small reserved global control budget for minimum health/cancel responses. Reserve that capacity before ordinary admission can consume it, or provide an already-credited fixed-buffer minimal control/error path. Test that byte pressure yields a bounded response and that the session still accepts requests after pressure is released. Cancellation itself currently needs no additional slot allocation once its frame is decoded, which is good; it does not remedy health/error admission terminating the reader first.

## Reviewed behavior and limits

- Framing keeps one newline-delimited JSON record, handles partial records and escaped newlines, rejects a record larger than 16 MiB before DOM allocation, and drains an oversized record to its delimiter. One writer serializes record and delimiter.
- Codec preflight validates UTF-8, JSON grammar, nesting, decoded duplicate keys, strict integer lexemes and bounded parser tables without DOM allocation. Supported enabled tool schemas are checked before decoding their argument strings. The additional 4096-total-key/65536-value resource caps are explicit.
- Normal execution reserves engine bytes/FDs/CPU, applies lowered Config limits, uses checked policy-bound capabilities and invokes the supplied authority validator before every tool execution. Root must supply the validator for expiry/root identity; this is accurately disclosed in the handoff.
- Success output checks the complete serialized MCP content including text escaping, enforces bounded backlog credit, and uses one text_v1 block without duplicated structuredContent. The response envelope and diagnostic fields examined match the frozen response schema. Root is separately executing actual CLI/schema validation.
- Cancellation matches IDs only inside this Transport's own slot array. Deadline watcher flags queued/running tool requests; result handling distinguishes expiry from ordinary cancellation. There is no cross-session request map.
- No falsely supported writes, actual host integration or Mac/Windows runtime claims were found. The worker reports native Debug/ReleaseSafe adapter/codec/T07 runs, with external-host and platform gates explicitly NOT_RUN.

## Source snapshot and evidence status

SHA-256 measured for the reviewed source:

| File | SHA-256 |
|---|---|
| `src/protocol/mcp.zig` | `e74a26d7a456210559a7570f6422b7e3bdb542ad8d751bb999e94f526bca8ff5` |
| `src/protocol/framing.zig` | `893d41b3fbed837ec856596bbe9ba04ec5d22d8a122b00fb39f1231197e20aeb` |
| `src/protocol/codec.zig` | `f3af32c8682d0afa0b39bcbc39edeb7bd92beef8946fc0c335671c90444188c0` |
| `tests/t08_test.zig` | `d7cd3f36a842e8ba720b1fd85f7f021a715df04424b8e9c70d472cbcf97886b7` |

Worker handoff/runs were inspected while being finalized. They identified source5482a702 and 12 adapter + 10 codec + 24 dependency tests per optimization mode. A subsequent independent artifact-hash check encountered the evidence directory being refreshed, so this review makes no independent final-binary provenance claim; verify replacement records after the fix wave. Source findings do not depend on evidence finalization. Complete finding list was sent to root and T08 owner before yielding.
