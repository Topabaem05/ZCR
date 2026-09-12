import subprocess,pathlib,os,hashlib,json,datetime,time
root=pathlib.Path('/workspace/scratch/3f4ab65dfb82/ZCR-legacy')
state=pathlib.Path('/workspace/scratch/3f4ab65dfb82/state/legacy')
zig='/workspace/scratch/3f4ab65dfb82/toolchain/ziglang/zig'
def sha(p): return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def git(*a): return subprocess.check_output(['git','-C',str(root),*a],text=True).strip()
source=git('rev-parse','HEAD'); tree=git('rev-parse','HEAD^{tree}')
assert not git('status','--porcelain'), 'dirty source'
env=os.environ.copy(); env.update(ZIG_GLOBAL_CACHE_DIR=str(state/'zig-global-cache'),ZIG_LOCAL_CACHE_DIR=str(state/'zig-local-cache'),TMPDIR=str(state/'tmp'))
config={'zig_sha256':sha(zig),'target':'native Linux x86_64','source_commit':source,'source_tree':tree,'cache_root':str(state),'uid':os.getuid(),'kernel':os.uname().release,'caps_status':[s for s in pathlib.Path('/proc/self/status').read_text().splitlines() if s.startswith(('CapEff','CapBnd','NoNewPrivs'))]}
config_bytes=json.dumps(config,sort_keys=True,indent=2).encode();(state/'verification-config.json').write_bytes(config_bytes);config_hash=hashlib.sha256(config_bytes).hexdigest()
records=[]
for mode in ('Debug','ReleaseSafe'):
 for group,task in (('io','T04'),('fs','T05'),('search','T06'),('batch','T07')):
  label='deadline-final-'+group+'-'+mode.lower(); prefix=state/'out'/label; log=state/'logs'/(label+'.log')
  cmd=[zig,'build','test','-Dtest-group='+group,'-Dinstall-tests=true','-Doptimize='+mode,'--prefix',str(prefix),'--summary','all']
  started=datetime.datetime.now(datetime.timezone.utc).isoformat(); tick=time.monotonic()
  with log.open('wb') as f:
   proc=subprocess.run(cmd,cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=180)
  binary=prefix/'bin'/(task+'-test')
  record={'label':label,'command':cmd,'cwd':str(root),'source_commit':source,'source_tree':tree,'config_sha256':config_hash,'started_at':started,'elapsed_seconds':time.monotonic()-tick,'exit_code':proc.returncode,'binary_path':str(binary),'binary_sha256':sha(binary) if binary.exists() else None,'output_path':str(log),'output_sha256':sha(log),'corpus_sha256': '8516686afc53e0500c9119dc68e4d62c60ab6e601af8d43a7f282bb90db6d26b' if group=='fs' else None}
  record['binaries']=[{'path':str(b),'sha256':sha(b)} for b in sorted((prefix/'bin').glob('*')) if b.is_file()]
  records.append(record);(state/'verification-runs.json').write_text(json.dumps(records,indent=2)+'\n')
  print(label,'exit',proc.returncode,'seconds',round(record['elapsed_seconds'],2),flush=True)
  print(log.read_text()[-1400:],flush=True)
  if proc.returncode: raise SystemExit(proc.returncode)
  assert source==git('rev-parse','HEAD') and not git('status','--porcelain'), 'source changed'
print('All legacy suites complete',source,flush=True)
