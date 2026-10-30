import importlib
import math
import struct
import unittest


def x3f_header(wb="Sunlight", rotation=270, settings=()):
    data = bytearray(232)
    struct.pack_into("<4sI", data, 0, b"FOVb", 0x00020002)
    struct.pack_into("<III", data, 28, 2640, 1760, rotation)
    data[40:40 + len(wb)] = wb.encode("ascii")
    for index, (kind, value) in enumerate(settings):
        data[72 + index] = kind
        struct.pack_into("<f", data, 104 + index * 4, value)
    return bytes(data)


class SavedSettingsTests(unittest.TestCase):
    def parser(self):
        try:
            return importlib.import_module("saved_settings").parse_saved_settings
        except ImportError:
            self.fail("X3F saved-settings parser is not implemented")

    def test_saved_white_balance_is_not_replaced_by_capture_property(self):
        data = x3f_header(settings=[(1, -0.2), (10, 0.3), (7, 0.955), (8, 1), (9, 1)])
        original = data + b"WB_DESC\0Auto\0"
        result = self.parser()(original)
        self.assertEqual(result.white_balance, "Sunlight")
        self.assertEqual(result.rotation, 270)
        self.assertEqual((result.width, result.height), (2640, 1760))
        self.assertAlmostEqual(result.exposure, -0.2)
        self.assertAlmostEqual(result.fill_light, 0.3)
        self.assertAlmostEqual(result.color_adjustment[0], 0.955)
        self.assertEqual(result.color_adjustment[1:], (1.0, 1.0))
        self.assertEqual(original, data + b"WB_DESC\0Auto\0")

    def test_unedited_zero_color_slots_mean_no_color_adjustment(self):
        result = self.parser()(x3f_header(wb="Auto", settings=[(7, 0), (8, 0), (9, 0)]))
        self.assertEqual(result.color_adjustment, (1.0, 1.0, 1.0))

    def test_absent_slots_default_to_neutral_settings(self):
        result = self.parser()(x3f_header())
        self.assertEqual(result.exposure, 0)
        self.assertEqual(result.fill_light, 0)
        self.assertEqual(result.color_adjustment, (1.0, 1.0, 1.0))

    def test_saved_tonal_controls_are_independent(self):
        result = self.parser()(x3f_header(settings=[(2, 0.1), (3, 0.2), (4, -0.2), (5, 0.4), (6, 0.5)]))
        for name, expected in [("contrast", 0.1), ("shadow", 0.2), ("highlight", -0.2), ("saturation", 0.4), ("sharpness", 0.5)]:
            self.assertAlmostEqual(getattr(result, name), expected)

    def test_nonfinite_adjustments_are_rejected(self):
        for value in [math.nan, math.inf, -math.inf]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.parser()(x3f_header(settings=[(10, value)]))

    def test_partial_zero_or_negative_color_gains_are_rejected(self):
        for gains in [(0, 1, 1), (-1, 1, 1)]:
            with self.subTest(gains=gains), self.assertRaises(ValueError):
                self.parser()(x3f_header(settings=list(zip([7, 8, 9], gains))))

    def test_invalid_or_truncated_header_is_rejected(self):
        for data in [b"", b"FOVb", b"II*\0" + bytes(228), x3f_header(rotation=45)]:
            with self.subTest(data=data[:8]), self.assertRaises(ValueError):
                self.parser()(data)

    def test_unknown_adjustment_slot_does_not_replace_known_values(self):
        result = self.parser()(x3f_header(settings=[(1, 0.5), (250, 100)]))
        self.assertEqual(result.exposure, 0.5)
        self.assertEqual(result.unknown_adjustments, ((250, 100.0),))

    def test_newer_color_mode_header_is_not_read_as_classic_adjustments(self):
        for version in (0x00020000, 0x00020003, 0x00030000):
            data = bytearray(x3f_header())
            struct.pack_into("<I", data, 4, version)
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.parser()(bytes(data))


if __name__ == "__main__":
    unittest.main()
