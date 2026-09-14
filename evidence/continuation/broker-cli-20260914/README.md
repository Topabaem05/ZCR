# Broker CLI wiring: `zcr broker serve` and `zcr mcp --broker`

**Date:** 2026-09-14 · **Host:** Apple M2 8 CPU, macOS 26.6.2, Zig 0.16.0 · **Base:** `961a686` · **Source:** `0039251` (tree `568da60c…`) · **Task:** T01 integrator (docs/18 row 2, slice C)

## Decision and scope

The repository owner chose, in this session, to wire the broker CLI as the T01 integrator, to add no supervisor for now, and to record the T11 pre-publish hook only as a proposal. docs/02 §2.2 and docs/03 name the roles. docs/11 requires the token to travel by inherited handle or protected file, never argv. docs/14 §5 says a missing broker must not be started silently.

## Change (`0039251`)

- **`zcr broker serve --socket /abs --policy /abs --token-fd FD`** reads the token from descriptor FD (at least 3, 64 lowercase hex digits and an optional newline) and closes it. It binds one approved grant through the same launch path as standalone: approved policy, manifest, workspace identity, registry, session, authorizer and cache. The launch policy must set `broker_allowed`. It creates the UDS broker with one executor and one group budget, writes `zcr broker: listening domain=N` to stderr and serves until its stdin closes.
- **`zcr mcp --broker --socket /abs --domain N --token-fd FD`** relays stdio to a running broker. A missing broker or a wrong token exits 69 with a message that no broker was started and that `zcr mcp --standalone` is the alternative.
- **Refusals:** a `--token` on argv exits 64 (usage), and the token is not echoed. Standalone `zcr mcp` still refuses a policy that allows the broker. Writes stay disabled: the handshake keeps `"writes":false`, and patch/create remain unsupported.
- **Ownership:** `src/launch.zig` is assigned to T01 in `tasks/tasks.json` and `tasks/T01.md`. `build.zig` gives the launch module the broker and executor imports, registers `tests/broker_cli_test.zig` (group broker), and passes it the built `zcr` path. `DESIGNBOOK.html` and `MANIFEST.sha256` are regenerated, and `validate_bundle.py` passes.

## RED, GREEN, mutants

The tests run the built `zcr` binary as real subprocesses and pass the token through a pipe descriptor that is not close-on-exec.

RED before the change ([log](logs/red-br004-cli-debug.log)):

| Test | Failure |
|---|---|
| `BR-004 zcr broker serve and mcp --broker take the token from an inherited fd and serve reads only` | line 147: `try t.expect(std.mem.startsWith(u8, ready, marker));`  |
| `BR-004 zcr mcp --broker without a running broker refuses clearly and starts nothing` | line 205: `try expectExit(&bridge, 69);` expected 69, found 64 |
| `BR-004 zcr broker serve refuses a token on argv and a policy without broker_allowed` | line 216: `try t.expect(on_argv.term == .exited and on_argv.term.exited == 64);`  |

GREEN after the change: 6/6 steps succeeded; 3/3 tests passed; 0 leaks ([log](logs/green-br004-cli-debug.log)). This run was not quiet ([uptime](logs/green-br004-cli-debug.uptime)).

| Mutant | Change | Result |
|---|---|---|
| `ignore_broker_allowed` | broker role no longer requires broker_allowed | FAIL `BR-004 zcr broker serve refuses a token on argv and a policy without broker_allowed` at line 231: `try t.expect(std.mem.indexOf(u8, try readAll(a, broker.stderr.?), "refused") != null);` ([log](logs/mutant-ignore_broker_allowed.log)) |
| `bridge_zero_token` | bridge sends an all-zero token | FAIL `BR-004 zcr broker serve and mcp --broker take the token from an inherited fd and serve reads only` at line 179: `try t.expect(std.mem.indexOf(u8, responses, "2025-11-25") != null);` ([log](logs/mutant-bridge_zero_token.log)) |

## Records (`zcr-evidence/1`, verified after recording)

The runs started with no other zig process, no other evidence run and a 1-minute load average below the CPU count, at `2026-09-14T05:58:36Z start 14:58  up 18:25, 1 user, load averages: 6.60 11.90 24.70`. Other applications on the host were not stopped, and the load rose during the run.

| Record | Run | Binary | Result |
|---|---|---|---|
| [quiet-broker-debug](records/quiet-broker-debug.json) | broker group Debug (T01-broker-cli-test binary) | `5c93c0ff…` | exit 0; 10/10 steps succeeded; 31/31 tests passed; 0 leaks ([log](logs/quiet-broker-debug.log)) |
| [quiet-broker-releasesafe](records/quiet-broker-releasesafe.json) | broker group ReleaseSafe (T01-broker-cli-test binary) | `6f553ebb…` | exit 0; 10/10 steps succeeded; 31/31 tests passed; 0 leaks ([log](logs/quiet-broker-releasesafe.log)) |
| [quiet-dev-debug](records/quiet-dev-debug.json) | dev group Debug including the zcr CLI contract checks (T01-test binary) | `d07ee44b…` | exit 0; 8/8 steps succeeded; 19/19 tests passed; 0 leaks ([log](logs/quiet-dev-debug.log)) |
| [quiet-mcp-debug](records/quiet-mcp-debug.json) | mcp group Debug including MC-005 launch tests (T08-launch-test binary) | `2ce5337f…` | exit 0; 8/8 steps succeeded; 29/29 tests passed; 0 leaks ([log](logs/quiet-mcp-debug.log)) |

[records/runs.json](records/runs.json) binds each record to its log digest, `source_config_sha256` `4ae78ffd…` ([source-config.json](records/source-config.json)) and `corpus_sha256` `d928281c…` ([corpus.json](records/corpus.json)).

## Task identity

[task/manifest.json](task/manifest.json) (`zcr-task/1`, workspace `fs:16777232:649568737:16777232:649568735:16777232:647053195`, base `961a686`), [task/authorization.json](task/authorization.json) and [task/preflight.json](task/preflight.json) were issued before any edit. Fence 2 added `tasks/T01.md` and `DESIGNBOOK.html` before either was edited, because `validate_bundle.py` requires every owned path to appear in the task document and `render_book.py` renders that document. The fence-1 manifest is kept. Fence 3 raised `max_changed_files` from 16 to 64 after the evidence commit `dcc3c6b` brought the branch to 45 changed files; the limit had been sized for the code change alone. The fence-2 manifest is kept as `manifest-fence2.json`. `zcr-dev-guard scope` reported 0 violations at the start ([task/scope-start.json](task/scope-start.json)) and on the code commit ([task/scope-commit1.json](task/scope-commit1.json)).

## Limits

- One grant per broker process. Several grants, and a supervisor that rebinds sessions after a broker crash, are not implemented (no supervisor, by decision).
- The broker keeps the conservative launch budget: the first memory profile's inflight bucket and one CPU permit.
- Not verified: Linux and Intel Mac runtime (native CI on the PR), Windows named pipes, actual host (Claude Code) registration of the bridge.
