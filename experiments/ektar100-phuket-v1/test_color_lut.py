import importlib.util
from pathlib import Path
import tempfile
import unittest

import numpy as np


class ColorLUTTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).with_name("color_lut.py")
        self.assertTrue(path.exists(), "The independent LUT generator is not implemented")
        spec = importlib.util.spec_from_file_location("color_lut", path)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)

    def test_flog2_decode_published_anchors_and_superwhite(self):
        encoded = np.array([0.092864, 0.39100724, 0.64144017])
        np.testing.assert_allclose(self.m.flog2_decode(encoded), [0, 0.18, 2], atol=2e-7)

    def test_srgb_white_and_gray_keep_neutrality(self):
        # Full-range F-Log2 ends near scene-linear 58.25; do not test past its ceiling.
        levels = np.geomspace(0.00001, 20, 200)
        rgb = np.repeat(levels[:, None], 3, axis=1)
        log = self.m.scene_to_log(rgb)
        out = self.m.ektar(log)
        self.assertTrue(np.isfinite(out).all())
        self.assertTrue((np.diff(out, axis=0) > 0).all())
        self.assertLess(np.max(np.ptp(out, axis=1)), 0.008)
        self.assertTrue((out[-1] > 0.99).all())
        self.assertTrue((out[0] < 0.003).all())

    def test_scene_log_roundtrip_preserves_superwhites(self):
        scene = np.array([[0.18, 0.18, 0.18], [4, 2, 1], [0.04, 0.09, 0.2]])
        actual = self.m.flog2_decode(self.m.scene_to_log(scene)) @ self.m.FGAMUT_TO_SRGB.T
        np.testing.assert_allclose(actual, scene, atol=1e-6)

    def test_cube_r_fast_order_and_interpolation(self):
        values = np.linspace(0, 1, 3)
        b, g, r = np.meshgrid(values, values, values, indexing="ij")
        identity = np.stack([r, g, b], axis=-1)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "identity.cube"
            self.m.write_cube(path, identity, "Identity")
            loaded = self.m.read_cube(path)
            np.testing.assert_allclose(loaded[0, 0, 1], [0.5, 0, 0])
            samples = np.array([[0.125, 0.7, 0.3], [0, 0, 0], [1, 1, 1]])
            np.testing.assert_allclose(self.m.apply_cube(loaded, samples), samples, atol=1e-7)

    def test_65_cube_matches_direct_transform_on_photographic_colors(self):
        values = np.linspace(0, 1, 65)
        b, g, r = np.meshgrid(values, values, values, indexing="ij")
        table = self.m.ektar(np.stack([r, g, b], axis=-1))
        self.assertTrue(np.isfinite(table).all())
        self.assertGreaterEqual(table.min(), 0)
        self.assertLessEqual(table.max(), 1)
        rng = np.random.default_rng(100)
        scene = rng.uniform(0.05, 1, (12000, 3)) * np.exp2(rng.uniform(-3, 2, (12000, 1)))
        log = self.m.scene_to_log(scene)
        error = np.abs(self.m.apply_cube(table, log) - self.m.ektar(log))
        self.assertLess(np.quantile(error, 0.99), 0.012)
        self.assertLess(error.max(), 0.04)

    def test_lut_rejects_incomplete_cube(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "broken.cube"
            path.write_text("LUT_3D_SIZE 2\n0 0 0\n")
            with self.assertRaises(ValueError):
                self.m.read_cube(path)

    def test_delivered_cube_has_required_grid_and_matches_generator(self):
        path = Path(__file__).with_name("EKTAR_100_Phuket_v1_FLog2_FGamut_65.cube")
        table = self.m.read_cube(path)
        self.assertEqual(table.shape, (65, 65, 65, 3))
        self.assertGreaterEqual(table.min(), 0)
        self.assertLessEqual(table.max(), 1)
        rng = np.random.default_rng(65)
        indices = rng.integers(0, 65, (500, 3))
        b, g, r = indices.T
        expected = self.m.ektar(indices[:, ::-1] / 64)
        np.testing.assert_allclose(table[b, g, r], expected, atol=6e-10, rtol=0)


if __name__ == "__main__":
    unittest.main()
