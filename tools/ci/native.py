#!/usr/bin/env python3
"""Native CI only. Every required failure makes the process fail.

State must be fresh and outside source. This script does not edit support
matrices, task ledgers, Git state, or source. Requires native CPython 3.12.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import signal
import subprocess
import sys
import tarfile
import time
import traceback
import urllib.request


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


class Run:
    def __init__(self, source, state, target, runner):
        self.source, self.state = source, state
        self.artifacts = state / 'artifacts'
        self.artifacts.mkdir(parents=True)
        self.env = dict(os.environ)
        for key in tuple(self.env):
            if key.startswith('GIT_'):
                del self.env[key]
        for directory in ('tmp', 'global-cache', 'local-cache'):
            (state / 'bootstrap' / directory).mkdir(parents=True)
        self.env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
                        GIT_TERMINAL_PROMPT='0', PYTHONDONTWRITEBYTECODE='1', LC_ALL='C',
                        TMPDIR=str(state / 'bootstrap/tmp'), TMP=str(state / 'bootstrap/tmp'),
                        TEMP=str(state / 'bootstrap/tmp'),
                        ZIG_GLOBAL_CACHE_DIR=str(state / 'bootstrap/global-cache'),
                        ZIG_LOCAL_CACHE_DIR=str(state / 'bootstrap/local-cache'))
        self.report = {
            'schema': 'zcr-native-ci/1', 'status': 'RUNNING',
            'scope': 'required native contract, registered test, codec, and CLI subprocess commands',
            'runner': runner, 'target': target, 'commands': [], 'checks': [],
            'binaries': [], 'source': {},
            'host': {'platform': platform.platform(), 'machine': platform.machine(),
                     'python': sys.version, 'python_executable_sha256': digest(sys.executable),
                     'runner_arch': os.environ.get('RUNNER_ARCH'),
                     'image_os': os.environ.get('ImageOS'),
                     'image_version': os.environ.get('ImageVersion')},
            'workflow': {key: os.environ.get(key) for key in (
                'GITHUB_SHA', 'GITHUB_REF', 'GITHUB_EVENT_NAME', 'GITHUB_REPOSITORY',
                'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_WORKFLOW_SHA')},
            'external_gates': [
                {'gate': 'G07/G08/G13 actual host client and sandbox integration',
                 'status': 'NOT_RUN', 'reason': 'No actual Codex/Claude client or host sandbox in this job.'},
                {'gate': 'G12 paired model coexistence and end-to-end performance',
                 'status': 'NOT_RUN', 'reason': 'No actual model/client benchmark harness in this job.'},
                {'gate': 'G11 macOS 11 Intel runtime', 'status': 'NOT_RUN',
                 'reason': 'The matrix runs macOS 15, not an actual macOS 11 machine.'},
                {'gate': 'G05 complete APFS ACL/xattr/crash-durability qualification',
                 'status': 'NOT_RUN', 'reason': 'Unit tests do not constitute the full destructive APFS qualification harness.'},
            ],
            'performance_claims': False,
        }
        self.flush()

    def flush(self):
        write_json(self.artifacts / 'report.json', self.report)

    def check(self, name, ok, detail):
        self.report['checks'].append({'name': name, 'status': 'PASS' if ok else 'FAIL', 'detail': detail})
        self.flush()
        return ok

    def command(self, label, argv, *, cwd=None, env=None, timeout=900, required=True):
        argv = [str(arg) for arg in argv]
        number = len(self.report['commands']) + 1
        stdout = self.artifacts / f'{number:02d}-{label}.stdout.log'
        stderr = self.artifacts / f'{number:02d}-{label}.stderr.log'
        started = time.time()
        print(f'[{label}] {shlex.join(argv)}', flush=True)
        with stdout.open('wb') as out, stderr.open('wb') as err:
            try:
                process = subprocess.Popen(argv, cwd=cwd or self.source, env=env or self.env,
                                           stdout=out, stderr=err, start_new_session=True)
                try:
                    code = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    # Also reap descendants that ignored TERM after the group leader exited.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    code = 124
                    err.write(b'CI command exceeded timeout; its process group was terminated.\n')
            except OSError as failure:
                err.write((str(failure) + '\n').encode())
                code = 127
        self.report['commands'].append({
            'label': label, 'argv': argv, 'cwd': str(cwd or self.source), 'exit_code': code,
            'status': 'PASS' if code == 0 else 'FAIL', 'required': required,
            'started_unix': started, 'duration_seconds': time.time() - started,
            'stdout': {'path': stdout.name, 'sha256': digest(stdout)},
            'stderr': {'path': stderr.name, 'sha256': digest(stderr)},
        })
        self.flush()
        print(f'[{label}] exit {code}; logs: {stdout.name}, {stderr.name}', flush=True)
        return code == 0, stdout

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.source), *args], env=self.env, timeout=30)

    def source_snapshot(self, phase):
        head = self.git('rev-parse', 'HEAD').decode().strip()
        tree = self.git('rev-parse', 'HEAD^{tree}').decode().strip()
        status = self.git('status', '--porcelain=v1', '--untracked-files=all').decode()
        files = []
        for relative in sorted(self.git('ls-files', '-z').split(b'\0')):
            if not relative:
                continue
            name = os.fsdecode(relative)
            path = self.source / name
            sha = hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest() if path.is_symlink() else digest(path)
            files.append({'path': name, 'sha256': sha})
        def subset_hash(prefixes):
            content = ''.join(f"{entry['sha256']}  {entry['path']}\n" for entry in files
                              if not prefixes or entry['path'].startswith(prefixes))
            return hashlib.sha256(content.encode()).hexdigest()
        snapshot = {'commit': head, 'tree': tree, 'git_status': status,
                    'tracked_files_sha256': subset_hash(()),
                    'contract_sha256': subset_hash(('contracts/',)),
                    'config_sha256': subset_hash(('config/',)),
                    'contract_config_sha256': subset_hash(('contracts/', 'config/')),
                    'test_inputs_sha256': subset_hash(('tests/', 'bench/spikes/'))}
        write_json(self.artifacts / f'source-{phase}.json', {'snapshot': snapshot, 'files': files})
        self.report['source'][phase] = snapshot
        self.check(f'source-{phase}-clean', status == '', status or 'clean tracked and untracked files')
        return snapshot

    def install_zig(self, target):
        lock_path = Path(__file__).with_name('zig.lock.json')
        lock = json.loads(lock_path.read_text())
        pinned = lock['targets'][target]
        archive = self.state / 'zig.tar.xz'
        with urllib.request.urlopen(pinned['url'], timeout=90) as response, archive.open('xb') as out:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > pinned['bytes']:
                    raise RuntimeError('Zig archive exceeds pinned byte length')
                out.write(chunk)
        actual = digest(archive)
        if not self.check('zig-archive-pin', actual == pinned['sha256'] and total == pinned['bytes'],
                          {'url': pinned['url'], 'sha256': actual, 'bytes': total}):
            raise RuntimeError('Zig archive hash or size does not match lock')
        toolchain = self.state / 'toolchain'
        toolchain.mkdir()
        with tarfile.open(archive, 'r:xz') as package:
            package.extractall(toolchain, filter='data')
        zig = toolchain / f'zig-{target}-{lock["version"]}' / 'zig'
        ok, log = self.command('zig-version', [zig, 'version'], timeout=30)
        if not self.check('zig-version-pin', ok and log.read_text().strip() == lock['version'], log.read_text()):
            raise RuntimeError('Unexpected Zig version')
        self.command('zig-env', [zig, 'env'], timeout=30)
        self.report['toolchain'] = {'version': lock['version'], 'url': pinned['url'],
            'archive_sha256': actual, 'executable_sha256': digest(zig), 'lock_sha256': digest(lock_path)}
        self.flush()
        return zig

    def run_mode(self, mode, zig, python):
        state = self.state / mode
        mode_artifacts = self.artifacts / mode
        mode_artifacts.mkdir()
        for name in ('tmp', 'global-cache', 'local-cache', 'out', 'codec', 'probe'):
            (state / name).mkdir(parents=True)
        env = {**self.env, 'ZIG_GLOBAL_CACHE_DIR': str(state / 'global-cache'),
               'ZIG_LOCAL_CACHE_DIR': str(state / 'local-cache'), 'TMPDIR': str(state / 'tmp'),
               'TMP': str(state / 'tmp'), 'TEMP': str(state / 'tmp')}
        cache_flags = ['--cache-dir', state / 'local-cache', '--global-cache-dir', state / 'global-cache']
        build = [zig, 'build', '-j2', f'-Doptimize={mode}', '--prefix', state / 'out', '--summary', 'all', *cache_flags]
        built, _ = self.command(mode + '-build', build, env=env)
        self.command(mode + '-contracts', build + ['verify-contracts'], env=env)
        self.command(mode + '-registered-tests', build + ['test', '-Dinstall-tests=true'], env=env)
        # codec.zig has its own allocation-failure/preflight tests outside build.zig's registry.
        self.command(mode + '-codec-tests', [zig, 'test', self.source / 'src/protocol/codec.zig',
                     f'-O{mode}', f'-femit-bin={state / "codec" / "codec-test"}', *cache_flags],
                     cwd=state / 'tmp', env=env)
        if built:
            self.command(mode + '-cli-subprocess', [python, self.source / 'tests/cli_smoke.py',
                         '--binary', state / 'out/bin/zcr', '--state', mode_artifacts / 'cli'], env=env)
        else:
            self.check(mode + '-cli-subprocess', False, 'BLOCKED by failed executable build; no stale binary is used')
        # Preserve the actual runtime capability data, not just compilation output.
        caps_binary = state / 'probe/caps'
        probe = [zig, 'build-exe', f'-O{mode}', f'-femit-bin={caps_binary}', '-lc', *cache_flags]
        if sys.platform == 'darwin':
            probe += ['-framework', 'Foundation', '-framework', 'IOKit', '-framework', 'CoreFoundation',
                      self.source / 'bench/spikes/darwin_abi.c']
        probe += [self.source / 'bench/spikes/caps.zig']
        compiled, _ = self.command(mode + '-caps-build', probe, cwd=state / 'tmp', env=env)
        if compiled:
            measured, _ = self.command(mode + '-caps-runtime', [caps_binary, '--repo', self.source,
                '--corpus', self.source / 'contracts', '--corpus-id', 'checked-out-contracts',
                '--zig', zig, '--out', mode_artifacts / 'baseline.json'], cwd=state / 'tmp', env=env)
            if measured:
                baseline = json.loads((mode_artifacts / 'baseline.json').read_text())
                gates = {gate['id']: gate['status'] for gate in baseline['gates']}
                required = ['G06'] + (['G01'] if sys.platform == 'darwin' else [])
                self.check(mode + '-caps-gates', all(gates.get(g) == 'pass' for g in required)
                           and 'fail' not in gates.values(), gates)
                # Missing optional perflevel keys remain unknown (e.g. Intel); no support promotion.
        else:
            self.check(mode + '-caps-runtime', False, 'BLOCKED by failed probe build')
        binaries = []
        for directory in (state / 'out/bin', state / 'codec', state / 'probe'):
            if directory.exists():
                binaries.extend(path for path in directory.iterdir() if path.is_file() and os.access(path, os.X_OK))
        for path in sorted(binaries):
            self.report['binaries'].append({'mode': mode, 'path': str(path.relative_to(state)),
                                           'sha256': digest(path), 'bytes': path.stat().st_size})
        with tarfile.open(mode_artifacts / 'binaries.tar.gz', 'w:gz') as archive:
            for path in sorted(binaries):
                archive.add(path, arcname=str(path.relative_to(state)), recursive=False)
        self.flush()

    def finish(self):
        failures = any(row['status'] == 'FAIL' for row in self.report['checks']) or any(
            row['required'] and row['exit_code'] != 0 for row in self.report['commands'])
        self.report['status'] = 'FAIL' if failures else 'PASS'
        self.report['finished_unix'] = time.time()
        self.flush()
        manifest = [{'path': str(path.relative_to(self.artifacts)), 'sha256': digest(path),
                     'bytes': path.stat().st_size} for path in sorted(self.artifacts.rglob('*')) if path.is_file()]
        write_json(self.artifacts / 'artifact-sha256.json', manifest)
        print('Required native CI commands: ' + self.report['status'], flush=True)
        return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--target', choices=('x86_64-linux', 'aarch64-macos', 'x86_64-macos'), required=True)
    parser.add_argument('--runner', required=True)
    args = parser.parse_args()
    source, state = args.source.resolve(strict=True), args.state.resolve()
    if state == source or source in state.parents or state in source.parents:
        parser.error('source and state must be separate directory trees')
    if state.exists():
        parser.error('state must be fresh; refusing to remove or reuse existing data')
    state.mkdir(parents=True)
    run = Run(source, state, args.target, args.runner)
    try:
        machine = {'arm64': 'aarch64', 'AMD64': 'x86_64'}.get(platform.machine(), platform.machine())
        host = machine + ('-macos' if sys.platform == 'darwin' else '-linux' if sys.platform == 'linux' else '-unsupported')
        if not run.check('native-target', host == args.target, {'actual': host, 'expected': args.target}):
            raise RuntimeError('Native runner architecture does not match matrix')
        if not run.check('python-3.12', sys.version_info[:2] == (3, 12), sys.version):
            raise RuntimeError('Python 3.12 is required by the wheel hash lock')
        before = run.source_snapshot('before')
        if before['git_status']:
            raise RuntimeError('Dirty source is not admissible evidence')
        run.command('git-version', ['git', '--version'], timeout=30)
        run.command('filesystem', ['df', '-h', str(source), str(state)], timeout=30)
        if sys.platform == 'darwin':
            run.command('os-version', ['sw_vers'], timeout=30)
            run.command('sdk-version', ['xcrun', '--sdk', 'macosx', '--show-sdk-version'], timeout=30)
            run.command('sdk-path', ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], timeout=30)
            located, log = run.command('filesystem-device', ['df', '-P', str(state)], timeout=30)
            if located:
                device = log.read_text().splitlines()[-1].split()[0]
                run.command('filesystem-detail', ['diskutil', 'info', device], timeout=30)
        else:
            run.command('cpu', ['lscpu'], timeout=30)
            run.command('filesystem-detail', ['findmnt', '-T', str(state), '-o', 'SOURCE,FSTYPE,OPTIONS'], timeout=30)
        zig = run.install_zig(args.target)
        created, _ = run.command('python-venv', [sys.executable, '-m', 'venv', state / 'venv'], timeout=90)
        python = state / 'venv/bin/python'
        if not created:
            raise RuntimeError('Schema fixture environment setup failed')
        installed, _ = run.command('schema-dependencies', [python, '-m', 'pip', '--isolated', 'install',
            '--disable-pip-version-check', '--no-input', '--no-cache-dir', '--require-hashes', '--only-binary=:all:',
            '--index-url', 'https://pypi.org/simple', '--report', run.artifacts / 'pip-install.json',
            '-r', Path(__file__).with_name('requirements.txt')], timeout=180)
        if not installed:
            raise RuntimeError('Hash-locked schema dependencies could not be installed')
        run.command('python-dependencies', [python, '-m', 'pip', 'freeze', '--all'], timeout=30)
        for mode in ('Debug', 'ReleaseSafe'):
            run.run_mode(mode, zig, python)
        after = run.source_snapshot('after')
        run.check('source-unchanged', before == after, {'before': before, 'after': after})
    except Exception:
        details = traceback.format_exc()
        (run.artifacts / 'driver-error.log').write_text(details)
        run.check('driver-completed', False, details)
    return run.finish()


if __name__ == '__main__':
    raise SystemExit(main())
