"""Regression tests for RawLab v0.14.0 BSH darkroom guidance."""

from pathlib import Path
import sys
import unittest

SRC = Path(__file__).resolve().parents[1] / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from rawlab_mcp.bsh_guidance import enrich_bsh_diagnosis


def _base_bsh_payload(**overrides):
    payload = {
        "dimensions": {"width": 1200, "height": 800, "bit_depth": 16, "channels": 3, "sampled_pixels": 960000},
        "luma_zones": {
            "blacks_0_10_pct": 4.0,
            "shadows_10_35_pct": 22.0,
            "midtones_35_65_pct": 46.0,
            "lights_65_90_pct": 22.0,
            "highlights_90_100_pct": 6.0,
            "mean_luma_0_1": 0.48,
            "percentiles_0_1": {"p01": 0.04, "p05": 0.11, "p25": 0.30, "p50": 0.48, "p75": 0.67, "p95": 0.86, "p99": 0.94},
            "percentiles_0_255": {"p01": 10, "p05": 28, "p50": 122, "p95": 219, "p99": 240},
            "dynamic_spread_p95_minus_p05": 0.75,
        },
        "clipping": {
            "shadow_crush_pct": 0.3,
            "white_blowout_pct": 0.2,
            "channel_clip_high_pct": {"any": 0.4, "r": 0.4, "g": 0.1, "b": 0.1},
        },
        "color_balance": {
            "neutral_midtone_coverage_pct": 20.0,
            "r_over_g": 1.0,
            "b_over_g": 0.99,
            "cast_hint": "neutral",
        },
        "saturation": {
            "mean_s_pct": 24.0,
            "p95_s_pct": 52.0,
            "low_sat_pct": 30.0,
            "melting_saturation_pct": 0.1,
            "melting_warning": False,
        },
        "hsl_channels": {
            "orange": {"coverage_pct": 18.0, "mean_hue_deg": 21.0, "mean_sat_pct": 26.0, "mean_brightness_pct": 76.0},
        },
        "samples": [],
    }
    payload.update(overrides)
    return payload


class V014BshGuidanceTests(unittest.TestCase):
    def test_portrait_redness_blotchy_variance_and_sallow_recommend_point_color_and_calibration(self):
        payload = _base_bsh_payload(
            hsl_channels={
                "red": {"coverage_pct": 12.0, "mean_hue_deg": 9.5, "mean_sat_pct": 39.0, "mean_brightness_pct": 74.0},
                "orange": {"coverage_pct": 15.0, "mean_hue_deg": 28.0, "mean_sat_pct": 29.0, "mean_brightness_pct": 75.0},
            },
            samples=[
                {"label": "face_cheek_red", "hsb": {"h_deg": 10.5, "s_pct": 38.0, "b_pct": 76.0}},
                {"label": "face_forehead_sallow", "hsb": {"h_deg": 28.5, "s_pct": 28.0, "b_pct": 74.0}},
            ],
        )
        enriched = enrich_bsh_diagnosis(payload)

        cheek = enriched["samples"][0]["portrait_skin_check"]
        self.assertFalse(cheek["in_window"])
        joined_cheek = " ".join(cheek["hints"])
        self.assertIn("color.point_color", joined_cheek)
        self.assertIn("variance < 0", joined_cheek)
        self.assertIn("color.calibration", joined_cheek)
        self.assertIn("neutral-gray safe", joined_cheek)

        forehead = enriched["samples"][1]["portrait_skin_check"]
        self.assertFalse(forehead["in_window"])
        joined_forehead = " ".join(forehead["hints"])
        self.assertIn("color.point_color", joined_forehead)
        self.assertIn("variance < 0", joined_forehead)
        self.assertIn("color.calibration", joined_forehead)

        pdiag = enriched["portrait_diagnostics"]
        self.assertTrue(pdiag["blotchy_variance_detected"])
        self.assertGreaterEqual(pdiag["hue_spread_deg"], 18.0)
        self.assertIn("color.point_color", pdiag["recommended_controls"])
        self.assertIn("effects.texture", pdiag["recommended_controls"])
        self.assertIn("detail.sharpening.luminance_v2", pdiag["recommended_controls"])
        self.assertIn("detail.sharpening.masking", pdiag["recommended_controls"])

        alerts_joined = " ".join(enriched["auto_diagnostics"])
        self.assertIn("color.point_color", alerts_joined)
        self.assertIn("variance < 0", alerts_joined)
        self.assertIn("masking >= 50", alerts_joined)

    def test_in_window_portrait_keeps_empty_hints_and_exposes_texture_sharpening_v2_guidance(self):
        payload = _base_bsh_payload(
            samples=[
                {"label": "center", "hsb": {"h_deg": 210.0, "s_pct": 40.0, "b_pct": 60.0}},
                {"label": "face_anchor", "hsb": {"h_deg": 20.0, "s_pct": 24.0, "b_pct": 77.0}},
            ],
        )
        enriched = enrich_bsh_diagnosis(payload)

        self.assertNotIn("portrait_skin_check", enriched["samples"][0])
        face = enriched["samples"][1]["portrait_skin_check"]
        self.assertTrue(face["in_window"])
        self.assertEqual(face["hints"], [])
        self.assertIn("effects.texture", face["v014_tools"]["micro_texture_and_sharpening"])
        self.assertIn("detail.sharpening.luminance_v2", face["v014_tools"]["micro_texture_and_sharpening"])
        self.assertIn("detail.sharpening.masking >= 50", face["v014_tools"]["micro_texture_and_sharpening"])

        detail = enriched["v014_guidance"]["detail_and_texture"]
        self.assertEqual(detail["recommended_masking_min"], 50.0)
        self.assertIn("effects.texture", detail["micro_contrast"])
        self.assertIn("detail.sharpening.luminance_v2", detail["luminance_sharpening"])

    def test_film_finish_selective_color_bw_mixer_and_defringe_branches(self):
        # 1. Monochrome / low-saturation scene -> B&W mixer + negative asymmetric grain
        mono_payload = _base_bsh_payload(
            saturation={
                "mean_s_pct": 4.2,
                "p95_s_pct": 11.0,
                "low_sat_pct": 91.5,
                "melting_saturation_pct": 0.0,
                "melting_warning": False,
            },
        )
        mono = enrich_bsh_diagnosis(mono_payload)
        mono_alerts = " ".join(mono["auto_diagnostics"])
        self.assertIn("color.bw.enabled=true", mono_alerts)
        self.assertIn("color.bw.mixer", mono_alerts)
        self.assertIn("negative_asymmetric", mono_alerts)

        film = mono["v014_guidance"]["film_and_color"]
        self.assertTrue(film["monochrome_candidate"])
        self.assertEqual(film["grain_presets"]["tone_curve"], "negative_asymmetric")
        self.assertEqual(film["grain_presets"]["format_presets"], ["135", "120"])
        for ctrl in (
            "effects.halation.amount",
            "effects.bloom.amount",
            "effects.grain.tone_curve",
            "effects.grain.format_preset",
            "color.selective_color",
            "color.bw.enabled",
            "color.bw.mixer",
        ):
            self.assertIn(ctrl, film["recommended_controls"])

        # 2. High-contrast backlit edges -> halation/bloom + axial defringe guidance
        backlit_payload = _base_bsh_payload(
            luma_zones={
                "blacks_0_10_pct": 8.0,
                "shadows_10_35_pct": 25.0,
                "midtones_35_65_pct": 28.0,
                "lights_65_90_pct": 26.0,
                "highlights_90_100_pct": 13.0,
                "mean_luma_0_1": 0.49,
                "percentiles_0_1": {"p01": 0.01, "p05": 0.06, "p25": 0.22, "p50": 0.46, "p75": 0.74, "p95": 0.92, "p99": 0.98},
                "percentiles_0_255": {"p01": 3, "p05": 15, "p50": 117, "p95": 235, "p99": 250},
                "dynamic_spread_p95_minus_p05": 0.86,
            },
            hsl_channels={
                "aqua": {"coverage_pct": 18.0, "mean_hue_deg": 195.0, "mean_sat_pct": 45.0, "mean_brightness_pct": 72.0},
            },
        )
        backlit = enrich_bsh_diagnosis(backlit_payload)
        self.assertTrue(backlit["v014_guidance"]["lens_optics"]["axial_fringing_risk"])
        self.assertIn("geometry.lens.defringe_purple_amount", backlit["v014_guidance"]["lens_optics"]["note"])
        self.assertIn("geometry.lens.defringe_green_amount", backlit["v014_guidance"]["lens_optics"]["note"])
        backlit_alerts = " ".join(backlit["auto_diagnostics"])
        self.assertIn("geometry.lens.defringe_*", backlit_alerts)
        self.assertIn("effects.halation", backlit_alerts)
        self.assertIn("effects.bloom", backlit_alerts)
        self.assertIn("color.selective_color", " ".join(film["notes"]))

    def test_preserves_existing_prepopulated_fields(self):
        pre = _base_bsh_payload(
            auto_diagnostics=["custom-existing"],
            samples=[{
                "label": "face",
                "hsb": {"h_deg": 12.0, "s_pct": 20.0, "b_pct": 75.0},
                "portrait_skin_check": {"in_window": False, "hints": ["custom"]},
            }],
        )
        out = enrich_bsh_diagnosis(pre)
        self.assertEqual(out["auto_diagnostics"], ["custom-existing"])
        self.assertEqual(out["samples"][0]["portrait_skin_check"], {"in_window": False, "hints": ["custom"]})


if __name__ == "__main__":
    unittest.main()
