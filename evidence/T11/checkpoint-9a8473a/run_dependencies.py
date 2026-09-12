import os, subprocess, hashlib, json, pathlib, time, shlex
S=pathlib.Path("/workspace/scratch/3f4ab65dfb82/state/T11")
W=pathlib.Path("/workspace/scratch/3f4ab65dfb82/ZCR-T11")
Z="/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig"
env=os.environ.copy()
for key,value in [("ZIG_GLOBAL_CACHE_DIR","zig-global-cache"),("ZIG_LOCAL_CACHE_DIR","zig-local-cache"),("TMPDIR","tmp")]: env[key]=str(S/value)
head=subprocess.check_output(["git","rev-parse","HEAD"],cwd=W,text=True).strip()
def digest(p): return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def run(label,args,prefix=None):
    command=[Z]+args
    start=time.time()
    with (S/"logs"/(label+".log")).open("wb") as f: r=subprocess.run(command,cwd=W,env=env,stdout=f,stderr=subprocess.STDOUT)
    record={"label":label,"argv":command,"command":shlex.join(command),"cwd":str(W),"environment":{k:env[k] for k in ["ZIG_GLOBAL_CACHE_DIR","ZIG_LOCAL_CACHE_DIR","TMPDIR"]},"source_commit":head,"exit_code":r.returncode,"elapsed_seconds":round(time.time()-start,3),"log":str(S/"logs"/(label+".log")),"log_sha256":digest(S/"logs"/(label+".log")),"binaries":[]}
    if prefix:
        for binary in sorted((S/prefix/"bin").glob("*")): record["binaries"].append({"path":str(binary),"sha256":digest(binary)})
    (S/(label+".json")).write_text(json.dumps(record,indent=2)+"\n")
    print(label,r.returncode,flush=True)
    if r.returncode: print((S/"logs"/(label+".log")).read_text(),flush=True); raise SystemExit(r.returncode)
for mode in ["Debug","ReleaseSafe"]:
    for group in ["isolation", "fs", "io", "memory"]:
        label="dependency-"+group+"-"+mode.lower()
        run(label,["build","test","-Dtest-group="+group,"-Doptimize="+mode,"-Dinstall-tests=true","--prefix",str(S/("out-"+label)),"--summary","all"],"out-"+label)
run("verify-contracts",["build","verify-contracts","--summary","all"])
run("runtime-gate-compile",["build-exe","-OReleaseSafe","-lc","--dep","zcr_fs_edit","--dep","zcr_core","-Mroot="+str(S/"runtime-gate.zig"),"--dep","zcr_core","--dep","zcr_policy","--dep","zcr_workspace","-Mzcr_fs_edit=src/fs/edit.zig","-Mzcr_core=src/core/types.zig","--dep","zcr_core","-Mzcr_policy=src/policy/capability.zig","--dep","zcr_core","--dep","zcr_policy","-Mzcr_workspace=src/workspace/registry.zig","-femit-bin="+str(S/"runtime-gate")])
run("evidence-tool-compile",["build-exe","-OReleaseSafe","-lc","--dep","zcr_core","-Mroot=tools/dev/evidence.zig","-Mzcr_core=src/core/types.zig","-femit-bin="+str(S/"zcr-dev-evidence")])
