import importlib
import unittest
import numpy as np


class SavedControlTests(unittest.TestCase):
    def module(self):
        try:
            return importlib.import_module("saved_controls")
        except ImportError:
            self.fail("Saved control response functions are not implemented")

    def test_monotonic_curve_recovers_known_mapping_on_unseen_values(self):
        x = np.linspace(0, 1, 4097)
        curve = self.module().fit_curve(x, 0.1 + 0.8 * x)
        np.testing.assert_allclose(self.module().curve_lookup(curve, np.array([.15, .6, .83])),
                                   [.22, .58, .764], atol=2e-4)

    def test_tone_zero_is_identity_and_calibrated_endpoint_is_exact(self):
        c = self.module()
        curves = {"positive": {"x": [0, 1], "y": [0, .8]},
                  "negative": {"x": [0, 1], "y": [.2, 1]}, "amount": .5}
        pixels = np.array([.25, .5, .75])
        np.testing.assert_array_equal(c.apply_curve(pixels, 0, curves), pixels)
        np.testing.assert_allclose(c.apply_curve(pixels, .5, curves), [.2, .4, .6])
        np.testing.assert_allclose(c.apply_curve(pixels, -.5, curves), [.4, .6, .8])
        with self.assertRaises(ValueError):
            c.apply_curve(pixels, 1, curves)

    def test_box_filter_keeps_constant_and_averages_known_impulse(self):
        c = self.module()
        np.testing.assert_allclose(c.box_mean(np.ones((5, 7)), .5), 1)
        impulse = np.zeros((3, 3)); impulse[1, 1] = 9
        np.testing.assert_allclose(c.box_mean(impulse, 1), 1)

    def test_fill_zero_does_not_change_image_and_chunking_keeps_last_row(self):
        c = self.module()
        image = np.full((5, 3, 3), .2)
        model = {"weights": np.zeros((20, 3)).tolist(), "scale": .03}
        model["weights"][0] = [.1, .2, .3]
        np.testing.assert_array_equal(c.apply_fill(image, 0, model), image)
        result = c.apply_fill(image, .5, model, chunk_rows=2)
        np.testing.assert_allclose(result, np.broadcast_to([.25, .3, .35], image.shape))

    def test_spatial_fill_does_not_change_at_processing_chunk_boundaries(self):
        image = np.broadcast_to(np.linspace(.05, .9, 9)[None, :, None], (7, 9, 3)).copy()
        image[3, 4] = .1
        model = {"weights": np.zeros((20, 3)).tolist(), "scale": .4}
        model["weights"][18] = [.3, .2, .1]
        whole = self.module().apply_fill(image, .5, model, chunk_rows=100)
        rows = self.module().apply_fill(image, .5, model, chunk_rows=1)
        np.testing.assert_array_equal(rows, whole)
        self.assertGreater(float(np.max(np.abs(whole - image))), .01)


if __name__ == "__main__":
    unittest.main()
