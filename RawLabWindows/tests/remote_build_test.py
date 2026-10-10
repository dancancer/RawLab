import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


class SourcePackageTest(unittest.TestCase):
    def test_includes_dirty_and_untracked_source_but_not_outputs_or_raws(self):
        path = Path(__file__).resolve().parents[1] / 'build-remote.py'
        spec = importlib.util.spec_from_file_location('remote_build', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            for name, content in {
                '.gitignore': 'build/\n',
                'RawLabWindows/build.ps1': 'old',
                'lutools/deleted.cpp': 'deleted',
            }.items():
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(content)
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            (root / 'RawLabWindows/build.ps1').write_text('current dirty contents')
            (root / 'lutools/deleted.cpp').unlink()
            for name in ['lutools/cmake/patch-libraw.cmake',
                         'lutools/third_party/rawspeed-camera-calibration.inc',
                         'LICENSE', 'docs/licensing.md',
                         'lutools/examples/private.ARW', 'build/cache.bin']:
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('fixture')
            archive = root / 'source.zip'
            files = module.package_source(root, archive)
            self.assertIn('lutools/cmake/patch-libraw.cmake', files)
            self.assertIn('lutools/third_party/rawspeed-camera-calibration.inc', files)
            self.assertIn('LICENSE', files)
            self.assertIn('docs/licensing.md', files)
            self.assertNotIn('lutools/deleted.cpp', files)
            self.assertNotIn('build/cache.bin', files)
            self.assertNotIn('lutools/examples/private.ARW', files)
            with zipfile.ZipFile(archive) as package:
                self.assertEqual(package.read('RawLabWindows/build.ps1'), b'current dirty contents')


if __name__ == '__main__':
    unittest.main()
