import datetime, hashlib, json, os, pathlib, subprocess, sys, time
root = pathlib.Path('/workspace/scratch/3f4ab65dfb82/ZCR-T12')
state = pathlib.Path('/workspace/scratch/3f4ab65dfb82/state/T12')
zig = '/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig'
mode = sys.argv[1]
out = state / ('final-' + mode.lower())
out.mkdir(exist_ok=True)
env = os.environ.copy()
env.update(ZIG_GLOBAL_CACHE_DIR=str(out/'global-cache'), ZIG_LOCAL_CACHE_DIR=str(out/'cache'), TMPDIR=str(out/'tmp'))
cmd = [zig, 'build', 'test', '-Dtest-group=write', '-Doptimize='+mode, '-Dinstall-tests=true', '--prefix', str(out/'out'), '--summary', 'all']
def git(*args): return subprocess.check_output(['git','-C',str(root),*args],text=True).strip()
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
record = dict(command=cmd, cwd=str(root), environment={k:env[k] for k in ('ZIG_GLOBAL_CACHE_DIR','ZIG_LOCAL_CACHE_DIR','TMPDIR')}, source_commit=git('rev-parse','HEAD'), source_tree=git('rev-parse','HEAD^{tree}'), started=datetime.datetime.now(datetime.timezone.utc).isoformat(), toolchain=zig, toolchain_version=subprocess.check_output([zig,'version'],text=True).strip(), toolchain_sha256=sha(pathlib.Path(zig)))
start=time.monotonic()
with (out/'stdout.log').open('wb') as stdout, (out/'stderr.log').open('wb') as stderr:
    result=subprocess.run(cmd,cwd=root,env=env,stdout=stdout,stderr=stderr,timeout=300)
record.update(exit_code=result.returncode,elapsed_seconds=time.monotonic()-start,stdout_sha256=sha(out/'stdout.log'),stderr_sha256=sha(out/'stderr.log'),binaries={p.name:dict(path=str(p),sha256=sha(p),size=p.stat().st_size) for p in (out/'out'/'bin').glob('*')})
(out/'run.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))
sys.exit(result.returncode)
