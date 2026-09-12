import os,sys,json,hashlib,subprocess
from pathlib import Path
s=Path(__file__).resolve().parent;w=Path('/workspace/scratch/3f4ab65dfb82/ZCR-runtime-cache');mode=sys.argv[1]
label='native-cli-'+mode;binary=s/('out-green-cli-'+mode)/'bin/zcr';state=s/label
args=['python3','tests/cli_smoke.py','--binary',str(binary),'--state',str(state)]
env={k:v for k,v in os.environ.items() if not k.upper().startswith('GIT_')};env['PYTHONPATH']='/workspace/scratch/3f4ab65dfb82/toolchain/doc-deps';env['TMPDIR']=str(s/'tmp')
r=subprocess.run(args,cwd=w,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);log=s/'logs'/f'{label}.log';log.write_bytes(r.stdout)
m={'command':args,'cwd':str(w),'source_commit':subprocess.check_output(['/usr/bin/git','-C',str(w),'rev-parse','HEAD'],env=env,text=True).strip(),'exit':r.returncode,'binary':str(binary),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'log':str(log),'log_sha256':hashlib.sha256(r.stdout).hexdigest(),'PYTHONPATH':env['PYTHONPATH'],'state':str(state)}
for name in ['report.json','transcript.json']:
 if (state/name).exists():m[name+'_sha256']=hashlib.sha256((state/name).read_bytes()).hexdigest()
(s/'logs'/f'{label}.json').write_text(json.dumps(m,indent=2)+'\n');print(r.stdout.decode());sys.exit(r.returncode)
