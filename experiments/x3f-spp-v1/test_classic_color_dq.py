import hashlib
import io
import json
from pathlib import Path
import unittest

import numpy as np

from classic_color_dq import make_color_dq_luts, transform_counts


def native_fixture(payload=None, metadata=None):
    root = Path(__file__).with_name('fixtures') / 'classic-color-dq-native'
    payload = root.with_suffix('.npz').read_bytes() if payload is None else payload
    metadata = json.loads(root.with_suffix('.json').read_text()) if metadata is None else metadata
    if (metadata.get('schema') != 'rawlab-classic-color-dq-fixtures-v1'
            or metadata.get('library_sha256') != '99d6d9360f605f0eb83188e8d2acb81cb97d6866df5811ffd8cad9cefb0cb8e1'
            or hashlib.sha256(payload).hexdigest() != metadata.get('fixture_sha256')):
        raise ValueError('Native ColorDQ fixture provenance changed')
    return np.load(io.BytesIO(payload), allow_pickle=False)


class ClassicColorDqTests(unittest.TestCase):
    def test_matrix_output_feeds_retinex_without_rounding_integer_boundaries(self):
        from classic_retinex import retinex_log_map
        with native_fixture() as data:
            np.testing.assert_array_equal(retinex_log_map(data['retinex_boundary_input']),
                                          data['retinex_boundary_output'])

    def test_all_native_lut_entries_match_including_zero_channels_and_all_sizes(self):
        with native_fixture() as data:
            sizes = set()
            for index in range(9):
                result = make_color_dq_luts(data[f'lut{index}_strengths'])
                np.testing.assert_array_equal(result, data[f'lut{index}_tables'])
                sizes.add(result.shape[1])
            self.assertEqual(sizes, {512, 1024, 2048, 4096, 8192})

    def test_two_pass_dq_matrix_and_copy_match_native_signed_counts(self):
        with native_fixture() as data:
            for index in range(9):
                source = data[f'case{index}_input']
                original = source.copy()
                output, before_matrix = transform_counts(
                    source, data[f'lut{index}_tables'], data[f'case{index}_matrix'],
                    int(data[f'case{index}_shift']), data[f'case{index}_bias'], data[f'case{index}_bounds'])
                np.testing.assert_array_equal(output, data[f'case{index}_output'])
                np.testing.assert_array_equal(before_matrix, data[f'case{index}_copy'])
                np.testing.assert_array_equal(source, original)

    def test_zero_strength_keeps_counts_until_explicit_matrix_clipping(self):
        pixels = np.array([[[-501, 1, 24001], [-500, 0, 24000]]], np.int16)
        output, before_matrix = transform_counts(pixels, make_color_dq_luts([0, 0, 0]),
                                                np.eye(3, dtype=np.int32) * 4096, 12)
        np.testing.assert_array_equal(before_matrix, pixels)
        np.testing.assert_array_equal(output, [[[-500, 1, 24000], [-500, 0, 24000]]])

    def test_invalid_inputs_fail_instead_of_guessing_calibration(self):
        for strength in ([-1, 1, 1], [1, np.nan, 1], [1, np.inf, 1], [1, 2], [1j, 2, 3]):
            with self.assertRaises(ValueError):
                make_color_dq_luts(strength)
        pixels = np.ones((3, 3), np.int16)
        tables = make_color_dq_luts([10, 10, 10])
        matrix = np.eye(3, dtype=np.int32) * 4096
        invalid = [(pixels.astype(np.float32), tables, matrix, 12, [0, 0, 0], [-500, 24000]),
                   (pixels, tables[:, :500], matrix, 12, [0, 0, 0], [-500, 24000]),
                   (pixels, tables, matrix.astype(float), 12, [0, 0, 0], [-500, 24000]),
                   (pixels, tables, matrix, 0, [0, 0, 0], [-500, 24000]),
                   (pixels, tables, matrix, 32, [0, 0, 0], [-500, 24000]),
                   (pixels, tables, matrix, 12, [0, 0], [-500, 24000]),
                   (pixels, tables, matrix, 12, [0, 0, 0], [-40000, 24000])]
        for args in invalid:
            with self.assertRaises(ValueError):
                transform_counts(*args)

    def test_changed_native_fixture_or_library_is_rejected(self):
        root = Path(__file__).with_name('fixtures') / 'classic-color-dq-native'
        payload = root.with_suffix('.npz').read_bytes()
        metadata = json.loads(root.with_suffix('.json').read_text())
        with self.assertRaises(ValueError):
            native_fixture(payload + b'changed', metadata)
        for field in ('schema', 'library_sha256'):
            with self.assertRaises(ValueError):
                native_fixture(payload, dict(metadata, **{field: 'changed'}))


if __name__ == '__main__':
    unittest.main()
