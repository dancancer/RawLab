import importlib.util
from pathlib import Path
import tempfile
import unittest

import numpy as np

spec = importlib.util.spec_from_file_location("prepare", Path(__file__).parents[1] / "prepare-bundled-looks.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class AdapterTests(unittest.TestCase):
    def test_source_and_output_trees_cannot_overlap(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for source, output in [(root, root), (root, root / "output"), (root / "source", root)]:
                with self.subTest(source=source, output=output):
                    with self.assertRaisesRegex(ValueError, "separate and read-only"):
                        prepare.prepare(source, output)

    def test_gamma24_identity_has_no_extra_display_curve(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "identity.cube"
            prepare.write_display_cube(path, lambda x: x, 2)
            evaluate = prepare.gamma24_adapter(path)
            values = np.array([[0., 0., 0.], [.18, .18, .18], [1., 1., 1.], [.1, .5, .9]])
            np.testing.assert_allclose(evaluate(values), values, atol=5e-6)

    def test_writer_uses_native_display_contract_and_r_fast_order(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "swap.cube"
            prepare.write_display_cube(path, lambda x: x[:, [2, 1, 0]], 3)
            text = path.read_text()
            self.assertIn("#Gamma:sRGB to sRGB", text)
            self.assertIn("#Gamut:ITU-R BT.709 to ITU-R BT.709", text)
            evaluate = prepare.file_processor(path)
            values = np.array([[.2, .4, .6], [1., 0., .5]])
            np.testing.assert_allclose(prepare.apply_processor(evaluate, values), values[:, [2, 1, 0]], atol=1e-6)


if __name__ == "__main__":
    unittest.main()
