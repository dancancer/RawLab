"""可选真实 X3F 回归；显式传入探针、固定样片和 SPP 参考后运行。"""

import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import numpy as np
import tifffile

from render_family import digest, render


class FamilyNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        names = ('RAWLAB_X3F_FAMILY_DECODER', 'RAWLAB_X3F_MERRILL_RAW',
                 'RAWLAB_X3F_QUATTRO_RAW', 'RAWLAB_X3F_MERRILL_SPP_REFERENCE',
                 'RAWLAB_X3F_FAMILY_CONTRACT')
        if not all(os.environ.get(name) for name in names):
            raise unittest.SkipTest('Explicit native decoder, two X3F files and SPP reference required')
        cls.decoder, cls.merrill, cls.quattro, cls.reference, contract = (Path(os.environ[name]) for name in names)
        cls.contract = json.loads(contract.read_text())
        expected = ((cls.merrill, '6598fd78ac45f0d142e5685eff02b7b202be67ff6a51c7d857e8d17a70b4a9d5'),
                    (cls.quattro, 'e89f40df6881bbf60a83e56eee92d04f71b89e9ff55d6ff5d498afd4590cfcb3'),
                    (cls.reference, '54cafac972ce0ec4cee6d60cb8cccddadf053882880b926a65ca36965cb6799f'))
        for path, sha in expected:
            if digest(path) != sha:
                raise ValueError(f'Unexpected real-RAW fixture: {path}')

    def test_merrill_pipeline_matches_the_fixed_spp_reference(self):
        before = digest(self.merrill)
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / 'output.tif'
            report = render(self.decoder, self.merrill, output, 'merrill-spp', self.contract)
            actual, reference = tifffile.imread(output), tifffile.imread(self.reference)
            self.assertEqual(actual.shape, (3136, 4704, 3))
            self.assertEqual(actual.shape, reference.shape)
            # 单个已绑定样片的回归阈值，不作为整代机型或其它保存参数的验收。
            difference = np.abs(actual.astype(np.int32) - reference.astype(np.int32))
            self.assertLess(float(difference.mean()), 3.0)
            self.assertEqual(report['source_sha256'], before)
        self.assertEqual(digest(self.merrill), before)

    def test_merrill_request_on_quattro_fails_without_publishing_or_fallback(self):
        before = digest(self.quattro)
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / 'output.tif'
            with self.assertRaisesRegex(RuntimeError, 'without fallback'):
                render(self.decoder, self.quattro, output, 'merrill-spp', self.contract)
            self.assertEqual(list(Path(root).iterdir()), [])
        self.assertEqual(digest(self.quattro), before)

    def test_existing_native_directory_is_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / 'native'; output.mkdir()
            sentinel = output / 'keep'; sentinel.write_bytes(b'owned by someone else')
            result = subprocess.run([str(self.decoder), 'merrill-spp', str(self.merrill), str(output)],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_bytes(), b'owned by someone else')
            self.assertEqual(list(output.iterdir()), [sentinel])

    def test_missing_input_removes_only_the_new_native_directory(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / 'native'
            result = subprocess.run([str(self.decoder), 'native', str(Path(root) / 'missing.X3F'), str(output)],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_native_renderer_is_not_changed_by_x3f_environment_tunables(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / 'native'
            result = subprocess.run([str(self.decoder), 'merrill-spp', str(self.merrill), str(output)],
                                    env={**os.environ, 'X3F_EV': '3', 'X3F_NO_CHROMA_LUT': '1'},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            actual, reference = tifffile.imread(output / 'render.tif'), tifffile.imread(self.reference)
            difference = np.abs(actual.astype(np.int32) - reference.astype(np.int32))
            self.assertLess(float(difference.mean()), 3.0)


if __name__ == '__main__':
    unittest.main()
