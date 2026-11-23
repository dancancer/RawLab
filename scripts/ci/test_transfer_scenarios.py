"""Contract for the shared adjustment-transfer scenario fixture.

The fixture carries a target seed plus the expected paste outcome, which the
older transfer fixture cannot express. Four platforms will read it, so the
shape has to stay stable even when only one platform is edited at a time.
"""
import json
from pathlib import Path
import unittest


FIXTURE = Path(__file__).parents[2] / "Shared" / "fixtures" / "adjustment-transfer-scenarios-v1.json"
PLATFORMS = {"macos", "ios", "android", "windows"}
TARGET_KINDS = {"sdr_raw", "sdr_raster", "hdr"}
STATUSES = {"applied", "unchanged", "rejected"}
REASONS = {"incompatible", "unrepresentable", "missing_look"}
NOTICES = {"ignored_target_denoise", "ignored_raw_denoise", "ignored_post_rgb_denoise", "retained_target_processing_version"}


class TransferScenarioContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(FIXTURE.read_text(encoding="utf-8"))
        cls.scenarios = cls.document["scenarios"]

    def test_fixture_declares_its_version_and_is_not_empty(self):
        self.assertEqual(self.document["fixture_version"], 1)
        self.assertGreater(len(self.scenarios), 0)

    def test_scenario_ids_are_unique(self):
        seen = [scenario["id"] for scenario in self.scenarios]
        self.assertEqual(len(seen), len(set(seen)), "duplicate scenario id")

    def test_every_scenario_seeds_a_target_and_expects_an_outcome(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                self.assertIn(scenario["target"]["kind"], TARGET_KINDS)
                self.assertIsInstance(scenario["payload"], dict)
                self.assertIn(scenario["expect"]["status"], STATUSES)

    def test_rejections_name_a_reason_and_acceptances_do_not(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                expect = scenario["expect"]
                if expect["status"] == "rejected":
                    self.assertIn(expect.get("reason"), REASONS, "rejection without a known reason")
                else:
                    self.assertNotIn("reason", expect)

    def test_expected_values_are_dotted_field_paths(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                for key in scenario["expect"].get("values", {}):
                    self.assertIn(".", key, "expected value key is not a field path")

    def test_platform_scoping_uses_known_names(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                self.assertLessEqual(set(scenario.get("platforms", PLATFORMS)), PLATFORMS)
                self.assertLessEqual(set(scenario.get("platform_expect", {})), PLATFORMS)
                for override in scenario.get("platform_expect", {}).values():
                    self.assertIn(override["status"], STATUSES)

    def test_notice_expectations_use_known_notice_ids(self):
        for scenario in self.scenarios:
            expect = scenario["expect"]
            by_platform = expect.get("notices_by_platform", {})
            self.assertLessEqual(set(by_platform), PLATFORMS, "unknown platform in notices_by_platform")
            declared = set(expect.get("notices", []))
            for names in by_platform.values():
                self.assertIsInstance(names, list)
                declared |= set(names)
            self.assertLessEqual(declared, NOTICES, "unknown notice id in expect notices")

    def test_q3_q4_scenarios_declare_per_platform_notice_expectations(self):
        # Q3/Q4：不支持键忽略与处理版本沿用必须由共享 fixture 显式声明四端提示预期。
        by_id = {scenario["id"]: scenario for scenario in self.scenarios}
        ignored = by_id["raw-source-nonzero-legacy-denoise-pasted"]["expect"]["notices_by_platform"]
        self.assertEqual(set(ignored), PLATFORMS, "Q3 scenario must declare notices for all four platforms")
        self.assertEqual(set(ignored["macos"]), {"ignored_post_rgb_denoise"})
        self.assertEqual(set(ignored["ios"]), {"ignored_raw_denoise", "ignored_post_rgb_denoise"})
        self.assertEqual(set(ignored["android"]), {"ignored_raw_denoise", "ignored_post_rgb_denoise"})
        self.assertEqual(set(ignored["windows"]), {"ignored_raw_denoise", "ignored_post_rgb_denoise"})
        retained = by_id["sdr-source-v1-pasted-retains-target-version"]["expect"]["notices"]
        self.assertEqual(retained, ["retained_target_processing_version"])

    def test_unsupported_denoise_targets_keep_shared_coverage(self):
        by_id = {scenario["id"]: scenario for scenario in self.scenarios}
        for name in ("unsupported-raster-denoise-keeps-other-edits",
                     "unsupported-non-bayer-fbdd-keeps-other-edits"):
            self.assertEqual(set(by_id[name].get("platforms", PLATFORMS)), PLATFORMS)
            self.assertEqual(by_id[name]["expect"]["status"], "applied")
            self.assertIn("ignored_raw_denoise", by_id[name]["expect"]["notices"])
        for name in ("ai-target-ignores-denoise-keeps-other-edits",
                     "ai-target-neutral-denoise-preserves-dormant-settings",
                     "ai-target-denoise-only-ignored-with-notice"):
            scenario = by_id[name]
            self.assertEqual(set(scenario["platforms"]), {"macos", "windows"})
            self.assertTrue(scenario["target"]["ai_denoise_enabled"])
            self.assertIn("detail.denoise.wavelet", scenario["payload"]["values"])
        self.assertEqual(by_id["ai-target-neutral-denoise-preserves-dormant-settings"]["expect"]["notices"], [])

    def test_hdr_intensity_scenarios_declare_protocol_expectations(self):
        # P1① 补票：HDR 强度粘贴向量必须以 v2 payload 消费，并登记跨端 HDR 降级语义。
        by_id = {scenario["id"]: scenario for scenario in self.scenarios}
        for scenario_id in ("hdr-common-scalar-intensity-paste-on-hdr-target",
                            "hdr-rendition-group-paste-on-hdr-target",
                            "hdr-mixed-common-and-rendition-paste-on-hdr-target"):
            scenario = by_id[scenario_id]
            with self.subTest(scenario=scenario_id):
                self.assertEqual(scenario["target"]["kind"], "hdr")
                payload = scenario["payload"]
                self.assertEqual((payload["payload_version"], payload["scope_version"]), (2, 2))
                self.assertIsNotNone(payload["source"].get("hdr_processing_version"))
                self.assertTrue(any(key.startswith("hdr.") for key in payload["values"]),
                                "HDR scenario must carry at least one hdr.* field")
                self.assertEqual(scenario["expect"]["status"], "applied")
                self.assertTrue(set(payload["values"]) <= set(scenario["expect"]["values"]),
                                "expected protocol values must cover the pasted HDR fields")
        rejected = by_id["hdr-rendition-group-rejected-on-sdr-target"]
        self.assertNotEqual(rejected["target"]["kind"], "hdr")
        self.assertTrue(any(key.startswith("hdr.") for key in rejected["payload"]["values"]))
        self.assertEqual(rejected["payload"]["payload_version"], 2)
        self.assertEqual(rejected["expect"], {"status": "rejected", "reason": "incompatible"})

    def test_sdr_recipe_strength_paste_on_hdr_declares_nonidentity_conversion(self):
        # A17/P1-10：v1 带配方源粘到 HDR 目标必须按来源强度对五共享标量做非恒等换算。
        by_id = {scenario["id"]: scenario for scenario in self.scenarios}
        scaled = by_id["sdr-recipe-strength-scalars-paste-on-hdr-target"]
        payload = scaled["payload"]
        self.assertEqual(scaled["target"]["kind"], "hdr")
        self.assertEqual(payload["payload_version"], 1)
        recipe = payload["source"].get("recipe")
        self.assertIsNotNone(recipe, "A17 vector must carry source.recipe")
        self.assertEqual(recipe["strength"], 0.5)
        self.assertEqual(scaled["expect"]["status"], "applied")
        values, expect = payload["values"], scaled["expect"]["values"]
        self.assertEqual(set(values), set(expect))
        self.assertNotEqual(values, expect, "recipe-strength conversion must be non-identity")
        for key, value in values.items():
            identity = 1.0 if key in ("light.contrast", "color.saturation") else 0.0
            self.assertAlmostEqual(expect[key], identity + (value - identity) * recipe["strength"],
                                   places=9, msg=key)
        plain = by_id["sdr-plain-scalars-paste-on-hdr-target-unscaled"]
        self.assertEqual(plain["target"]["kind"], "hdr")
        self.assertIsNone(plain["payload"]["source"].get("recipe"))
        self.assertEqual(plain["expect"]["status"], "applied")
        self.assertEqual(plain["expect"]["values"], plain["payload"]["values"])

    def test_post_rgb_is_hdr_only_across_all_platforms(self):
        # D-02/W-A2a：detail.denoise.post_rgb 四端仅在 HDR 建模；SDR 目标必须忽略非零请求并回吐 0。
        by_id = {scenario["id"]: scenario for scenario in self.scenarios}
        self.assertNotIn("raster-all-preserves-ios-post-rgb-denoise", by_id)
        self.assertNotIn("raster-post-rgb-zero-unchanged-on-ios-raw", by_id)
        for scenario in self.scenarios:
            if scenario["target"]["kind"] == "hdr":
                continue
            for expect in (scenario["expect"], *scenario.get("platform_expect", {}).values()):
                values = expect.get("values") or {}
                if "detail.denoise.post_rgb" in values:
                    self.assertEqual(values["detail.denoise.post_rgb"], 0, scenario["id"])
        sdr_all = by_id["sdr-raw-all-ignores-seeded-post-rgb-denoise"]
        self.assertEqual(set(sdr_all.get("platforms", PLATFORMS)), PLATFORMS)
        self.assertEqual(sdr_all["target"]["kind"], "sdr_raw")
        self.assertEqual(sdr_all["expect"]["status"], "applied")
        self.assertEqual(sdr_all["expect"]["notices"], [])
        self.assertEqual(sdr_all["expect"]["values"]["detail.denoise.post_rgb"], 0)
        sdr_ignored = by_id["sdr-post-rgb-nonzero-ignored-unchanged-on-raw"]
        self.assertEqual(set(sdr_ignored.get("platforms", PLATFORMS)), PLATFORMS)
        self.assertEqual(sdr_ignored["target"]["kind"], "sdr_raw")
        self.assertEqual(sdr_ignored["expect"]["status"], "unchanged")
        self.assertEqual(sdr_ignored["expect"]["notices"], ["ignored_post_rgb_denoise"])
        self.assertEqual(sdr_ignored["expect"]["values"], {"detail.denoise.post_rgb": 0})
        hdr_applied = by_id["hdr-v6-post-rgb-denoise-applies"]
        self.assertEqual(set(hdr_applied.get("platforms", PLATFORMS)), PLATFORMS)
        self.assertEqual(hdr_applied["target"]["kind"], "hdr")
        self.assertEqual(hdr_applied["expect"]["status"], "applied")
        self.assertEqual(hdr_applied["expect"]["values"], {"detail.denoise.post_rgb": 0.25})

    def test_seed_payloads_are_full_payloads(self):
        for scenario in self.scenarios:
            seed = scenario["target"].get("seed_payload")
            if seed is None:
                continue
            with self.subTest(scenario=scenario["id"]):
                self.assertEqual(set(seed) - {"payload_version", "scope_version", "source", "values"}, set())
                self.assertIn("source", seed)
                self.assertIn("values", seed)


if __name__ == "__main__":
    unittest.main()
