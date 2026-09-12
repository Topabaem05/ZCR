"""Retain native T12 crash evidence, without archiving fixture source trees."""
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import tarfile


def _regular_bytes(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('not a regular evidence file')
        if before.st_size > limit:
            raise ValueError('capture byte limit exceeded')
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError('capture byte limit exceeded')
        after = os.fstat(stream.fileno())
        identity = lambda st: (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        if identity(before) != identity(after) or len(data) != after.st_size:
            raise ValueError('evidence changed during capture')
        return data


def capture(fixtures, output, *, max_bytes=64 * 1024 * 1024, max_files=4096):
    """Capture generated records only. A successful capture is not a test PASS."""
    fixtures, output = Path(fixtures), Path(output)
    output.mkdir(parents=True, exist_ok=False)
    result = {'schema': 'zcr-native-crash-capture/1', 'status': 'NO_FIXTURES',
              'runtime_pass_claim': False, 'fixture_count': 0, 'bytes': 0,
              'files': [], 'oracles': [], 'excluded_special_files': []}
    directories = sorted(fixtures.iterdir()) if fixtures.exists() else []
    with tarfile.open(output / 'raw-fixtures.tar.gz', 'w:gz') as archive:
        for fixture in directories:
            if fixture.is_symlink() or not fixture.is_dir():
                continue
            records = list(fixture.glob('child-*'))
            for name in ('case.json', 'history.json'):
                records.extend(fixture.glob(name))
            if not records:
                continue
            result['fixture_count'] += 1
            if result['fixture_count'] > 512:
                raise ValueError('capture fixture limit exceeded')
            for name in ('state', 'state-original'):
                directory = fixture / name
                if directory.is_symlink():
                    result['excluded_special_files'].append(str(directory.relative_to(fixtures)))
                elif directory.is_dir():
                    for path in directory.rglob('*'):
                        if len(records) >= max_files:
                            raise ValueError('capture file limit exceeded')
                        records.append(path)
            for path in sorted(set(records)):
                relative = path.relative_to(fixtures).as_posix()
                metadata = path.lstat()
                if stat.S_ISDIR(metadata.st_mode):
                    continue
                if not stat.S_ISREG(metadata.st_mode):
                    result['excluded_special_files'].append(relative)
                    continue
                if len(result['files']) >= max_files:
                    raise ValueError('capture file limit exceeded')
                data = _regular_bytes(path, max_bytes - result['bytes'])
                member = tarfile.TarInfo(relative)
                member.size, member.mode = len(data), 0o600
                archive.addfile(member, io.BytesIO(data))
                result['files'].append({'path': relative, 'bytes': len(data),
                                        'sha256': hashlib.sha256(data).hexdigest()})
                result['bytes'] += len(data)
            oracle = {'fixture': fixture.name}
            for label, name in (('target', 'file.txt'), ('sentinel', 'sentinel')):
                path = fixture / 'repo' / name
                if (fixture / 'repo').is_symlink():
                    oracle[label] = {'state': 'UNTRUSTED_PARENT'}
                elif not path.exists() and not path.is_symlink():
                    oracle[label] = {'state': 'ABSENT'}
                elif path.is_symlink() or not path.is_file():
                    oracle[label] = {'state': 'NOT_REGULAR'}
                else:
                    data = _regular_bytes(path, max_bytes)
                    oracle[label] = {'state': 'REGULAR', 'bytes': len(data),
                                     'sha256': hashlib.sha256(data).hexdigest()}
            result['oracles'].append(oracle)
    if result['fixture_count']:
        result['status'] = 'CAPTURED'
    with (output / 'raw-fixtures.tar.gz').open('rb') as stream:
        result['archive_sha256'] = hashlib.file_digest(stream, 'sha256').hexdigest()
    (output / 'capture.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result
