import unittest

import numpy as np
from PIL import ImageCms

from analyze_scans import to_srgb


class ScanColorTests(unittest.TestCase):
    def test_float_icc_path_keeps_sub_8_bit_precision(self):
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        rgb = np.array([[[.1, .2, .3], [.1001, .2001, .3001], [.8, .8, .8]]], dtype=np.float32)
        result = to_srgb(rgb, profile)
        # Serialized ICC matrix/TRC rounding can differ from the in-memory sRGB profile.
        np.testing.assert_allclose(result, rgb, atol=3e-5)
        self.assertGreater(float((result[0, 1] - result[0, 0]).min()), .00009)


if __name__ == "__main__":
    unittest.main()
