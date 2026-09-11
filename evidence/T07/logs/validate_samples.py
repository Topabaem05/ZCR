import json, sys, glob, os, hashlib
from jsonschema import Draft202012Validator
wt, sdir = sys.argv[1], sys.argv[2]
resp = json.load(open(f"{wt}/contracts/response.schema.json"))
data = json.load(open(f"{wt}/contracts/data.schema.json"))
defs = data["$defs"]
kinds = {"read.json": "read", "batch_read.json": "batch_read", "batch_read_truncated.json": "batch_read", "failure.json": None}
out = {"schema_files": {p: hashlib.sha256(open(f"{wt}/contracts/{p}","rb").read()).hexdigest() for p in ["response.schema.json","data.schema.json"]}, "samples": []}
ok = True
for name, kind in kinds.items():
    raw = open(f"{sdir}/{name}", "rb").read()
    doc = json.loads(raw)
    errs = [e.message for e in Draft202012Validator(resp).iter_errors(doc)]
    if kind:
        errs += [f"data: {e.message}" for e in Draft202012Validator(defs[kind]).iter_errors(doc["data"])]
        data_len = len(json.dumps(doc["data"], ensure_ascii=False, separators=(",", ":")).encode())
        if data_len != doc["meta"]["returned_bytes"]:
            errs.append(f"returned_bytes {doc['meta']['returned_bytes']} != re-serialized data {data_len}")
    rec = {"sample": name, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(), "data_schema": kind, "errors": errs,
           "truncated": doc["truncated"], "complete": doc["complete"], "returned_bytes": doc["meta"]["returned_bytes"]}
    out["samples"].append(rec); ok = ok and not errs
out["status"] = "pass" if ok else "fail"
print(json.dumps(out, indent=2))
sys.exit(0 if ok else 1)
