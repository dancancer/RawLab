#!/usr/bin/env python3
"""Behavioral gates for the independent P3 candidate and strength diagnostics."""

import unittest
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

import cv2
import numpy as np

import denoise_p3 as p3
import run_denoise_p3_scenarios as scenarios

DISPLAY_PROBE = None
EDGE_FIXTURES = None


class P3StrengthTests(unittest.TestCase):
    def test_clipped_color_edges_do_not_receive_one_sided_luma_sharpening(self):
        source = np.full((128, 320, 3), [1, .02, .08], np.float32)
        source[:, 160:] = [1, .6, .3]
        source = cv2.GaussianBlur(source, (0, 0), 1.)
        source[..., 0] = 1
        result = p3.noise_aware_sharpen(source, 2)[0]
        np.testing.assert_array_equal(result, source)

    def test_edge_limiter_does_not_prefer_a_horizontal_or_vertical_direction(self):
        source = np.full((256, 320, 3), .03, np.float32)
        source[:, 160:] = .7
        source = np.sqrt(cv2.GaussianBlur(source, (0, 0), 1.))
        expected = p3.noise_aware_sharpen(source, 2)[0]
        mirrored = p3.noise_aware_sharpen(source[:, ::-1].copy(), 2)[0][:, ::-1]
        rotated = p3.noise_aware_sharpen(np.rot90(source).copy(), 2)[0]
        np.testing.assert_allclose(mirrored, expected, rtol=0, atol=2e-6)
        np.testing.assert_allclose(np.rot90(rotated, -1), expected, rtol=0, atol=2e-6)

    def test_clean_gray_edges_follow_ordinary_strength_without_noise_compensation(self):
        for width, sigma in ((320, .9), (321, 1.5), (319, 2.5)):
            source = np.full((128, width, 3), .15, np.float32)
            source[:, width // 2:] = .75
            source = cv2.GaussianBlur(source, (0, 0), sigma)
            before = source[64, width // 2, 0] - source[64, width // 2 - 1, 0]
            previous = before
            for amount in (.25, .5, 1, 1.5, 2):
                result, _ = p3.noise_aware_sharpen(source, amount)
                ordinary = p3.ordinary_sharpen(source, amount)
                actual = result[64, width // 2, 0] - result[64, width // 2 - 1, 0]
                target = ordinary[64, width // 2, 0] - ordinary[64, width // 2 - 1, 0]
                self.assertGreaterEqual(actual + 1e-7, previous)
                self.assertLessEqual(abs(actual - target), .03 * (target - before) + 1e-6)
                previous = actual

    def test_channel_limits_do_not_turn_shared_luma_addition_into_new_chroma(self):
        source = np.full((128, 320, 3), [.8, .2, .1], np.float32)
        source[:, 160:] = [.8, .65, .35]
        source = cv2.GaussianBlur(source, (0, 0), 1.5)
        result, _ = p3.noise_aware_sharpen(source, 2)
        delta = result - source
        self.assertLessEqual(float(np.max(np.ptp(delta, axis=2))), 2e-7)
        self.assertTrue(np.all(result >= 0) and np.all(result <= 1))

    def test_out_of_gamut_flat_does_not_force_unclipped_channels_to_follow_clipping(self):
        source = np.full((128, 320, 3), [1.2, .7, -.1], np.float32)
        for amount in (.5, 1, 2):
            result, _ = p3.noise_aware_sharpen(source, amount)
            np.testing.assert_allclose(result, np.broadcast_to([1, .7, 0], result.shape), atol=1e-7)

    def test_equivalent_strength_reports_unreachable_instead_of_saturating(self):
        self.assertTrue(callable(getattr(p3, "equivalent_strength", None)))
        values = [(0., 0.), (.5, .04), (1., .08), (2., .12)]
        self.assertAlmostEqual(p3.equivalent_strength(values, .10)["amount"], 1.5)
        self.assertEqual(p3.equivalent_strength(values, .2)["status"], "UNREACHABLE")
        self.assertIsNone(p3.equivalent_strength(values, .2)["amount"])
        self.assertEqual(p3.equivalent_strength(values, 0)["amount"], 0)

    def test_equivalent_strength_rejects_nonmonotonic_or_invalid_response(self):
        self.assertTrue(callable(getattr(p3, "equivalent_strength", None)))
        for values in ([(0, 0), (1, .1), (2, .05)], [(0, 0)], [(0, 0), (3, .1)],
                       [(0, 0), (1, float("nan"))], [(0, 0), (0, .1)]):
            with self.assertRaises(ValueError):
                p3.equivalent_strength(values, .05)


class P3GateTests(unittest.TestCase):
    def test_added_halo_excludes_input_bias_but_not_new_errors_hidden_by_global_extrema(self):
        self.assertTrue(callable(getattr(scenarios, "added_edge_excursion", None)))
        truth = np.full((128, 320, 3), .2, np.float32)
        truth[:, 160:] = .7
        baseline = truth.copy()
        baseline[:, :160] = .15
        baseline[:, 60] = .1
        self.assertEqual(scenarios.added_edge_excursion(baseline, baseline, truth), 0)
        improved = baseline.copy()
        improved[:, 90] = .18
        self.assertEqual(scenarios.added_edge_excursion(improved, baseline, truth), 0)
        candidate = baseline.copy()
        candidate[:, 90] = .12
        self.assertEqual(scenarios.edge_excursion(candidate, truth), scenarios.edge_excursion(baseline, truth))
        self.assertAlmostEqual(scenarios.added_edge_excursion(candidate, baseline, truth), .03, places=6)

    def test_interpolated_strength_is_not_matched_until_actual_response_agrees(self):
        self.assertTrue(callable(getattr(scenarios, "matched_strength", None)))
        source = np.full((128, 320, 3), .2, np.float32)
        source[:, 160:] = .7
        source = cv2.GaussianBlur(source, (0, 0), 1.5)
        result = scenarios.matched_strength(source, [(0, 0), (2, 10)], 5)
        self.assertEqual(result["status"], "INTERPOLATION_MISMATCH")
        self.assertGreater(result["interpolation_relative_error"], .9)

    def test_report_validation_rejects_wrong_display_domain_geometry_and_paths(self):
        self.assertTrue(callable(getattr(scenarios, "validate_render_report", None)))
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            source = np.full((5, 7, 3), .2, np.float32)
            settings = [{"id": "neutral"}]
            (directory / "neutral").mkdir()
            buffers = {}
            for key in ("off", "ordinary_0.5", "ordinary_1", "ordinary_2"):
                descriptor = scenarios.metrics.write_buffer(directory / "neutral" / (key + ".f32"), source,
                    "display_RGB", "before_sharpen" if key == "off" else "ordinary_sharpen")
                descriptor["bytes"] = source.nbytes
                buffers[key] = descriptor
            report = {"backend": "Metal", "scenarios": [{"settings": settings[0], "buffers": buffers}]}
            scenarios.validate_render_report(report, source.shape, settings, directory)
            for field, value in (("shape", [7, 5, 3]), ("space", "linear_sRGB"), ("stage", "native_decode"),
                                 ("bytes", 0), ("path", buffers["ordinary_1"]["path"]), ("sha256", "0" * 64)):
                broken = json.loads(json.dumps(report))
                broken["scenarios"][0]["buffers"]["off"][field] = value
                with self.assertRaises(ValueError, msg=field):
                    scenarios.validate_render_report(broken, source.shape, settings, directory)

    def test_reuse_rejects_same_input_bytes_with_different_image_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "native").mkdir()
            source = np.arange(5 * 7 * 3, dtype=np.float32).reshape(5, 7, 3)
            descriptor = scenarios.metrics.write_buffer(directory / "input.f32", source, "linear_sRGB", "frozen_input")
            report = {"input_descriptor": descriptor, "scenarios": [], "backend": "Metal"}
            (directory / "native/result.json").write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError, "shape"):
                scenarios.reuse_render(directory, source.reshape(7, 5, 3), [])

    def test_strength_sweep_uses_visible_sdr_baseline_at_zero(self):
        self.assertTrue(callable(getattr(scenarios, "strength_response", None)))
        source = np.full((128, 320, 3), .5, np.float32)
        source[:, 160:] = 1.5
        response = scenarios.strength_response(source, [0, .5, 1, 2])
        self.assertEqual(response, [(0, 0), (.5, 0), (1, 0), (2, 0)])

    def test_edge_response_tracks_the_display_edge_not_the_linear_input_center(self):
        self.assertTrue(callable(getattr(scenarios, "edge_response", None)))
        source = np.zeros((128, 320, 3), np.float32)
        source[:, 158] = .2
        source[:, 159] = .5
        source[:, 160] = .7
        source[:, 161:] = .8
        measured = scenarios.edge_response(source)
        self.assertAlmostEqual(measured["peak_slope"], .3, places=6)
        self.assertAlmostEqual(measured["center_slope"], .2, places=6)
        self.assertEqual(measured["peak_index"], 158)
        self.assertGreater(measured["width_10_90"], 0)

    def test_edge_gate_detects_ringing_inside_original_global_range(self):
        self.assertTrue(callable(getattr(scenarios, "edge_safety", None)))
        source = np.full((128, 320, 3), .2, np.float32)
        source[:, 160:] = .7
        source = cv2.GaussianBlur(source, (0, 0), 2)
        candidate = source.copy()
        candidate[:, 159] += .15
        candidate[:, 160] -= .15
        candidate[:, 145] += .08
        self.assertEqual(scenarios.edge_excursion(candidate, source), 0)
        measured = scenarios.edge_safety(candidate, source)
        self.assertGreater(measured["added_reversal_fraction"], .1)
        self.assertGreater(measured["guard_delta_max"], .07)

    def test_validated_reuse_rejects_different_source_pixels(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "native").mkdir()
            report = {"input_descriptor": {"sha256": "0" * 64}, "scenarios": []}
            (directory / "native/result.json").write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError, "input/settings"):
                scenarios.reuse_render(directory, np.ones((5, 7, 3), np.float32), [])


class FrozenEdgeTests(unittest.TestCase):
    def load_fixture(self, name):
        if EDGE_FIXTURES is None:
            self.skipTest("frozen actual-display edge controls not requested")
        with np.load(EDGE_FIXTURES / (name + ".npz")) as saved:
            return {key: saved[key].copy() for key in saved.files}

    def test_strong_gain_matches_frozen_native_edge_within_three_percent(self):
        data = self.load_fixture("edge-gray-1.0-0")
        source = data["off"]
        candidate = p3.noise_aware_sharpen(source, 2)[0]
        before = scenarios.edge_slope(np.clip(source, 0, 1))
        target = scenarios.edge_slope(data["ordinary_2"]) - before
        self.assertLessEqual(abs(scenarios.edge_slope(candidate) - before - target), .03 * target)

    def test_noisy_tone_edge_does_not_add_more_than_one_percent_reversal(self):
        data = self.load_fixture("edge-gray-1.0-0.005")
        source = data["off"]
        for amount in (1, 2):
            result = p3.noise_aware_sharpen(source, amount)[0]
            safety = scenarios.edge_safety(result, np.clip(source, 0, 1))
            self.assertLessEqual(safety["added_reversal_fraction"], .01)
            self.assertLessEqual(safety["guard_delta_max"], 1 / 255)


class DisplayProbeTests(unittest.TestCase):
    def setUp(self):
        if DISPLAY_PROBE is None:
            self.skipTest("actual display probe not requested")

    def invoke(self, directory, source, scenario):
        path = directory / "input.f32"
        source.astype("<f4").tofile(path)
        request = {"input": {"path": str(path), "width": source.shape[1], "height": source.shape[0]},
                   "output": str(directory / "out"), "scenarios": [scenario]}
        request_path = directory / "request.json"
        request_path.write_text(json.dumps(request))
        self.assertTrue(DISPLAY_PROBE.is_file(), "actual display probe is not built")
        return subprocess.run([str(DISPLAY_PROBE), str(request_path)], text=True, capture_output=True)

    def test_actual_metal_tone_precedes_native_ordinary_sharpen(self):
        source = np.linspace(.01, 1.5, 63 * 65 * 3, dtype=np.float32).reshape(63, 65, 3)
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            result = self.invoke(directory, source, {"id": "tone", "exposure_ev": .7, "shadows": .4,
                                                    "contrast": 1.3, "saturation": .8})
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((directory / "out/result.json").read_text())
            self.assertEqual(report["backend"], "Metal")
            buffers = report["scenarios"][0]["buffers"]
            off = np.fromfile(buffers["off"]["path"], dtype="<f4").reshape(source.shape)
            for amount in (.5, 1, 2):
                native = np.fromfile(buffers[f"ordinary_{amount:g}"]["path"], dtype="<f4").reshape(source.shape)
                np.testing.assert_allclose(native, p3.ordinary_sharpen(off, amount), atol=2e-6, rtol=0)

    def test_invalid_input_or_unknown_tone_does_not_report_success(self):
        for pixels, scenario in ((np.full((5, 7, 3), np.nan), {"id": "bad"}),
                                 (np.full((5, 7, 3), .2), {"id": "bad", "typo_contrast": 1.5})):
            with tempfile.TemporaryDirectory() as tmp:
                result = self.invoke(Path(tmp), pixels, scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((Path(tmp) / "out/result.json").exists())

    def test_actual_lut_and_tone_are_not_a_silent_neutral_render(self):
        source = np.full((35, 39, 3), [.03, .18, .7], np.float32)
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            lut = directory / "constant.cube"
            lut.write_text("# Gamma: sRGB to sRGB\n# Gamut: ITU-R BT.709 to ITU-R BT.709\nLUT_3D_SIZE 2\n" +
                           ".12 .34 .56\n" * 8)
            result = self.invoke(directory, source, {"id": "lut", "lut": str(lut), "lut_strength": 1})
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((directory / "out/result.json").read_text())
            actual = np.fromfile(report["scenarios"][0]["buffers"]["off"]["path"], dtype="<f4").reshape(source.shape)
            np.testing.assert_allclose(actual, np.broadcast_to([.12, .34, .56], actual.shape), atol=2e-6, rtol=0)
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            result = self.invoke(directory, source, {"id": "tone", "saturation": 0})
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((directory / "out/result.json").read_text())
            actual = np.fromfile(report["scenarios"][0]["buffers"]["off"]["path"], dtype="<f4").reshape(source.shape)
            self.assertLess(float(np.ptp(actual, axis=2).max()), 2e-7)

    def test_tone_clipped_flat_noise_cannot_unlock_extra_edge_headroom(self):
        source = next(source for name, _, source, _ in scenarios.synthetic_cases() if name == "flat-0.01-0.02")
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            result = self.invoke(directory, source, {"id": "crush", "shadows": -.6, "contrast": 1.2})
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((directory / "out/result.json").read_text())
            image = np.fromfile(report["scenarios"][0]["buffers"]["off"]["path"], dtype="<f4").reshape(source.shape)
            baseline = np.clip(image, 0, 1)[16:-16, 16:-16]
            for amount in (1, 2):
                candidate = p3.noise_aware_sharpen(image, amount)[0][16:-16, 16:-16]
                self.assertLessEqual(np.var(scenarios.metrics.luma(candidate)), 1.02 * np.var(scenarios.metrics.luma(baseline)))
                self.assertLessEqual(float(np.max(np.abs((candidate - baseline).mean(axis=(0, 1))))), 1e-5)

    def test_colored_film_edge_response_does_not_reverse_with_strength(self):
        source = next(source for name, _, source, _ in scenarios.synthetic_cases() if name == "edge-color-1.0-0")
        setting = scenarios.scenarios(Path(__file__).resolve().parents[1], Path("unused.cube"))[8]
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            result = self.invoke(directory, source, setting)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((directory / "out/result.json").read_text())
            image = np.fromfile(report["scenarios"][0]["buffers"]["off"]["path"], dtype="<f4").reshape(source.shape)
            response = scenarios.strength_response(image, np.linspace(0, 2, 17))
            self.assertTrue(all(b[1] >= a[1] - 1e-7 for a, b in zip(response, response[1:])))

    def test_wide_lifted_edge_does_not_move_guard_band_by_more_than_one_dn(self):
        source = next(source for name, _, source, _ in scenarios.synthetic_cases() if name == "edge-gray-2.0-0")
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            result = self.invoke(directory, source, {"id": "lift", "exposure_ev": 1.5, "shadows": .5})
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((directory / "out/result.json").read_text())
            image = np.fromfile(report["scenarios"][0]["buffers"]["off"]["path"], dtype="<f4").reshape(source.shape)
            candidate = p3.noise_aware_sharpen(image, 2)[0]
            self.assertLessEqual(scenarios.edge_safety(candidate, np.clip(image, 0, 1))["guard_delta_max"], 1 / 255)

    def test_noisy_saturated_color_edge_peak_does_not_weaken(self):
        source = next(source for name, _, source, _ in scenarios.synthetic_cases() if name == "edge-color-1.0-0.005")
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            result = self.invoke(directory, source, {"id": "contrast", "contrast": 1.5, "saturation": 1.4, "tone_curve": .35})
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((directory / "out/result.json").read_text())
            image = np.fromfile(report["scenarios"][0]["buffers"]["off"]["path"], dtype="<f4").reshape(source.shape)
            response = scenarios.strength_response(image, np.linspace(0, 2, 17))
            self.assertTrue(all(b[1] >= a[1] - 1e-7 for a, b in zip(response, response[1:])))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--display-probe", type=Path)
    parser.add_argument("--edge-fixtures", type=Path)
    args, remaining = parser.parse_known_args()
    DISPLAY_PROBE = args.display_probe
    EDGE_FIXTURES = args.edge_fixtures
    unittest.main(argv=[__file__, *remaining])
