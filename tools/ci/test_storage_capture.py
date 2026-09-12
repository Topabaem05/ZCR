"""Development checks for native crash-evidence capture; no runtime claims."""
import hashlib
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from storage_capture import capture


class CaptureTests(unittest.TestCase):
    def test_retains_raw_evidence_without_source_or_special_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixtures = root / 'fixtures'
            case = fixtures / 'one'
            (case / 'state').mkdir(parents=True)
            (case / 'repo/.git').mkdir(parents=True)
            (case / 'repo/.git/config').write_bytes(b'never archive Git metadata')
            (case / 'repo/file.txt').write_bytes(b'new target')
            (case / 'repo/sentinel').write_bytes(b'sentinel')
            (case / 'case.json').write_text('{"point":7,"create":false}')
            (case / 'history.json').write_text('{"original":["first","second"]}')
            (case / 'child-1.stdout').write_bytes(b'raw pipe transcript')
            (case / 'state/entry').write_bytes(b'journal bytes')
            (case / 'state/link').symlink_to(root / 'outside')
            (root / 'outside').write_bytes(b'not evidence')
            import os
            os.mkfifo(case / 'state/fifo')
            output = root / 'output'
            result = capture(fixtures, output)
            self.assertEqual(result['fixture_count'], 1)
            with tarfile.open(output / 'raw-fixtures.tar.gz') as archive:
                names = archive.getnames()
                self.assertEqual(set(names), {'one/case.json', 'one/history.json', 'one/child-1.stdout', 'one/state/entry'})
                self.assertEqual(archive.extractfile('one/state/entry').read(), b'journal bytes')
            manifest = json.loads((output / 'capture.json').read_text())
            self.assertEqual(manifest['oracles'][0]['target']['sha256'], hashlib.sha256(b'new target').hexdigest())
            self.assertEqual(len(manifest['excluded_special_files']), 2)
            self.assertFalse(manifest['runtime_pass_claim'])

    def test_bound_exhaustion_is_a_capture_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'fixtures/one').mkdir(parents=True)
            (root / 'fixtures/one/child-1.stdout').write_bytes(b'12345')
            with self.assertRaisesRegex(ValueError, 'capture byte limit'):
                capture(root / 'fixtures', root / 'output', max_bytes=4)

    def test_missing_fixtures_never_claim_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = capture(root / 'absent', root / 'output')
            self.assertEqual(result['status'], 'NO_FIXTURES')
            self.assertEqual(result['fixture_count'], 0)
            self.assertFalse(result['runtime_pass_claim'])

    def test_does_not_follow_replaced_repository_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'fixtures/one').mkdir(parents=True)
            (root / 'fixtures/one/child-1.stdout').write_bytes(b'failed case')
            (root / 'outside').mkdir()
            (root / 'outside/file.txt').write_bytes(b'not an oracle')
            (root / 'fixtures/one/repo').symlink_to(root / 'outside', target_is_directory=True)
            result = capture(root / 'fixtures', root / 'output')
            self.assertEqual(result['oracles'][0]['target'], {'state': 'UNTRUSTED_PARENT'})


if __name__ == '__main__':
    unittest.main()
