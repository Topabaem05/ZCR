import hashlib,json,os,sys,tarfile,traceback
from pathlib import Path
ROOT=Path('/workspace/scratch/3f4ab65dfb82'); repo=ROOT/'ZCR-work'; state=ROOT/'state/i1'; state.mkdir()
sys.dont_write_bytecode=True; sys.path.insert(0,str(repo/'tools/ci'))
from native import Run,digest
from storage_capture import capture
run=Run(repo,state,'x86_64-linux','local-restricted-container')
run.env.update(PYTHONPATH=str(ROOT/'toolchain/doc-deps'))
zig=ROOT/'toolchain/ziglang/zig'
run.report['driver']={'path':str(Path(__file__).resolve()),'sha256':digest(__file__)}
run.report['toolchain']={'path':str(zig),'sha256':digest(zig)}
try:
 before=run.source_snapshot('before')
 assert not before['git_status']
 run.command('zig-version',[zig,'version'])
 for mode,short in [('Debug','D'),('ReleaseSafe','S')]:
  s=state/short
  for x in ['c','g','t','o']:(s/x).mkdir(parents=True)
  env={**run.env,'ZIG_LOCAL_CACHE_DIR':str(s/'c'),'ZIG_GLOBAL_CACHE_DIR':str(s/'g'),'TMPDIR':str(s/'t'),'TMP':str(s/'t'),'TEMP':str(s/'t')}
  run.report.setdefault('mode_env',{})[mode]={k:env[k] for k in ['ZIG_LOCAL_CACHE_DIR','ZIG_GLOBAL_CACHE_DIR','TMPDIR','PYTHONPATH']}
  base=[zig,'build','-j2',f'-Doptimize={mode}','--prefix',s/'o','--summary','all','--cache-dir',s/'c','--global-cache-dir',s/'g']
  built,_=run.command(mode+'-build',base,env=env)
  run.command(mode+'-contracts',base+['verify-contracts'],env=env)
  run.command(mode+'-registered-tests',base+['test','-Dinstall-tests=true'],env=env)
  try:
   c=capture(s/'c/.zig-cache/tmp',run.artifacts/short/'storage')
   run.report.setdefault('storage_evidence',[]).append({'mode':mode,**c})
   run.check(mode+'-storage-captured',c['fixture_count']>0,{'fixtures':c['fixture_count'],'capture_only':True})
  except Exception as e:run.check(mode+'-storage-captured',False,str(e))
  run.command(mode+'-codec',[zig,'test',repo/'src/protocol/codec.zig',f'-O{mode}',f'-femit-bin={s}/o/codec','--cache-dir',s/'c','--global-cache-dir',s/'g'],env=env,cwd=s/'t')
  if built:run.command(mode+'-cli',[sys.executable,repo/'tests/cli_smoke.py','--binary',s/'o/bin/zcr','--state',s/'cli'],env=env)
  binaries=[p for p in (s/'o').rglob('*') if p.is_file() and os.access(p,os.X_OK)]
  for p in binaries:run.report['binaries'].append({'mode':mode,'path':str(p),'sha256':digest(p),'bytes':p.stat().st_size})
  run.flush()
 after=run.source_snapshot('after'); run.check('source-unchanged',before==after,{'before':before,'after':after})
except Exception:
 run.check('driver-completed',False,traceback.format_exc())
sys.exit(run.finish())
