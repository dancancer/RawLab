import importlib
import unittest
from saved_settings import parse_saved_settings
from test_saved_settings import x3f_header


class SettingVariantTests(unittest.TestCase):
    def function(self):
        try:
            return importlib.import_module("setting_variants").neutral_variant
        except ImportError:
            self.fail("Controlled setting variants are not implemented")

    def test_variant_changes_only_adjustments_and_retains_sensor_payload_and_wb(self):
        original = x3f_header(wb="Sunlight", rotation=270,
                              settings=[(1, -0.2), (10, 0.3), (7, 0.95), (8, 1), (9, 1)]) + b"SENSOR_AND_CAMF"
        variant = self.function()(original, {"contrast": 0.5})
        self.assertEqual(original[:72], variant[:72])
        self.assertEqual(original[232:], variant[232:])
        settings = parse_saved_settings(variant)
        self.assertEqual(settings.white_balance, "Sunlight")
        self.assertEqual(settings.contrast, 0.5)
        self.assertEqual(settings.exposure, 0)
        self.assertEqual(settings.fill_light, 0)
        self.assertEqual(settings.color_adjustment, (1, 1, 1))
        self.assertAlmostEqual(parse_saved_settings(original).exposure, -0.2)

    def test_unknown_header_slots_survive_controlled_sweep(self):
        original = x3f_header(settings=[(250, 123), (4, 0.4)]) + b"payload"
        result = self.function()(original, {"highlight": -0.5})
        self.assertEqual(result[72], 250)
        self.assertEqual(result[104:108], original[104:108])
        self.assertEqual(parse_saved_settings(result).highlight, -0.5)

    def test_unknown_or_nonfinite_control_is_rejected(self):
        for overrides in ({"unknown": 1}, {"shadow": float("nan")}, {"red": 0}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                self.function()(x3f_header(), overrides)


if __name__ == "__main__":
    unittest.main()
