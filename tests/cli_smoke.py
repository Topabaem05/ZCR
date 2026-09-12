#!/usr/bin/env python3
"""Native subprocess/stdio integration fixture; this is not a Codex/Claude run.

Run with --binary ABS --state ABS from any directory. Fixtures, transcripts and
logs live under state. jsonschema is a development-only dependency.
"""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import time
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


class Client:
    def __init__(self, command, env, transcript):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env)
        self.poll = selectors.DefaultSelector()
        self.poll.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.transcript = transcript

    def send(self, frame):
        self.transcript.append({"send": frame})
        self.process.stdin.write(encoded(frame) + b"\n")
        self.process.stdin.flush()

    def receive(self):
        end = time.monotonic() + 10
        while b"\n" not in self.buffer:
            left = end - time.monotonic()
            if left <= 0 or not self.poll.select(left):
                raise AssertionError("MCP response deadline elapsed")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise AssertionError("MCP stdout ended before response")
            self.buffer += chunk
            if len(self.buffer) > 3 * 1024 * 1024:
                raise AssertionError("MCP output exceeds fixture bound")
        line, self.buffer = self.buffer.split(b"\n", 1)
        frame = json.loads(line)
        self.transcript.append({"receive": frame})
        return frame

    def request(self, identifier, method, params=None):
        frame = {"jsonrpc": "2.0", "id": identifier, "method": method}
        if params is not None:
            frame["params"] = params
        self.send(frame)
        response = self.receive()
        assert response["jsonrpc"] == "2.0" and response["id"] == identifier, response
        return response

    def close(self, success):
        self.process.stdin.close()
        if not success:
            self.process.kill()
        try:
            code = self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise
        error = self.process.stderr.read().decode(errors="replace")
        self.poll.close()
        self.process.stdout.close()
        self.process.stderr.close()
        if success:
            assert code == 0 and not error, (code, error)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--state", type=Path, required=True)
    args = ap.parse_args()
    binary, state = args.binary.resolve(), args.state.resolve()
    state.mkdir(parents=True, exist_ok=True)
    repo = state / "fixture"
    repo.mkdir()  # Refuse reused fixtures instead of cleaning existing user data.
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "ZCR fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
           "GIT_COMMITTER_NAME": "ZCR fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
    for key in tuple(env):
        if key.startswith("GIT_") and key not in {"GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
                "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"}:
            del env[key]
    def git(*argv):
        subprocess.run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "init.templateDir=",
                        "-c", "commit.gpgSign=false", "-C", str(repo), *argv], env=env, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    git("init", "-q", "-b", "main")
    (repo / "a.txt").write_text("alpha\n한글 needle\nomega\n")
    (repo / "ignored.txt").write_text("needle hidden by trusted Git excludes\n")
    (repo / "global-hidden.txt").write_text("needle hidden by explicit global excludes\n")
    global_exclude = state / "global-exclude"
    global_exclude.write_text("global-hidden.txt\n")
    (repo / ".git/info").mkdir()
    (repo / ".git/info/exclude").write_text("ignored.txt\n")
    git("add", "a.txt")
    git("commit", "-q", "-m", "fixture")
    identity = json.loads(subprocess.check_output([str(binary), "workspace-id", "--root", str(repo)],
                                                  env=env, timeout=10))
    manifest = {"schema_version": "zcr-task/1", "state": "active", "task_id": "T08",
                **identity, "fence": 1,
                "expires_at": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "read_paths": ["."], "write_paths": [], "immutable_paths": [],
                "operations": ["read", "enumerate", "search", "batch_read", "status", "health"],
                "max_changed_files": 0}
    manifest_path = state / "manifest.json"
    policy_path = state / "policy.json"
    policy = {"status": "approved", "root": str(repo), "task_manifest": str(manifest_path),
              "global_exclude": str(global_exclude)}
    manifest_path.write_bytes(encoded(manifest))
    policy_path.write_bytes(encoded(policy))
    command = [str(binary), "mcp", "--standalone", "--policy", str(policy_path)]
    transcript, checks = [], []
    envelope_schema = json.loads((ROOT / "contracts/response.schema.json").read_text())
    data_schemas = json.loads((ROOT / "contracts/data.schema.json").read_text())["$defs"]
    client = Client(command, env, transcript)
    success = False
    try:
        init = client.request(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                              "clientInfo": {"name": "native-fixture", "version": "1"}})
        assert init["result"]["protocolVersion"] == "2025-11-25", init
        client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        advertised = client.request(2, "tools/list")["result"]["tools"]
        assert {t["name"] for t in advertised} == {"zcr_" + op for op in
                   ("read", "files", "search", "batch_read", "status", "health")}
        checks.append("explicit approved read-only tool advertisement")
        cases = [("read", {"path": "a.txt"}), ("files", {}), ("search", {"literal": "needle"}),
                 ("batch_read", {"items": [{"item_id": "a", "path": "a.txt"}]}),
                 ("health", {}), ("status", {})]
        for i, (tool, arguments) in enumerate(cases, 3):
            result = client.request(i, "tools/call", {"name": "zcr_" + tool, "arguments": arguments})["result"]
            assert len(result["content"]) == 1 and result["content"][0]["type"] == "text", result
            assert "structuredContent" not in result, result
            envelope = json.loads(result["content"][0]["text"])
            Draft202012Validator(envelope_schema).validate(envelope)
            assert envelope["ok"] is True and envelope["complete"] is True, envelope
            Draft202012Validator(data_schemas[tool]).validate(envelope["data"])
            assert envelope["meta"]["returned_bytes"] == len(encoded(envelope["data"])), envelope
            if tool in ("files", "search"):
                assert "ignored.txt" not in encoded(envelope["data"]).decode(), envelope
                assert "global-hidden.txt" not in encoded(envelope["data"]).decode(), envelope
            if tool == "health":
                assert envelope["data"]["usable_cpu_permits"] == 1, envelope
            checks.append("stdio/schema/byte-count " + tool)
        for i, arguments in enumerate(({"path": "../outside"}, {"path": "a.txt", "root": "/"}), 20):
            refused = client.request(i, "tools/call", {"name": "zcr_read", "arguments": arguments})
            assert "error" in refused or refused.get("result", {}).get("isError") is True, refused
        checks.append("model path and root authority refusal")
        success = True
    finally:
        (state / "transcript.json").write_bytes(encoded(transcript))
        client.close(success)
    for name, change in [("unbound", {"workspace_id": None}), ("wrong-workspace", {"workspace_id": "fs:0:0:0:0:0:0"}),
                         ("wrong-base", {"base_commit": "0" * 40}), ("wrong-contract", {"contract_digest": "0" * 64}),
                         ("expired", {"expires_at": "2000-01-01T00:00:00Z"}), ("zero-fence", {"fence": 0})]:
        manifest_path.write_bytes(encoded({**manifest, **change}))
        result = subprocess.run(command, input=b"", capture_output=True, env=env, timeout=10)
        (state / (name + ".stderr")).write_bytes(result.stderr)
        assert result.returncode == 69 and result.stdout == b"" and b"startup refused" in result.stderr, (name, result)
        checks.append("startup refuses " + name)
    manifest_path.write_bytes(encoded(manifest))
    def initialized():
        session = Client(command, env, transcript)
        response = session.request(101, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                   "clientInfo": {"name": "binding-fixture", "version": "1"}})
        assert "result" in response, response
        session.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return session
    def health(session):
        reply = session.request(102, "tools/call", {"name": "zcr_health", "arguments": {}})["result"]
        value = json.loads(reply["content"][0]["text"])
        Draft202012Validator(envelope_schema).validate(value)
        return value
    def scope_refused(value):
        assert value["ok"] is False and value["error"]["code"] == "E_SCOPE", value
    for name, path in (("Git info/exclude", repo / ".git/info/exclude"), ("global excludes", global_exclude)):
        session, ok = initialized(), False
        try:
            assert health(session)["ok"] is True
            replacement = path.with_name(path.name + ".replacement")
            replacement.write_bytes(path.read_bytes())
            replacement.replace(path)
            scope_refused(health(session))
            checks.append("atomic replacement refuses stale " + name + " binding")
            ok = True
        finally:
            session.close(ok)
    # Creation of an initially absent trusted file also requires a fresh binding.
    info_exclude = repo / ".git/info/exclude"
    info_exclude.unlink()
    session, ok = initialized(), False
    try:
        assert health(session)["ok"] is True
        info_exclude.write_text("ignored.txt\n")
        scope_refused(health(session))
        checks.append("creation refuses an initially absent trusted exclude binding")
        ok = True
    finally:
        session.close(ok)
    # Expiry is revalidated throughout the session, not just at process startup.
    expires = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=3)
    manifest_path.write_bytes(encoded({**manifest, "expires_at": expires.strftime("%Y-%m-%dT%H:%M:%SZ")}))
    session, ok = initialized(), False
    try:
        assert health(session)["ok"] is True
        end = time.monotonic() + 5
        while True:
            value = health(session)
            if not value["ok"]:
                scope_refused(value)
                break
            assert time.monotonic() < end, "expired session remained authorized"
            time.sleep(0.05)
        checks.append("live session expiry revokes subsequent tools")
        ok = True
    finally:
        session.close(ok)
    manifest_path.write_bytes(encoded(manifest))
    (state / "transcript.json").write_bytes(encoded(transcript))
    report = {"scope": "native subprocess fixture; actual Codex/Claude integration NOT_RUN",
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "checks": checks,
              "transcript_sha256": hashlib.sha256((state / "transcript.json").read_bytes()).hexdigest()}
    (state / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"checks_passed": len(checks), "scope": report["scope"]}))


if __name__ == "__main__":
    main()
