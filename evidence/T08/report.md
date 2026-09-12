# T08 direct stdio MCP handoff

Implemented the owned MCP adapter and verified its native Linux behavior. Source commits are `e742d64fbd40bda605e932a5b4b300a986eea600`, `5482a7022fd20ce4b284b17ac48e7c93bfe33280`, and `48d2e8b61a83af444f0914379f8bc75f169413f3`. The authoritative source tree for these records is `32e0f1c7db627bfcdf45a8acf475b41e8be718bb`. Base: `9897f27a18c66c310ae6dda3ee854f7fdcdcfa3d`; contract digest: `8aa53314410fe471f0e070c522766684286f60e1ad4d9785c292bb709ea370a4`; task workspace incarnation: `4d6ae4ae-f3aa-4b20-b1c8-061147f3dfd2`.

## Behavior

The adapter negotiates only MCP2025-11-25, requires initialized notification before discovery/tool execution, preserves JSON-RPC string/integer IDs, keeps logical request IDs separate, and exposes exact trusted contract discovery entries for enabled capabilities. Patch/create stay disabled. Read, files, literal search, batch, status and health use the real engines and approved session. Every tool result is one text_v1 block, with no structuredContent/outputSchema. Tool failures are logical isError results; malformed transport/method traffic is a JSON-RPC error.

Raw16MiB/depth64/decoded duplicate keys and parser resource caps are checked before DOM allocation. Supported-tool unknown fields, required fields, numeric ranges and decoded UTF8 byte limits are additionally validated without allocations. A2MiB unknown argument is rejected while preserving its escaped RPC ID using only16KiB response allocation. Actual output serialization and waiting response credit remain bounded; omitted request defaults honor lower Config limits.

The transport owns a reader, one engine worker, a deadline watcher and one record writer. A16-entry work queue, four512KiB control blocks plus64KiB control-output credit reserved at connection startup, separate health/status control dispatch, and2MiB total queued/output-credit cap prevent unbounded output growth. Cancellation flags and monotonic deadlines are scoped to active requests in this Server session. Children and output drain before arenas/reservations are released. Engine, parser, input, output, CPU and directory/transient FD costs are reserved; traversal depth falls within the available FD profile and any engine limit remains visible in coverage.

## Validation

Native Debug and ReleaseSafe each pass15 adapter tests,10 codec tests and24 T07 batch/projection regression tests:98 actual executions. The6 evidence records were generated and verified against this clean source commit with this worktree's own evidence binary. Initial supported-version RED compiled and failed the intended assertion (exit1); its source snapshots, binary hash and output are retained. Tests include actual partial pipe input, escaped newlines, blocked stdout, request cancellation, deadline expiry, failed output cleanup, exact tool discovery, schema errors and real read/files/search under32MiB admission. Contract verification passes. See runs.json for exact binaries, commands, hashes and output artifacts.

## Integration and limits

- zcr_files/zcr_search currently require policy authority for the traversal root "."; narrower policies fail E_SCOPE rather than broadening authority.
- A single engine worker processes a bounded queue; batch reads may use up to two bounded internal workers.
- Parser resource limits additionally cap 4096 total object keys and 65536 JSON values.
- Actual CLI/host integration, macOS runtime and Windows runtime were not executed in this task.
- The launcher must provide validate_authority for registry/session expiry and root-identity validation; Config defaults support independently bound test fixtures.
- Trusted global/info excludes and the integrator core.Cancel deadline extension are pending root integration; T08 uses an independent per-request monotonic watcher and flags.

The root integrator owns CLI/build/shared contracts and will verify the actual integrated binary after applying the two source commits. No actual Codex/Claude host integration is claimed. No remote write occurred.

## Exports

- `Config{allocator,io,authorizer,session,generation,budget,tools_json,version,output_bytes,max_search_file_bytes,authority_context,validate_authority}`
- `Server.init(Config)!Server`
- `Server.respond(Allocator,[]const u8,core.Cancel)!?[]const u8`
- `Server.serve(std.Io.File,std.Io.File)!void`
- `Server.FrameContext{allocator,cancel}`
- `Server.serveFrame(std.Io,*core.Connection,core.BoundedBytes) core.ServeError!core.EncodedToolResult`
- `codec.preflight/parse/preflightToolArguments/rawRequestId/toolName`
- `framing.Decoder.init/push/finish; framing.RecordWriter.write`

## Review resolution

The complete independent initial review found three defects in source5482a70. Fix48d2e8b retires slots and clears reader-visible ID/raw/response slices under the mutex before freeing their arena; a deterministic lifecycle hook verifies that a new same-string-ID request is admitted while earlier teardown is paused. Public POSIX readiness polling observes stdout failure without requiring input EOF; the new kept-open-stdin test first failed the intended assertion and now passes. The control lane now uses backing and credit reserved at startup, so health/error responses need no new ordinary Budget reservation; a test exhausts all remaining32MiB credit, obtains health, then verifies ping still succeeds. Normal discovery also runs through that reserved control pool.

The optional Config retirement_context/before_tool_release fault hooks default to null. The direct transport requires libc and public POSIX poll; Windows serve explicitly reports Unsupported pending its platform gate. Final records are bound to the fixed clean source commit, not the earlier reviewed commit.
