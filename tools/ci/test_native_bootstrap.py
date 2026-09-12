"""Regression checks for the CI source-integrity gate; no runtime claims."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class BootstrapTests(unittest.TestCase):
    def test_plain_python_launch_does_not_write_into_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'source'
            source.mkdir()
            for name in ('native.py', 'storage_capture.py'):
                shutil.copyfile(Path(__file__).with_name(name), source / name)
            before = {p.name: p.read_bytes() for p in source.iterdir()}
            env = dict(os.environ)
            env.pop('PYTHONDONTWRITEBYTECODE', None)
            env.pop('PYTHONPYCACHEPREFIX', None)
            result = subprocess.run([sys.executable, source / 'native.py', '--help'],
                                    env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(sorted(p.name for p in source.iterdir()), sorted(before))
            for name, content in before.items():
                self.assertEqual((source / name).read_bytes(), content)


if __name__ == '__main__':
    unittest.main()
