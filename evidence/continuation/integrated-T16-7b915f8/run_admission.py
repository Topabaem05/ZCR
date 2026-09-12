import os,sys,json,traceback
from pathlib import Path
root=Path('/workspace/scratch/3f4ab65dfb82'); repo=root/'ZCR-work'; state=root/'state/i2'; state.mkdir()
sys.dont_write_bytecode=True;sys.path.insert(0,str(repo/'tools/ci'))
from native import Run,digest
run=Run(repo,state,'x86_64-linux','local-restricted-container')
zig=root/'toolchain/ziglang/zig';run.report['driver']={'path':str(Path(__file__).resolve()),'sha256':digest(__file__)};run.report['toolchain']={'path':str(zig),'sha256':digest(zig)}
try:
 before=run.source_snapshot('before');assert not before['git_status']
 for x in ['c','g','t','o']:(state/x).mkdir()
 env={**run.env,'ZIG_LOCAL_CACHE_DIR':str(state/'c'),'ZIG_GLOBAL_CACHE_DIR':str(state/'g'),'TMPDIR':str(state/'t')};run.report['env_overrides']={k:env[k] for k in ['ZIG_LOCAL_CACHE_DIR','ZIG_GLOBAL_CACHE_DIR','TMPDIR']}
 for group in ['scheduler','memory','mcp']:
  run.command(group+'-Debug',[zig,'build','test','-j2','-Doptimize=Debug','-Dtest-group='+group,'-Dinstall-tests=true','--prefix',state/'o','--summary','all'],env=env)
 for p in (state/'o/bin').glob('*'):
  if p.is_file():run.report['binaries'].append({'path':str(p),'sha256':digest(p),'bytes':p.stat().st_size})
 after=run.source_snapshot('after');run.check('source-unchanged',before==after,{'before':before,'after':after})
except Exception:run.check('driver-completed',False,traceback.format_exc())
sys.exit(run.finish())
