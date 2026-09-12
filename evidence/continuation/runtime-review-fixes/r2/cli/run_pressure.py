import hashlib, json, subprocess, sys
binary, proof_path = sys.argv[1:]
policy = "/workspace/scratch/3f4ab65dfb82/state/runtime-review-fixes/cli/policy.json"
p = subprocess.Popen([binary, "mcp", "--standalone", "--policy", policy], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
records = []
def send(obj, receive=True):
    p.stdin.write(json.dumps(obj, separators=(",", ":")) + "\n")
    p.stdin.flush()
    if not receive:
        return None
    line = p.stdout.readline()
    if not line:
        raise RuntimeError("missing response: " + p.stderr.read())
    return json.loads(line)
def read(req_id, path, output=262144):
    rpc = send({"jsonrpc":"2.0","id":req_id,"method":"tools/call","params":{"name":"zcr_read","arguments":{"path":path,"output_bytes":output}}})
    logical = json.loads(rpc["result"]["content"][0]["text"])
    records.append({"id":req_id,"path":path,"output_bytes":output,"ok":logical["ok"],"error":logical.get("error"),"cache":logical.get("meta",{}).get("cache")})
    return logical
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"pressure-regression","version":"1"}}})
send({"jsonrpc":"2.0","method":"notifications/initialized"}, False)
assert read(2, "tiny.txt", 2097152)["ok"]
request_id = 3
for i in range(16):
    for _ in range(2):
        assert read(request_id, f"warm{i}.txt")["ok"]
        request_id += 1
for _ in range(2):
    result = read(request_id, "tiny.txt", 2097152)
    assert result["ok"], result
    request_id += 1
p.stdin.close()
rc = p.wait(timeout=10)
stderr = p.stderr.read()
proof = {"source_commit":"5ad79b17c54e0ee28288f67344b208d04154f6a0","binary":binary,"binary_sha256":hashlib.sha256(open(binary,"rb").read()).hexdigest(),"exit":rc,"stderr":stderr,"records":records}
open(proof_path,"w").write(json.dumps(proof,indent=2,sort_keys=True)+"\n")
assert rc == 0, rc
print(json.dumps({"checks":len(records),"final":records[-2:],"binary_sha256":proof["binary_sha256"]},sort_keys=True))
