import tempfile
import unittest
from pathlib import Path

import numpy as np

import generate as look


def lab(rgb):
    linear = np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055) ** 2.4)
    return look.base.linear_to_oklab(linear)


class StrongerLookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = look.make_table()

    def test_original_default_is_unchanged(self):
        scene = np.array([[.045] * 3, [.18] * 3, [.72] * 3, [.035, .14, .36],
                          [.08, .22, .045], [.5, .28, .18], [.3, .035, .016]])
        expected = [[.16205964206351386, .16205964190270292, .16205964146741778],
                    [.4596274271229483, .45962742651284666, .45962742486141356],
                    [.8392629002150774, .8392629000563211, .8392628996265936],
                    [.07324385281156623, .3906315137647175, .6420781815042074],
                    [.27387495205151036, .5057142660861313, .11433968681133697],
                    [.7531266349285879, .592187719040477, .462605746329451],
                    [.5964432011151231, .15724540652796717, .0804092621963165]]
        np.testing.assert_allclose(look.base.ektar(look.base.scene_to_log(scene)), expected, atol=1e-12)

    def test_more_contrast_without_exposure_shift(self):
        gray = look.base.PARAMETERS['middle_gray']
        encoded = look.base.scene_to_log(np.repeat((gray * np.array([.25, 1, 4]))[:, None], 3, axis=1))
        before, after = look.base.ektar(encoded), look.render(encoded)
        self.assertLess(after[0].mean(), before[0].mean() - .015)
        self.assertGreater(after[2].mean(), before[2].mean() + .015)
        np.testing.assert_allclose(after[1], before[1], atol=1e-8)

    def test_blue_and_green_have_more_color_separation(self):
        # Moderate chroma probes leave room for enhancement without forcing out-of-gamut colors.
        encoded = look.base.scene_to_log(np.array([[.07, .14, .22], [.13, .22, .1]]))
        before, after = lab(look.base.ektar(encoded)), lab(look.render(encoded))
        ratio = np.linalg.norm(after[:, 1:], axis=1) / np.linalg.norm(before[:, 1:], axis=1)
        self.assertTrue(np.all(ratio > 1.05), ratio)
        self.assertTrue(np.all(ratio < 1.5), ratio)

    def test_skin_hue_and_color_stay_controlled(self):
        encoded = look.base.scene_to_log(np.array([[.5, .28, .18], [.26, .12, .07], [.7, .45, .32]]))
        before, after = lab(look.base.ektar(encoded)), lab(look.render(encoded))
        hue_before = np.arctan2(before[:, 2], before[:, 1])
        hue_after = np.arctan2(after[:, 2], after[:, 1])
        hue_delta = np.angle(np.exp(1j * (hue_after - hue_before)))
        self.assertLess(np.max(np.abs(np.rad2deg(hue_delta))), 4)
        self.assertLess(np.max(np.abs(after[:, 0] - before[:, 0])), .035)
        self.assertLess(np.max(np.linalg.norm(after[:, 1:], axis=1) /
                               np.linalg.norm(before[:, 1:], axis=1)), 1.15)

    def test_gray_ramp_is_neutral_and_continuous(self):
        scene = np.repeat(np.geomspace(.18 * 2 ** -7, .18 * 2 ** 7, 241)[:, None], 3, axis=1)
        result = look.base.apply_cube(self.table, look.base.scene_to_log(scene))
        steps = np.diff(result, axis=0)
        # Trilinear interpolation may wobble by less than one 16-bit code near black.
        self.assertGreaterEqual(steps.min(), -1 / 65535)
        self.assertTrue(np.all(result[:-1][np.any(steps < 0, axis=1)] < .001))
        self.assertLess(np.ptp(result, axis=1).max(), .008)
        self.assertTrue(np.all(result[-1] > .99))

    def test_65_grid_is_finite_and_in_display_range(self):
        self.assertEqual(self.table.shape, (65, 65, 65, 3))
        self.assertTrue(np.isfinite(self.table).all())
        self.assertGreaterEqual(self.table.min(), 0)
        self.assertLessEqual(self.table.max(), 1)

    def test_interpolation_error_stays_bounded(self):
        rng = np.random.default_rng(100)
        scene = rng.uniform(.05, 1, (12000, 3)) * np.exp2(rng.uniform(-3, 2, (12000, 1)))
        encoded = look.base.scene_to_log(scene)
        error = np.abs(look.base.apply_cube(self.table, encoded) - look.render(encoded))
        self.assertLess(np.quantile(error, .99), .012)
        self.assertLess(error.max(), .04)

    def test_delivered_cube_roundtrip_and_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / look.FILENAME
            look.write(output, self.table)
            np.testing.assert_allclose(look.base.read_cube(output), self.table, atol=5.01e-10, rtol=0)
            header = output.read_text().splitlines()[:12]
            self.assertIn('#Gamma:F-Log2 to EKTAR 100 Phuket', header)
            self.assertIn('#Gamut:F-Gamut to ITU-R BT.709', header)
            self.assertIn('v2 Strong', header[0])


if __name__ == '__main__':
    unittest.main()
