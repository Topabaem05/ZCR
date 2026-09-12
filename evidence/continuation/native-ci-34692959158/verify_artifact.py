"""Verify downloaded CI artifacts without executing or extracting binaries."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import zipfile

p = argparse.ArgumentParser()
p.add_argument('archive', type=Path)
p.add_argument('--sha256', required=True)
p.add_argument('--repo', type=Path, required=True)
p.add_argument('--commit', required=True)
a = p.parse_args()
checks = []

def check(name, condition):
    checks.append({'name': name, 'pass': bool(condition)})
    if not condition:
        raise RuntimeError(name)

def digest(stream):
    return hashlib.file_digest(stream, 'sha256').hexdigest()

def git(*args):
    return subprocess.check_output(['git', '-C', str(a.repo), *args])

with a.archive.open('rb') as f:
    check('download ZIP SHA256', digest(f) == a.sha256)
tree = git('rev-parse', a.commit + '^{tree}').decode().strip()
root = a.archive.parent / 'extracted'
root.mkdir(exist_ok=True)
with zipfile.ZipFile(a.archive) as z:
    names = z.namelist()
    check('unique ZIP members', len(names) == len(set(names)))
    for name in names:
        q = PurePosixPath(name)
        check('safe member ' + name, not q.is_absolute() and '..' not in q.parts)
    manifest = json.loads(z.read('artifact-sha256.json'))
    for item in manifest:
        with z.open(item['path']) as f:
            check('artifact digest ' + item['path'], digest(f) == item['sha256'])
        check('artifact size ' + item['path'], z.getinfo(item['path']).file_size == item['bytes'])
    report = json.loads(z.read('report.json'))
    before = json.loads(z.read('source-before.json'))
    after = json.loads(z.read('source-after.json'))
    check('same clean source before/after', before == after and before['snapshot']['git_status'] == '')
    check('expected exact source tree', before['snapshot']['tree'] == tree)
    for item in before['files']:
        blob = git('show', a.commit + ':' + item['path'])
        check('source blob ' + item['path'], hashlib.sha256(blob).hexdigest() == item['sha256'])
    for mode in ('Debug', 'ReleaseSafe'):
        expected = {b['path']: b for b in report['binaries'] if b['mode'] == mode}
        seen = set()
        with tarfile.open(fileobj=z.open(mode + '/binaries.tar.gz'), mode='r|gz') as t:
            for member in t:
                check('regular unique recorded binary ' + mode + '/' + member.name,
                      member.isfile() and member.name in expected and member.name not in seen)
                item = expected[member.name]
                check('binary size ' + mode + '/' + member.name, member.size == item['bytes'])
                with t.extractfile(member) as f:
                    check('binary digest ' + mode + '/' + member.name, digest(f) == item['sha256'])
                seen.add(member.name)
        check('complete binary set ' + mode, seen == expected.keys())
    for name in names:
        if name.endswith('/') or name.endswith('.tar.gz') or '/cli/fixture/' in name:
            continue
        dest = root / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(z.read(name))
    result = {'archive': a.archive.name, 'archive_sha256': a.sha256,
              'local_source': a.commit, 'tree': tree, 'native_source': before['snapshot']['commit'],
              'target': report['target'], 'native_status': report['status'], 'checks': checks}
    (a.archive.parent / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'checks'}, indent=2))
    print('Artifact/source/binary checks passed:', len(checks))
    for name in names:
        if name.endswith('registered-tests.stderr.log'):
            print(name)
            print('\n'.join(l for l in z.read(name).decode().splitlines()
                            if 'Build Summary:' in l or 'error:' in l))
