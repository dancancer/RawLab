#!/usr/bin/env python3
"""Unit controls for the opt-in AI adapter and display-domain P3 experiments."""

import unittest
from pathlib import Path
import tempfile
import hashlib

import cv2
import numpy as np

import denoise_ai_adapter as ai
import denoise_p3 as p3
import denoise_experiment_metrics as metrics
import run_denoise_experiments as experiments


class AdapterTests(unittest.TestCase):
    def test_frozen_native_stage_labels(self):
        for stage, label in (("frozen_swt_v2", "SWT v2"), ("frozen_swt_legacy", "SWT v1"),
                             ("frozen_c5_v2", "C5 v2")):
            self.assertEqual(experiments.native_label({"experiment": {"buffers": {"swt": {"stage": stage}}}}), label)
        with self.assertRaises(ValueError):
            experiments.native_label({"experiment": {"buffers": {"swt": {"stage": "unknown"}}}})

    def test_black_white_normalization_and_distinct_greens(self):
        metadata = {"black": 100, "cblack": [1, 2, 3, 4, 0, 0], "white": 1100,
                    "pattern": [[0, 1], [3, 2]]}
        raw = np.array([[101, 1100], [1100, 103]], dtype=np.uint16)
        packed, offset = ai.pack_bayer(raw, metadata)
        np.testing.assert_array_equal(packed[:, 0, 0], [0, 1, 1, 0])
        self.assertEqual(offset, (0, 0))
        raw[0, 0] = 0
        self.assertEqual(ai.pack_bayer(raw, metadata)[0][0, 0, 0], 0)
        self.assertLess(ai.pack_bayer(raw, metadata, clip=False)[0][0, 0, 0], 0)

    def test_all_cfa_phases_pack_the_same_rggb_order(self):
        canonical = np.array([[0, 1], [3, 2]])
        for y in (0, 1):
            for x in (0, 1):
                pattern = np.roll(np.roll(canonical, y, axis=0), x, axis=1)
                raw = np.tile(np.take([10, 20, 40, 30], pattern), (5, 5)).astype(np.uint16)
                metadata = {"black": 0, "cblack": [0] * 6, "white": 100, "pattern": pattern.tolist()}
                packed, offset = ai.pack_bayer(raw, metadata)
                np.testing.assert_allclose(packed[:, 0, 0], [.1, .2, .3, .4])
                self.assertEqual(offset, (y, x))

    def test_channel_balanced_anchor_does_not_count_green_twice(self):
        packed = np.broadcast_to(np.array([1., 2., 4., 9.])[:, None, None], (4, 3, 5))
        self.assertEqual(ai.input_anchor(packed, "plane_mean"), 4)
        self.assertAlmostEqual(ai.input_anchor(packed, "camera_rgb_mean"), 13 / 3)

    def test_gain_is_one_input_anchored_scalar_not_reference_or_per_channel_fit(self):
        output = np.broadcast_to(np.array([2., 4., 6.], dtype=np.float32), (4, 5, 3)).copy()
        scaled, gain = ai.match_input_gain(output, .2)
        self.assertAlmostEqual(gain, .05)
        np.testing.assert_allclose(scaled, output * .05)
        negative, negative_gain = ai.match_input_gain(-output, .2)
        self.assertAlmostEqual(negative_gain, -.05)
        np.testing.assert_array_equal(negative, scaled)
        for anchor in (0, -1, float("nan")):
            with self.assertRaises(ValueError):
                ai.match_input_gain(output, anchor)
        with self.assertRaises(ValueError):
            ai.match_input_gain(np.zeros_like(output), .2)

    def test_tiled_identity_and_upscale_cover_short_last_core(self):
        random = np.random.default_rng(41)
        for height, width in ((1, 1), (33, 49), (49, 35)):
            source = random.normal(size=(3, height, width)).astype(np.float32)
            identity = ai.tiled_inference(source, lambda tile: tile, tile_size=32, halo=8, scale=1)
            np.testing.assert_array_equal(identity, source.transpose(1, 2, 0))
            enlarged = ai.tiled_inference(
                source, lambda tile: np.repeat(np.repeat(tile, 2, axis=1), 2, axis=2),
                tile_size=32, halo=8, scale=2)
            expected = np.repeat(np.repeat(source, 2, axis=1), 2, axis=2).transpose(1, 2, 0)
            np.testing.assert_array_equal(enlarged, expected)

    def test_tiling_uses_global_reflection_not_last_core_local_reflection(self):
        source = np.arange(3 * 35 * 49, dtype=np.float32).reshape(3, 35, 49)
        def filter_tile(tile):
            return np.stack([cv2.blur(channel, (3, 3), borderType=cv2.BORDER_REFLECT_101) for channel in tile])
        actual = ai.tiled_inference(source, filter_tile, tile_size=32, halo=8, scale=1)
        expected = filter_tile(source).transpose(1, 2, 0)
        np.testing.assert_allclose(actual, expected, atol=.001)

    def test_all_orientation_flags_are_invertible(self):
        image = np.arange(5 * 7 * 3).reshape(5, 7, 3)
        for flip in range(8):
            np.testing.assert_array_equal(ai.sensor_view(ai.orient(image, flip), flip), image)

    def test_camera_matrix_and_wb_use_row_major_camera_to_native_order(self):
        metadata = {"post_scale_pre_mul": [1, .5, .25, .5],
                    "rgb_cam": [[1, 2, 0], [0, 1, 0], [0, 0, 3]],
                    "native_working_matrix": np.eye(3).tolist()}
        result = ai.camera_to_native(np.array([[[.1, .2, .3]]], dtype=np.float32), metadata)
        np.testing.assert_allclose(result, [[[.6, .2, .45]]], atol=1e-7)
        metadata["rgb_cam"][0][0] = float("nan")
        with self.assertRaises(ValueError):
            ai.camera_to_native(np.ones((2, 2, 3)), metadata)

    def test_memmap_output_is_complete_and_does_not_overwrite(self):
        source = np.ones((3, 5, 7), dtype=np.float32)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "output.f32"
            result = ai.tiled_inference(source, lambda tile: tile, tile_size=16, halo=4, output_path=target)
            self.assertEqual(target.stat().st_size, 5 * 7 * 3 * 4)
            np.testing.assert_array_equal(result, 1)
            del result
            with self.assertRaises(FileExistsError):
                ai.tiled_inference(source, lambda tile: tile, tile_size=16, halo=4, output_path=target)

    def test_input_clipping_mask_has_sensor_dimensions_and_no_phantom_protection(self):
        packed = np.full((4, 7, 9), .2, dtype=np.float32)
        np.testing.assert_array_equal(ai.clipped_input_weight(packed, (16, 20), (1, 1)), 0)
        packed[0, 3, 4] = 1.2
        mask = ai.clipped_input_weight(packed, (16, 20), (1, 1), radius=0)
        self.assertEqual(mask.shape, (16, 20))
        self.assertEqual(mask[7, 9], 1)
        self.assertEqual(mask[0, 0], 0)

    def test_linear_color_roundtrip_preserves_extended_values(self):
        source = np.random.default_rng(12).normal(.3, .7, (13, 17, 3)).astype(np.float32)
        working = ai.linear_to_rec2020(source)
        self.assertLess(float(working.min()), 0)
        self.assertGreater(float(working.max()), 1)
        np.testing.assert_allclose(ai.rec2020_to_linear(working), source, atol=8e-7)

    def test_highlight_fallback_only_uses_input_mask_and_preserves_unmasked_pixels(self):
        native = np.ones((11, 13, 3), dtype=np.float32)
        candidate = native * [1.4, .7, 1.3]
        weight = np.zeros((11, 13), dtype=np.float32)
        weight[5, 6] = 1
        result = ai.highlight_fallback(candidate, native, weight)
        np.testing.assert_array_equal(result[5, 6], native[5, 6])
        np.testing.assert_array_equal(result[0, 0], candidate[0, 0])
        self.assertTrue(np.isfinite(result).all())


class SharpenTests(unittest.TestCase):
    def test_zero_strength_preserves_all_float_bits_including_extended_values(self):
        image = np.random.default_rng(4).normal(size=(17, 19, 3)).astype(np.float32)
        np.testing.assert_array_equal(p3.noise_aware_sharpen(image, 0)[0], image)
        np.testing.assert_array_equal(p3.ordinary_sharpen(image, 0), image)

    def test_constant_and_thin_images_do_not_invent_edges(self):
        for shape in ((1, 1, 3), (1, 37, 3), (41, 1, 3), (35, 27, 3)):
            image = np.full(shape, .25, dtype=np.float32)
            result, _ = p3.noise_aware_sharpen(image, 1)
            np.testing.assert_allclose(result, image, atol=1e-7)

    def test_flat_display_noise_is_not_amplified_like_ordinary_sharpen(self):
        image = (.4 + np.random.default_rng(99).normal(0, .01, (256, 256, 3))).astype(np.float32)
        result, diagnostics = p3.noise_aware_sharpen(image, 1)
        flat = np.s_[16:-16, 16:-16]
        before = np.var(p3.luma(image)[flat])
        self.assertLessEqual(np.var(p3.luma(result)[flat]), before * 1.02)
        self.assertGreater(np.var(p3.luma(p3.ordinary_sharpen(image, 1))[flat]), before * 2)
        self.assertLess(abs(float(np.mean(result - image))), 1e-5)
        self.assertEqual(diagnostics["domain"], "display_RGB_before_sharpen")

    def test_hard_edge_has_no_new_overshoot_or_undershoot(self):
        image = np.full((96, 128, 3), .2, dtype=np.float32)
        image[:, 64:] = .7
        result, _ = p3.noise_aware_sharpen(image, 2)
        self.assertGreaterEqual(float(result.min()), .2 - 1e-6)
        self.assertLessEqual(float(result.max()), .7 + 1e-6)

    def test_blurred_edge_can_get_steeper_without_exceeding_local_range(self):
        image = np.full((96, 128, 3), .2, dtype=np.float32)
        image[:, 64:] = .7
        image = cv2.GaussianBlur(image, (0, 0), 1.5)
        result, _ = p3.noise_aware_sharpen(image, 1)
        before = image[48, 64, 0] - image[48, 63, 0]
        self.assertGreater(result[48, 64, 0] - result[48, 63, 0], before)
        self.assertGreaterEqual(float(result.min()), .2 - 1e-6)
        self.assertLessEqual(float(result.max()), .7 + 1e-6)

    def test_invalid_images_and_strength_fail_before_filtering(self):
        for value in (-1, 2.1, float("nan")):
            with self.assertRaises(ValueError):
                p3.noise_aware_sharpen(np.zeros((3, 3, 3), dtype=np.float32), value)
        for image in (np.zeros((0, 3, 3)), np.zeros((3, 3)), np.full((3, 3, 3), float("nan"))):
            with self.assertRaises(ValueError):
                p3.noise_aware_sharpen(image, 1)


class MeasurementTests(unittest.TestCase):
    def test_full_measurement_roi_is_preserved_when_figure_shows_only_the_center(self):
        source = np.arange(225 * 235 * 3, dtype=np.float32).reshape(225, 235, 3) * 1e-6
        case = {"id": "unit", "regions": [{"id": "full", "kind": "synthetic", "rect": [0, 0, 1, 1]}]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            measured = experiments.selected_figures(root, case, {"SWT v2": source, "candidate": source},
                                                      figure_labels=["SWT v2"])
            self.assertEqual(set(measured[0]["methods"]), {"SWT v2", "candidate"})
            with np.load(root / "measurement-crops.npz") as saved:
                np.testing.assert_array_equal(saved["full__candidate"], source)
            with np.load(root / "selected-crops.npz") as selected:
                self.assertEqual(selected["full__SWT v2"].shape, (192, 192, 3))

    def test_buffer_hash_and_shape_are_checked_before_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pixels.f32"
            pixels = np.arange(18, dtype="<f4").reshape(2, 3, 3)
            pixels.tofile(path)
            descriptor = {"path": str(path), "shape": [2, 3, 3], "dtype": "<f4",
                          "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            loaded = metrics.load_buffer(descriptor)
            np.testing.assert_array_equal(loaded, pixels)
            self.assertFalse(loaded.flags.writeable)
            del loaded
            path.write_bytes(path.read_bytes()[:-4])
            with self.assertRaises(ValueError):
                metrics.load_buffer(descriptor)

    def test_detail_metric_does_not_hide_brightness_bias_or_invent_flat_detail(self):
        x = np.arange(96, dtype=np.float32)[None, :]
        reference = np.repeat(np.repeat((.3 + .03 * np.sin(x * .7))[..., None], 64, axis=0), 3, axis=2)
        result = metrics.measure(reference * 2, reference)
        self.assertAlmostEqual(result["normalized_detail_projection"], 1, places=5)
        self.assertGreater(result["rgb_rmse"], .29)
        self.assertGreater(result["mean_rgb_bias"][0], .29)
        constant = metrics.measure(np.full((8, 8, 3), .2), np.full((8, 8, 3), .1))
        self.assertIsNone(constant["normalized_detail_projection"])

    def test_edge_guard_metric_detects_ringing_inside_global_range(self):
        truth = np.full((96, 128, 3), .2, dtype=np.float32)
        truth[:, 64:] = .7
        ringing = truth.copy()
        ringing[:, 50:55] = .3
        ringing[:, 74:79] = .6
        self.assertEqual(float(ringing.min()), float(truth.min()))
        self.assertEqual(float(ringing.max()), float(truth.max()))
        measured = metrics.edge_profile_metrics(ringing, truth, 64)
        self.assertGreater(measured["guard_max_abs_error"], .09)
        self.assertGreater(measured["guard_rms_error"], .04)
        unchanged = metrics.edge_profile_metrics(truth, truth, 64)
        self.assertEqual(unchanged["guard_max_abs_error"], 0)


if __name__ == "__main__":
    unittest.main()
