import importlib
import unittest
import numpy as np


class CalibrationTests(unittest.TestCase):
    def module(self):
        try:
            return importlib.import_module("calibration")
        except ImportError:
            self.fail("Calibration measurement functions are not implemented")

    def test_srgb_reference_white_black_and_red_in_lab(self):
        lab = self.module().srgb_to_lab(np.array([[0, 0, 0], [1, 1, 1], [1, 0, 0]], dtype=float))
        np.testing.assert_allclose(lab, [[0, 0, 0], [100, 0, 0], [53.2408, 80.0925, 67.2032]], atol=0.001)

    def test_saved_270_degree_rotation_keeps_pixel_correspondence(self):
        source = np.array([[1, 2], [3, 4], [5, 6]])
        np.testing.assert_array_equal(self.module().rotate_saved(source, 270), [[2, 4, 6], [1, 3, 5]])

    def test_linear_averaging_does_not_average_encoded_srgb(self):
        source = np.array([[[0., 0., 0.], [1., 1., 1.]], [[0., 0., 0.], [1., 1., 1.]]])
        result = self.module().reduce_reference(source, 2)
        np.testing.assert_allclose(result, [[[0.73535698] * 3]], atol=1e-7)

    def test_first_degree_fit_recovers_known_color_mapping_on_unseen_values(self):
        c = self.module()
        rng = np.random.default_rng(917)
        source = rng.uniform(0.03, 0.8, (200, 3))
        target = source @ np.array([[0.8, 0.1, 0.0], [0.1, 0.8, 0.1], [0.0, 0.1, 0.8]]) + 0.02
        weights = c.fit_polynomial(source, target, 1)
        unseen = np.array([[0.12, 0.22, 0.51], [0.41, 0.35, 0.10]])
        expected = np.array([[0.138, 0.259, 0.450], [0.383, 0.351, 0.135]])
        np.testing.assert_allclose(c.predict_polynomial(unseen, weights, 1), expected, atol=1e-6)

    def test_measurement_reports_nonzero_error_and_rejects_shape_mismatch(self):
        c = self.module()
        a = np.full((3, 4, 3), 0.3)
        b = a.copy(); b[..., 0] += 0.1
        self.assertEqual(c.measure(a, a)["delta_e76_p90"], 0)
        self.assertGreater(c.measure(a, b)["delta_e76_p90"], 5)
        with self.assertRaises(ValueError):
            c.measure(a, b[:2])

    def test_display_clipping_does_not_hide_unbounded_model_error(self):
        result = self.module().measure(np.array([[1.2, -0.1, 0.5]]), np.array([[1., 0., 0.5]]))
        self.assertAlmostEqual(result["rgb_mae_255"], 0)
        self.assertAlmostEqual(result["unclipped_rgb_mae_255"], 25.5)
        self.assertAlmostEqual(result["below_zero_channel_fraction"], 1 / 3)
        self.assertAlmostEqual(result["above_one_channel_fraction"], 1 / 3)


if __name__ == "__main__":
    unittest.main()
