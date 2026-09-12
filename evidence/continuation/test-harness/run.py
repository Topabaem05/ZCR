import os,sys,subprocess,json,hashlib
from pathlib import Path
w=Path('/workspace/scratch/3f4ab65dfb82/ZCR-tests');s=Path('/workspace/scratch/3f4ab65dfb82/state/test-harness')
task=sys.argv[1];mode=sys.argv[2] if len(sys.argv)>2 else 'Debug';label=sys.argv[3] if len(sys.argv)>3 else task+'-'+mode
z='/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig'
mods={
'T00':['--dep','caps','-Mroot=tests/t00_test.zig','-Mcaps=bench/spikes/caps.zig'],
'T01':['--dep','zcr_core','--dep','evidence','--dep','build_options','-Mroot=tests/t01_test.zig','-Mzcr_core=src/core/types.zig','--dep','zcr_core','-Mevidence=tools/dev/evidence.zig','-Mbuild_options='+str(s/'build_options.zig')],
'T02':['--dep','zcr_core','--dep','evidence','--dep','build_options','--dep','zcr_policy','--dep','dev_guard','-Mroot=tests/t02_test.zig','-Mzcr_core=src/core/types.zig','--dep','zcr_core','-Mevidence=tools/dev/evidence.zig','-Mbuild_options='+str(s/'build_options.zig'),'--dep','zcr_core','-Mzcr_policy=src/policy/capability.zig','--dep','zcr_core','--dep','evidence','-Mdev_guard=tools/dev/guard.zig'],
'T03':['--dep','zcr_core','--dep','zcr_memory','--dep','zcr_admission','-Mroot=tests/t03_test.zig','-Mzcr_core=src/core/types.zig','--dep','zcr_core','-Mzcr_memory=src/memory/budget.zig','--dep','zcr_core','--dep','zcr_memory','-Mzcr_admission=src/scheduler/admission.zig']}
args=[z,'test','--test-no-exec','-lc','-O',mode,*mods[task],'-femit-bin='+str(s/'bin'/label)]
if len(sys.argv)>4:args+=['--test-filter',sys.argv[4]]
env={k:v for k,v in os.environ.items() if not k.upper().startswith('GIT_')};env.update(ZIG_GLOBAL_CACHE_DIR=str(s/'zig-global-cache'),ZIG_LOCAL_CACHE_DIR=str(s/'zig-local-cache'),TMPDIR=str(s/'tmp'))
r=subprocess.run(args,cwd=w,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
compile_result=r
if r.returncode==0:
 r=subprocess.run([str(s/'bin'/label)],cwd=s,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(s/'logs'/f'{label}.log').write_bytes(compile_result.stdout+r.stdout if compile_result is not r else r.stdout)
metadata={'argv':args,'cwd':str(w),'exit_code':r.returncode,'head':subprocess.check_output(['/usr/bin/git','-C',str(w),'rev-parse','HEAD'],text=True,env=env).strip(),'compile_exit':compile_result.returncode,'run_argv':[str(s/'bin'/label)],'run_cwd':str(s),'log_sha256':hashlib.sha256((s/'logs'/f'{label}.log').read_bytes()).hexdigest()}
if (s/'bin'/label).is_file():metadata['binary_sha256']=hashlib.sha256((s/'bin'/label).read_bytes()).hexdigest()
(s/'logs'/f'{label}.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(r.stdout.decode());sys.exit(r.returncode)
