import os,sys,json,subprocess,hashlib
from pathlib import Path
s=Path(__file__).resolve().parent
w=Path('/workspace/scratch/3f4ab65dfb82/ZCR-runtime-cache')
label=sys.argv[1];args=['/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig',*sys.argv[2:]]
env={k:v for k,v in os.environ.items() if not k.upper().startswith('GIT_')}
env.update(ZIG_GLOBAL_CACHE_DIR=str(s/'zig-global-cache'),ZIG_LOCAL_CACHE_DIR=str(s/'zig-local-cache'),TMPDIR=str(s/'tmp'))
head=subprocess.check_output(['/usr/bin/git','-C',str(w),'rev-parse','HEAD'],env=env,text=True).strip()
r=subprocess.run(args,cwd=w,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
log=s/'logs'/f'{label}.log';log.write_bytes(r.stdout)
m={'command':args,'cwd':str(w),'head':head,'exit':r.returncode,'log':str(log),'log_sha256':hashlib.sha256(r.stdout).hexdigest(),'env_overrides':{k:env[k] for k in ['ZIG_GLOBAL_CACHE_DIR','ZIG_LOCAL_CACHE_DIR','TMPDIR']}}
(s/'logs'/f'{label}.json').write_text(json.dumps(m,indent=2)+'\n')
print(r.stdout.decode());sys.exit(r.returncode)
