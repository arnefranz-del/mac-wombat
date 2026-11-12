import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def module(name):
    path = Path(__file__).resolve().parents[2]/'Scripts'/(name+'.py')
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class ReleasePreparationTests(unittest.TestCase):
    def fixture(self, directory):
        export = module('export-public-source')
        export.ROOT = Path(directory)
        export.ROOT_FILES = ['README.md']
        export.SCRIPTS = []
        export.TREES = ['Sources']
        (export.ROOT/'README.md').write_text('synthetic fixture\n')
        (export.ROOT/'Sources').mkdir()
        (export.ROOT/'Sources/main.swift').write_text('print("fixture")\n')
        return export

    def test_snapshot_hashes_match_exported_bytes_and_private_trees_are_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            export = self.fixture(directory)
            (export.ROOT/'.git').mkdir()
            (export.ROOT/'.git/private').write_text('private history fixture')
            (export.ROOT/'usage.sqlite').write_text('private database fixture')
            (export.ROOT/'Sources/main.swift').chmod(0o755)
            with contextlib.redirect_stdout(io.StringIO()):
                export.main()
            output = export.ROOT/'build/release-audit/Wombat-source-LOCAL-PREVIEW'
            manifest = json.loads((output/'SOURCE-MANIFEST.json').read_text())
            for name, digest in manifest.items():
                self.assertEqual(hashlib.sha256((output/name).read_bytes()).hexdigest(), digest)
            self.assertFalse((output/'.git').exists())
            self.assertFalse((output/'usage.sqlite').exists())
            self.assertTrue(os.access(output/'Sources/main.swift', os.X_OK))
            with self.assertRaises(SystemExit):
                export.main()

    def test_secret_scan_blocks_without_printing_matched_value(self):
        with tempfile.TemporaryDirectory() as directory:
            export = self.fixture(directory)
            fake = 'sk-proj-' + 'X'*32
            (export.ROOT/'README.md').write_text(fake)
            capture = io.StringIO()
            with contextlib.redirect_stdout(capture), self.assertRaises(SystemExit) as raised:
                export.main()
            self.assertEqual(raised.exception.code, 1)
            self.assertNotIn(fake, capture.getvalue())
            self.assertIn('credential-marker', capture.getvalue())

    def test_linked_allowlist_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            export = self.fixture(directory)
            (export.ROOT/'README.md').unlink()
            (export.ROOT/'README.md').symlink_to(export.ROOT/'Sources/main.swift')
            with self.assertRaises(SystemExit):
                export.main()

    def test_swift_wrapper_forwards_args_with_a_clean_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts, bin_dir = root/'Scripts', root/'bin'
            scripts.mkdir()
            bin_dir.mkdir()
            wrapper = Path(__file__).resolve().parents[2]/'Scripts/swift.sh'
            shutil.copy2(wrapper, scripts/'swift.sh')
            (bin_dir/'xcrun').write_text('#!/bin/bash\nprintf "%s\\n" "$FAKE_SWIFT_COMPILER"\n')
            (bin_dir/'swift').write_text('#!/bin/bash\nprintf "%s\\n" "$@"\n')
            for shim in bin_dir.iterdir():
                shim.chmod(0o755)
            env = {**os.environ, 'PATH': f"{bin_dir}:{os.environ['PATH']}",
                   'FAKE_SWIFT_COMPILER': str(root/'toolchain/usr/bin/swiftc')}
            result = subprocess.run(['/bin/bash', str(scripts/'swift.sh'), 'test', '--filter', 'sample case'],
                                    capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['test', '--filter', 'sample case'])

    def test_normal_release_rejects_lab_environment_before_any_build(self):
        release = module('prepare-release')
        with patch.dict(os.environ, {'WOMBAT_HOME_LAB':'1'}), patch.object(release,'run') as runner:
            with self.assertRaisesRegex(SystemExit, 'refuses WOMBAT_HOME_LAB'):
                release.main()
            runner.assert_not_called()


if __name__ == '__main__':
    unittest.main()
