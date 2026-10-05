import struct
import json
import colorsys
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np

from lutools.lutprep.bake import inspect_source, prepare
from lutools.lutprep.color import SRGB_TO_XYZ, srgb_decode, srgb_encode
from lutools.lutprep.dcp import D65, DCPProfile, PROPHOTO_TO_XYZ, SRGB_TO_PROPHOTO, ToneCurve, apply_look_table


def identity_table(hues=2, sats=2, values=2):
    data = np.zeros((values, hues, sats, 3))
    data[..., 1:] = 1
    return data


def rationals(matrix):
    return [(int(round(value * 10_000_000)), 10_000_000) for value in np.asarray(matrix).ravel()]


def write_dcp(path, *, endian="<", table=None, curve=None, encoding=0, extra=None, omit=()):
    table = identity_table() if table is None else table
    curve = [0., 0., 1., 1.] if curve is None else curve
    values, hues, sats, _ = table.shape
    tags = {
        50708: (2, b"Synthetic Camera\0"),
        50722: (10, rationals(np.linalg.inv(SRGB_TO_XYZ))),
        50779: (3, [21]),
        50936: (2, b"Synthetic Look\0"),
        50940: (11, curve),
        50965: (10, rationals(PROPHOTO_TO_XYZ @ SRGB_TO_PROPHOTO)),
        50981: (4, [hues, sats, values]),
        50982: (11, table.ravel().tolist()),
        51108: (4, [encoding]),
    }
    tags.update(extra or {})
    tags = {k: v for k, v in tags.items() if k not in omit}
    start = 8 + 2 + 12 * len(tags) + 4
    entries, payload = [], bytearray()
    formats = {1: "B", 3: "H", 4: "I", 5: "II", 7: "B", 10: "ii", 11: "f"}
    for tag, (kind, data) in sorted(tags.items()):
        if kind == 2:
            raw, count = data, len(data)
        elif kind in (5, 10):
            raw = b"".join(struct.pack(endian + formats[kind], *x) for x in data)
            count = len(data)
        else:
            raw = struct.pack(endian + formats[kind] * len(data), *data)
            count = len(data)
        if len(raw) <= 4:
            field = raw.ljust(4, b"\0")
        else:
            field = struct.pack(endian + "I", start + len(payload))
            payload.extend(raw)
        entries.append(struct.pack(endian + "HHI", tag, kind, count) + field)
    header = (b"II" if endian == "<" else b"MM") + struct.pack(endian + "HI", 0x4352, 8)
    path.write_bytes(header + struct.pack(endian + "H", len(entries)) + b"".join(entries)
                     + b"\0" * 4 + payload)
    return path


class DCPMathTests(unittest.TestCase):
    def test_hue_shift_uses_degrees_and_wraps(self):
        table = identity_table()
        table[..., 0] = 120
        result = apply_look_table(np.array([[.5, 0, 0], [0, 0, .5]]), table, 0)
        np.testing.assert_allclose(result, [[0, .5, 0], [.5, 0, 0]], atol=1e-6)

    def test_tiny_negative_hue_shift_wraps_without_an_invalid_sector(self):
        table = identity_table()
        table[..., 0] = -1e-17
        result = apply_look_table(np.array([[.5, 0, 0]]), table, 0)
        np.testing.assert_allclose(result, [[.5, 0, 0]], atol=1e-12)

    def test_encoded_value_scale_is_applied_before_decode(self):
        table = identity_table()
        table[..., 2] = .5
        rgb = np.array([[.25, 0, 0]])
        actual = apply_look_table(rgb, table, 1)
        np.testing.assert_allclose(actual, [[srgb_decode(srgb_encode(.25) * .5), 0, 0]], atol=2e-6)
        self.assertGreater(abs(actual[0, 0] - .125), .01)

    def test_value_hue_saturation_axes_have_independent_weights(self):
        table = identity_table(4, 3, 3)
        table[1, 1, 2, 0] = 120
        # H=90 degrees, S=1, V=.5 selects exactly that non-symmetric cell.
        actual = apply_look_table(np.array([[.25, .5, 0]]), table, 0)
        np.testing.assert_allclose(actual, [[0, .25, .5]], atol=1e-6)

    def test_hue_interpolation_wraps_last_plane_to_first(self):
        table = identity_table(4, 2, 1)
        table[0, 3, :, 0] = 120
        actual = apply_look_table(np.array([[.5, 0, .25]]), table, 0)
        # H=330 interpolates 1/3 of the 120-degree shift, producing H=10.
        np.testing.assert_allclose(actual, [[.5, 1 / 12, 0]], atol=1e-6)

    def test_tone_curve_uses_natural_cubic_not_linear_interpolation(self):
        curve = ToneCurve(np.array([[0., 0.], [.5, .25], [1., 1.]]))
        np.testing.assert_allclose(curve.evaluate(np.array([.25, .75])), [.078125, .578125], atol=1e-7)

    def test_tone_application_preserves_middle_channel_position(self):
        curve = ToneCurve(np.array([[0., 0.], [.5, .25], [1., 1.]]))
        rgb = np.array([[.75, .5, .25], [.25, .75, .5], [.5, .5, .5]])
        expected = [[.578125, .328125, .078125], [.078125, .578125, .328125], [.25, .25, .25]]
        np.testing.assert_allclose(curve.apply(rgb), expected, atol=1e-7)

    def test_invalid_curve_is_rejected(self):
        for points in ([[0, 0]], [[0, 0], [0, 1]], [[0, 0], [1, 2]]):
            with self.assertRaises(ValueError):
                ToneCurve(np.array(points))


class DCPFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.path = self.root / "synthetic.dcp"

    def test_both_endiannesses_and_identity_look(self):
        rgb = np.array([[.18, .18, .18], [.1, .2, .3]])
        for endian in ("<", ">"):
            profile = DCPProfile.read(write_dcp(self.path, endian=endian))
            self.assertEqual(profile.describe()["source_model"], "Synthetic Camera")
            self.assertEqual(profile.describe()["look_dimensions"], [2, 2, 2])
            np.testing.assert_allclose(profile.evaluate(rgb), srgb_encode(rgb), atol=3e-6)

    def test_byte_profile_name_is_decoded_and_cli_returns_json(self):
        write_dcp(self.path, extra={50936: (1, b"Synthetic \xc3\xa9\0")})
        result = subprocess.run([sys.executable, "-m", "lutools.lutprep", "inspect", str(self.path)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["name"], "Synthetic \u00e9")

    def test_unsupported_profile_name_type_is_an_explicit_error(self):
        write_dcp(self.path, extra={50936: (7, b"Synthetic\0")})
        result = subprocess.run([sys.executable, "-m", "lutools.lutprep", "inspect", str(self.path)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_source_matrices_reconstruct_the_look_table_input(self):
        rgb = np.array([[.1, .2, .3]])
        profile = DCPProfile.read(write_dcp(self.path, extra={
            50722: (10, rationals(np.eye(3))),
            50965: (10, rationals(PROPHOTO_TO_XYZ)),
        }))
        # This virtual camera measures XYZ channels, normalized to a D65 white.
        virtual_camera = (rgb @ SRGB_TO_XYZ.T) / D65
        expected = np.clip(srgb_encode(virtual_camera @ np.linalg.inv(SRGB_TO_PROPHOTO).T), 0, 1)
        np.testing.assert_allclose(profile.evaluate(rgb), expected, atol=3e-6)
        self.assertEqual(profile.describe()["input_calibration_tags"], [50779, 50722, 50965])

    def test_source_matrix_scale_does_not_change_scene_exposure(self):
        rgb = np.array([[.1, .2, .3], [.18, .18, .18]])
        baseline = DCPProfile.read(write_dcp(self.path)).evaluate(rgb)
        profile = DCPProfile.read(write_dcp(self.path, extra={
            50722: (10, rationals(7 * np.linalg.inv(SRGB_TO_XYZ))),
        }))
        np.testing.assert_allclose(profile.evaluate(rgb), baseline, atol=3e-6)

    def test_d65_pair_is_selected_by_illuminant_not_position(self):
        profile = DCPProfile.read(write_dcp(self.path, extra={
            50778: (3, [21]), 50721: (10, rationals(np.linalg.inv(SRGB_TO_XYZ))),
            50964: (10, rationals(PROPHOTO_TO_XYZ @ SRGB_TO_PROPHOTO)),
            50779: (3, [17]), 50722: (10, rationals(np.eye(3))),
        }))
        rgb = np.array([[.1, .2, .3]])
        np.testing.assert_allclose(profile.evaluate(rgb), srgb_encode(rgb), atol=3e-6)
        self.assertEqual(profile.describe()["input_calibration_tags"], [50778, 50721, 50964])

    def test_missing_d65_or_invalid_source_calibration_is_rejected(self):
        for options in ({"omit": (50722,)}, {"omit": (50965,)},
                        {"extra": {50779: (3, [17])}},
                        {"extra": {50778: (3, [21])}},
                        {"extra": {50722: (10, rationals(np.ones((3, 3))))}},
                        {"extra": {50722: (10, rationals(np.eye(2)))}},
                        {"extra": {50965: (10, rationals(np.zeros((3, 3))))}}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                DCPProfile.read(write_dcp(self.path, **options))

    def test_third_illuminant_d65_pair_is_supported(self):
        profile = DCPProfile.read(write_dcp(self.path, extra={
            50779: (3, [17]), 52529: (3, [21]),
            52531: (10, rationals(np.linalg.inv(SRGB_TO_XYZ))),
            52532: (10, rationals(PROPHOTO_TO_XYZ @ SRGB_TO_PROPHOTO)),
        }))
        rgb = np.array([[.1, .2, .3]])
        np.testing.assert_allclose(profile.evaluate(rgb), srgb_encode(rgb), atol=3e-6)
        self.assertEqual(profile.describe()["input_calibration_tags"], [52529, 52531, 52532])

    def test_hue_sat_calibration_cannot_be_silently_skipped(self):
        with self.assertRaisesRegex(ValueError, "HueSat"):
            DCPProfile.read(write_dcp(self.path, extra={50938: (11, [0., 1., 1.])}))

    def test_d65_hue_sat_map_precedes_profile_exposure_and_look(self):
        hsm = identity_table(4, 3, 2)
        hsm[0, :, 1:, 2] = .4
        hsm[1, :, 1:, 2] = 1.2
        hsm[:, 1, 1:, 0] = 35
        look = identity_table(4, 3, 2)
        look[..., 0] = 120
        profile = DCPProfile.read(write_dcp(self.path, table=look, extra={
            50937: (4, [4, 3, 2]), 50938: (11, identity_table(4, 3, 2).ravel().tolist()),
            50939: (11, hsm.ravel().tolist()), 51109: (10, [(1, 1)]), 51110: (4, [1]),
        }))
        rgb = np.array([[.03, .08, .2], [.2, .1, .02]])
        pp = rgb @ profile.input_to_prophoto.T
        calibrated = apply_look_table(pp, hsm, 0)
        expected = apply_look_table(calibrated * 2, look, 0)
        expected = np.clip(srgb_encode(profile.curve.apply(expected) @ np.linalg.inv(SRGB_TO_PROPHOTO).T), 0, 1)
        np.testing.assert_allclose(profile.evaluate(rgb), expected, atol=2e-6)
        self.assertEqual(profile.describe()["hue_sat_map_data_tag"], 50939)
        wrong = apply_look_table(pp * 2, hsm, 0)
        self.assertGreater(abs(wrong - calibrated * 2).max(), .01)

    def test_shared_hue_sat_map_and_absent_look_are_supported(self):
        hsm = identity_table(2, 2, 1)
        hsm[..., 0] = 120
        profile = DCPProfile.read(write_dcp(self.path, omit=(50981, 50982, 51108), extra={
            50937: (4, [2, 2, 1]), 50938: (11, hsm.ravel().tolist()), 51110: (4, [1]),
        }))
        self.assertIsNone(profile.table)
        self.assertEqual(profile.describe()["hue_sat_map_data_tag"], 50938)
        self.assertTrue(np.isfinite(profile.evaluate(np.array([[.1, .2, .3]]))).all())

    def test_missing_tone_requires_explicit_curve_and_black_policy(self):
        write_dcp(self.path, omit=(50940,))
        with self.assertRaisesRegex(ValueError, "ProfileToneCurve.*--tone-curve"):
            DCPProfile.read(self.path)
        with self.assertRaisesRegex(ValueError, "black"):
            DCPProfile.read(self.path, tone_curve=[[0, 0], [1, 1]])
        profile = DCPProfile.read(self.path, tone_curve=[[0, 0], [1, 1]], no_auto_black=True)
        self.assertEqual(profile.describe()["tone_source"], "external")
        self.assertEqual(profile.describe()["black_render_policy"], "omitted-explicitly")
        write_dcp(self.path)
        with self.assertRaisesRegex(ValueError, "replace"):
            DCPProfile.read(self.path, tone_curve=[[0, 0], [1, 1]], no_auto_black=True)

    def test_incomplete_or_triple_hue_sat_calibration_is_rejected(self):
        hsm = identity_table()
        for extra in ({50939: (11, hsm.ravel().tolist())},
                      {50938: (11, hsm.ravel().tolist()), 52529: (3, [21])}):
            write_dcp(self.path, extra={50937: (4, [2, 2, 2]), 51110: (4, [1]), **extra})
            with self.assertRaises(ValueError):
                DCPProfile.read(self.path)

    def test_unselected_hue_sat_table_must_still_be_valid(self):
        data = identity_table(2, 2, 1).ravel().tolist()
        for slot in (1, 2):
            for malformed in ([], [0.]):
                extra = {50937: (4, [2, 2, 1]), 51110: (4, [1]),
                         50938: (11, data if slot == 1 else malformed),
                         50939: (11, malformed if slot == 1 else data)}
                if slot == 1:
                    extra.update({50778: (3, [21]), 50779: (3, [17]),
                                  50721: (10, rationals(np.linalg.inv(SRGB_TO_XYZ))),
                                  50964: (10, rationals(PROPHOTO_TO_XYZ @ SRGB_TO_PROPHOTO))})
                write_dcp(self.path, extra=extra)
                with self.subTest(slot=slot, data=malformed), self.assertRaises(ValueError):
                    DCPProfile.read(self.path)

    def test_profile_exposure_can_be_explicitly_excluded(self):
        profile = DCPProfile.read(write_dcp(self.path, extra={51109: (10, [(-1, 1)])}))
        rgb = np.full((1, 3), .18)
        np.testing.assert_allclose(profile.evaluate(rgb), srgb_encode(rgb * .5), atol=3e-6)
        np.testing.assert_allclose(profile.evaluate(rgb, apply_exposure=False), srgb_encode(rgb), atol=3e-6)

    def test_zero_saturation_value_scale_is_normalized(self):
        table = identity_table()
        table[:, :, 0, 2] = .2
        profile = DCPProfile.read(write_dcp(self.path, table=table))
        np.testing.assert_allclose(profile.evaluate(np.full((1, 3), .18)),
                                   srgb_encode(np.full((1, 3), .18)), atol=3e-6)

    def test_omitted_zero_saturation_plane_is_reconstructed(self):
        table = identity_table(3, 3, 2)
        profile = DCPProfile.read(write_dcp(self.path, table=table,
                                          extra={50982: (11, table[:, :, 1:].ravel().tolist())}))
        rgb = np.array([[.18, .18, .18], [.1, .4, .2]])
        np.testing.assert_allclose(profile.evaluate(rgb), srgb_encode(rgb), atol=3e-6)

    def test_truncated_or_invalid_ifd_is_rejected(self):
        valid = write_dcp(self.path).read_bytes()
        for data in (valid[:10], valid[:-1], b"not a profile", valid[:4] + b"\xff" * 4 + valid[8:]):
            self.path.write_bytes(data)
            with self.assertRaises(ValueError):
                DCPProfile.read(self.path)

    def test_missing_look_and_unsupported_encoding_are_rejected(self):
        for options in ({"omit": (50982,)}, {"encoding": 2},
                        {"extra": {52543: (4, [1])}}, {"extra": {52551: (4, [1])}}):
            with self.assertRaises(ValueError):
                DCPProfile.read(write_dcp(self.path, **options))

    def test_inspect_and_prepare_dcp_are_separate_from_generic_contract(self):
        write_dcp(self.path)
        self.assertEqual(inspect_source(self.path)["format"], "dcp")
        dest = self.root / "look.cube"
        report = prepare(self.path, dest, size=9, allow_approximation=True, dcp_exposure=False)
        self.assertEqual(report["mode"], "dcp-look")
        self.assertFalse(report["dcp"]["apply_profile_exposure"])
        self.assertTrue(inspect_source(dest)["canonical"])

    @unittest.skipUnless(os.environ.get("RAWLAB_TEST_CANON_DCP"), "Optional local Canon R5 Standard profile")
    def test_real_canon_profile_does_not_turn_dji_blue_sky_purple(self):
        profile = DCPProfile.read(os.environ["RAWLAB_TEST_CANON_DCP"])
        self.assertEqual(profile.source_model, "Canon EOS R5")
        # Mean scene-linear RGB from the DJI regression's blue-sky region.
        sky = np.array([[.04202286899, .09458850324, .26337432861]])
        hue = colorsys.rgb_to_hsv(*profile.evaluate(sky)[0])[0] * 360
        self.assertGreater(hue, 190)
        self.assertLess(hue, 240)


if __name__ == "__main__":
    unittest.main()
