import importlib
import unittest
import numpy as np


class DetailResponseTests(unittest.TestCase):
    def apply(self, image, amount=1., threshold=.002):
        try:
            module = importlib.import_module('detail_response')
        except ImportError:
            self.fail('Luminance detail diagnostic is not implemented')
        return module.apply_detail(image, {'schema': 'rawlab-luma-detail-v1',
                                          'amount': amount, 'threshold': threshold})

    def test_uniform_colors_and_disabled_response_preserve_pixels(self):
        image = np.tile(np.array([.2, .4, .6], dtype=np.float32), (5, 7, 1))
        np.testing.assert_array_equal(self.apply(image), image)
        image[2, 3] += .1
        np.testing.assert_array_equal(self.apply(image, amount=0), image)

    def test_known_edge_increases_local_contrast_without_changing_chroma(self):
        image = np.tile(np.array([.2, .3, .4]), (3, 6, 1))
        image[:, 3:] += .2
        output = self.apply(image, threshold=0)
        # 三点核的跨边界亮度差为 0.2/4；同一增量作用于 RGB。
        np.testing.assert_allclose(output[:, 2], image[:, 2] - .05)
        np.testing.assert_allclose(output[:, 3], image[:, 3] + .05)
        np.testing.assert_allclose(np.diff(output, axis=-1), np.diff(image, axis=-1))
        np.testing.assert_array_equal(output[:, 0], image[:, 0])

    def test_threshold_does_not_amplify_small_fluctuations(self):
        image = np.full((5, 5, 3), .4)
        image[2, 2] += .001
        np.testing.assert_array_equal(self.apply(image), image)

    def test_shared_gamut_limit_preserves_color_differences(self):
        image = np.tile(np.array([.01, .2, .4]), (3, 6, 1))
        image[:, 3:] = [.7, .9, .99]
        output = self.apply(image)
        self.assertTrue(np.all((output >= 0) & (output <= 1)))
        np.testing.assert_allclose(np.diff(output, axis=-1), np.diff(image, axis=-1))

    def test_nonfinite_out_of_range_or_invalid_configuration_is_rejected(self):
        image = np.ones((3, 4, 3)) * .4
        for bad, amount, threshold in [(image * np.nan, 1, .002),
                                       (image + 1, 1, .002),
                                       (image[:, :, :2], 1, .002),
                                       (image, -1, .002), (image, 2, .002),
                                       (image, 1, -.1), (image, 1, float('nan'))]:
            with self.subTest(amount=amount, threshold=threshold), self.assertRaises(ValueError):
                self.apply(bad, amount, threshold)


if __name__ == '__main__': unittest.main()
