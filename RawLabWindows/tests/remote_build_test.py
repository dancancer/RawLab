import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


def load_module():
    path = Path(__file__).resolve().parents[1] / 'build-remote.py'
    spec = importlib.util.spec_from_file_location('remote_build', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RumSdkArgumentsTest(unittest.TestCase):
    """远程构建默认带统计 SDK：本地有缓存就上传固定哈希的归档，否则由远端按固定地址下载"""

    def setUp(self):
        self.module = load_module()

    def test_pin_matches_the_build_rules(self):
        project = ET.parse(Path(__file__).resolve().parents[1] / 'RumSdk.targets').getroot()
        pins = [node.text for node in project.iter('RawLabRumSdkZipSha256')]
        self.assertEqual(pins, [self.module.RUM_SDK_SHA256])

    def test_offline_package_skips_the_sdk(self):
        self.assertEqual(self.module.rum_build_args(True, Path('/missing.zip'), 'C:/in'), ('-NoRumSdk', None))

    def test_missing_local_cache_lets_the_remote_download(self):
        self.assertEqual(self.module.rum_build_args(False, Path('/missing.zip'), 'C:/in'), ('', None))

    def test_cached_archive_is_verified_and_uploaded(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'sdk.zip'
            archive.write_bytes(b'vendor archive')
            self.module.RUM_SDK_SHA256 = hashlib.sha256(b'vendor archive').hexdigest()
            self.assertEqual(self.module.rum_build_args(False, archive, 'C:/RawLabBuild/incoming/1'),
                             ("-RumSdkZip 'C:/RawLabBuild/incoming/1/rum-sdk.zip'", archive))
            archive.write_bytes(b'tampered')
            with self.assertRaises(SystemExit):
                self.module.rum_build_args(False, archive, 'C:/in')

    def test_default_cache_is_in_the_main_worktree(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            self.assertEqual(self.module.rum_sdk_cache(root),
                             root / '.cache/shared/aliyun-rum/windows/0.4.4/sdk.zip')


class SourcePackageTest(unittest.TestCase):
    def test_includes_dirty_and_untracked_source_but_not_outputs_or_raws(self):
        module = load_module()
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
                         'LICENSE', 'LICENSE-ALIYUN-RUM-EXCEPTION', 'docs/reference/licensing.md',
                         'lutools/tests/fixtures/linear-jxl.dng',
                         'lutools/tests/fixtures/linear-uncompressed.dng',
                         'lutools/tests/fixtures/linear-jxl-gain.dng',
                         'lutools/tests/fixtures/linear-doubled.dng',
                         'lutools/tests/fixtures/linear-jxl-stage1.dng',
                         'lutools/tests/fixtures/linear-halved.dng',
                         'lutools/tests/fixtures/linear-jxl-crop-gain.dng',
                         'lutools/tests/fixtures/linear-crop-doubled.dng',
                         'lutools/tests/fixtures/linear-jxl-required-unknown.dng',
                         'lutools/tests/fixtures/linear-jxl-default-crop-gain.dng',
                         'lutools/tests/fixtures/linear-default-crop-doubled.dng',
                         'lutools/tests/fixtures/linear-jxl-channel-levels.dng',
                         'lutools/tests/fixtures/linear-channel-levels.dng',
                         'lutools/tests/fixtures/linear-normalized.dng',
                         'lutools/tests/fixtures/private.dng',
                         'lutools/examples/private.ARW', 'build/cache.bin']:
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('fixture')
            archive = root / 'source.zip'
            files = module.package_source(root, archive)
            self.assertIn('lutools/cmake/patch-libraw.cmake', files)
            self.assertIn('lutools/third_party/rawspeed-camera-calibration.inc', files)
            self.assertIn('LICENSE', files)
            self.assertIn('LICENSE-ALIYUN-RUM-EXCEPTION', files)
            self.assertIn('docs/reference/licensing.md', files)
            self.assertNotIn('lutools/deleted.cpp', files)
            self.assertNotIn('build/cache.bin', files)
            self.assertNotIn('lutools/examples/private.ARW', files)
            self.assertNotIn('lutools/tests/fixtures/private.dng', files)
            for name in ['linear-jxl.dng', 'linear-uncompressed.dng',
                         'linear-jxl-gain.dng', 'linear-doubled.dng',
                         'linear-jxl-stage1.dng', 'linear-halved.dng',
                         'linear-jxl-crop-gain.dng', 'linear-crop-doubled.dng',
                         'linear-jxl-required-unknown.dng',
                         'linear-jxl-default-crop-gain.dng', 'linear-default-crop-doubled.dng',
                         'linear-jxl-channel-levels.dng', 'linear-channel-levels.dng',
                         'linear-normalized.dng']:
                self.assertIn('lutools/tests/fixtures/' + name, files)
            with zipfile.ZipFile(archive) as package:
                self.assertEqual(package.read('RawLabWindows/build.ps1'), b'current dirty contents')
                self.assertEqual(package.read('LICENSE-ALIYUN-RUM-EXCEPTION'), b'fixture')


if __name__ == '__main__':
    unittest.main()
