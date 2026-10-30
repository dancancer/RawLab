import unittest
from pathlib import Path
import json
import hashlib
import io

import numpy as np

from classic_retinex import gain_from_log_map, log_luminance


def verified_native_fixture(payload=None, metadata=None):
    root = Path(__file__).with_name('fixtures') / 'classic-retinex-native'
    if payload is None:
        payload = root.with_suffix('.npz').read_bytes()
    if metadata is None:
        metadata = json.loads(root.with_suffix('.json').read_text())
    if (metadata.get('schema') != 'rawlab-classic-retinex-fixtures-v1'
            or metadata.get('library_sha256') != '99d6d9360f605f0eb83188e8d2acb81cb97d6866df5811ffd8cad9cefb0cb8e1'
            or hashlib.sha256(payload).hexdigest() != metadata.get('fixture_sha256')):
        raise ValueError('Native fixture provenance changed')
    return np.load(io.BytesIO(payload), allow_pickle=False)


class ClassicRetinexTests(unittest.TestCase):
    def test_native_fixture_provenance_rejects_changed_bytes_or_library(self):
        root = Path(__file__).with_name('fixtures') / 'classic-retinex-native'
        payload = root.with_suffix('.npz').read_bytes()
        metadata = json.loads(root.with_suffix('.json').read_text())
        with self.assertRaises(ValueError):
            verified_native_fixture(payload + b'changed', metadata)
        for field in ('schema', 'library_sha256'):
            altered = dict(metadata, **{field: 'different'})
            with self.assertRaises(ValueError):
                verified_native_fixture(payload, altered)

    def test_downscale_matches_native_odd_borders_and_negative_rounding(self):
        from classic_retinex import downscale2x2
        with verified_native_fixture() as data:
            for index in range(2):
                np.testing.assert_array_equal(downscale2x2(data[f'down{index}_input']),
                                              data[f'down{index}_output'])

    def test_smooth_blend_matches_native_parity_edges_and_q8_weights(self):
        from classic_retinex import smooth_double_blend
        with verified_native_fixture() as data:
            for index in range(4):
                result = smooth_double_blend(data[f'smooth{index}_half'], data[f'smooth{index}_full'],
                                             *data[f'smooth{index}_weights'])
                np.testing.assert_array_equal(result, data[f'smooth{index}_output'])

    def test_pyramid_matches_native_at_all_pixels_for_both_orientations(self):
        from classic_retinex import pyramid_filter
        with verified_native_fixture() as data:
            for index in range(3):
                np.testing.assert_array_equal(pyramid_filter(data[f'pyramid{index}_input']),
                                              data[f'pyramid{index}_output'])

    def test_full_log_map_matches_native_ramp_flat_field_and_bright_edges(self):
        from classic_retinex import retinex_log_map
        with verified_native_fixture() as data:
            for index in range(3):
                np.testing.assert_array_equal(retinex_log_map(data[f'map{index}_input']),
                                              data[f'map{index}_output'])

    def test_signed_map_uses_asymmetric_native_quantization(self):
        # lib98 arm64 0x76308–0x764e0：正向的提前终止不能换成对称 exp。
        log_map = np.array([[-32767, -4096, -1024, -256, 0, 256, 1024, 4096, 32767]], np.int16)
        np.testing.assert_array_equal(
            gain_from_log_map(log_map, .5),
            np.array([[132, 132, 151, 215, 256, 305, 434, 497, 497]]) / 256,
        )
        np.testing.assert_array_equal(
            gain_from_log_map(log_map, -.5),
            np.array([[498, 498, 434, 305, 256, 215, 151, 132, 132]]) / 256,
        )

    def test_zero_fill_is_identity_for_all_signed_indices(self):
        log_map = np.arange(-32768, 32768, dtype=np.int16).reshape(256, 256)
        np.testing.assert_array_equal(gain_from_log_map(log_map, 0), np.ones((256, 256)))

    def test_nonzero_fill_rejects_native_uninitialized_endpoint(self):
        with self.assertRaisesRegex(ValueError, '32768'):
            gain_from_log_map(np.array([[-32768]], np.int16), .5)

    def test_log_luminance_uses_native_counts_and_channel_weights(self):
        # 手算：0→round(1024 ln30)，1000→round(1024 ln1030)，先截断亮度。
        rgb = np.array([[[0., 0., 0.], [1000., 1000., 1000.],
                         [4000., 0., 0.], [0., 0., 10000.],
                         [-100., -100., -100.], [40000., 40000., 40000.]]], np.float32)
        np.testing.assert_array_equal(log_luminance(rgb), [[3483, 7104, 7104, 7104, 3483, 10648]])

    def test_invalid_inputs_are_rejected_without_mutation(self):
        for amount in (np.nan, np.inf, -2.01, 2.01, 1j, '0.5'):
            with self.assertRaises(ValueError):
                gain_from_log_map(np.zeros((2, 3), np.int16), amount)
        for values in (np.zeros((2, 3), np.uint16), np.zeros((2, 3), np.float32),
                       np.empty((0, 3), np.int16), np.zeros((2, 3, 1), np.int16)):
            with self.assertRaises(ValueError):
                gain_from_log_map(values, .5)
        for rgb in (np.zeros((2, 3)), np.full((2, 3, 3), np.nan), np.empty((0, 3, 3))):
            with self.assertRaises(ValueError):
                log_luminance(rgb)
        rgb = np.arange(18, dtype=np.float32).reshape(2, 3, 3)
        before = rgb.copy()
        log_luminance(rgb)
        np.testing.assert_array_equal(rgb, before)

    def test_pyramid_rejects_unsupported_dimensions_and_preserves_input(self):
        from classic_retinex import pyramid_filter, smooth_double_blend
        for image in (np.zeros((64, 64), np.int16), np.zeros((2, 128), np.int16),
                      np.full((128, 128), -1, np.int16)):
            with self.assertRaises(ValueError):
                pyramid_filter(image)
        with self.assertRaises(ValueError):
            smooth_double_blend(np.zeros((3, 4), np.int16), np.zeros((8, 8), np.int16), .5, .5)
        for weight in (np.inf, -1, 17, 1j, '0.5'):
            with self.assertRaises(ValueError):
                smooth_double_blend(np.zeros((3, 4), np.int16), np.zeros((6, 8), np.int16), weight, .5)
        source = np.full((128, 193), 1000, np.int16)
        before = source.copy()
        result = pyramid_filter(source)
        np.testing.assert_array_equal(result, before)
        np.testing.assert_array_equal(source, before)


if __name__ == '__main__':
    unittest.main()
