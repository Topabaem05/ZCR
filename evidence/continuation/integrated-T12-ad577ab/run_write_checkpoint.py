import hashlib,json,os,subprocess,sys,time
from pathlib import Path
ROOT=Path('/workspace/scratch/3f4ab65dfb82')
repo=ROOT/'ZCR-work'; state=ROOT/'state/integration/write-ad577ab-debug'
state.mkdir()
for name in ['cache','global-cache','tmp','out']:(state/name).mkdir()
zig=ROOT/'toolchain/ziglang/zig'
def sha(p):
 with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def git(*args):return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
assert not git('status','--porcelain')
source=git('rev-parse','HEAD')
argv=[str(zig),'build','test','-Dtest-group=write','-Doptimize=Debug','-Dinstall-tests=true','--prefix',str(state/'out'),'--summary','all']
env={**os.environ,'ZIG_LOCAL_CACHE_DIR':str(state/'cache'),'ZIG_GLOBAL_CACHE_DIR':str(state/'global-cache'),'TMPDIR':str(state/'tmp'),'PYTHONDONTWRITEBYTECODE':'1'}
r={'source_commit':source,'tree':git('rev-parse','HEAD^{tree}'),'argv':argv,'cwd':str(repo),'env_overrides':{k:env[k] for k in ['ZIG_LOCAL_CACHE_DIR','ZIG_GLOBAL_CACHE_DIR','TMPDIR']},'toolchain_sha256':sha(zig),'driver_sha256':sha(__file__),'python':{'executable':sys.executable,'sha256':sha(sys.executable)},'source_files':{p:sha(repo/p) for p in git('ls-files','src','tests','config','contracts','build.zig','build.zig.zon','tools/ci').splitlines()},'started_unix':time.time()}
with (state/'stdout.log').open('wb') as out,(state/'stderr.log').open('wb') as err:
 result=subprocess.run(argv,cwd=repo,env=env,stdout=out,stderr=err,timeout=240)
r.update(exit_code=result.returncode,finished_unix=time.time(),stdout_sha256=sha(state/'stdout.log'),stderr_sha256=sha(state/'stderr.log'),binaries={p.name:{'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size} for p in (state/'out/bin').glob('*') if p.is_file()},source_unchanged=source==git('rev-parse','HEAD') and not git('status','--porcelain'))
sys.dont_write_bytecode=True;sys.path.insert(0,str(repo/'tools/ci'))
from storage_capture import capture
r['capture']=capture(state/'cache/.zig-cache/tmp',state/'storage')
r['capture_manifest_sha256']=sha(state/'storage/capture.json')
(state/'run.json').write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps({'source':source,'exit':r['exit_code'],'source_unchanged':r['source_unchanged'],'fixtures':r['capture']['fixture_count'],'files':len(r['capture']['files'])}))
sys.exit(result.returncode)
