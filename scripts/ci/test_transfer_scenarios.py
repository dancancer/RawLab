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
NOTICES = {"ignored_raw_denoise", "ignored_post_rgb_denoise", "retained_target_processing_version"}


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
        self.assertEqual(set(ignored["ios"]), {"ignored_raw_denoise"})
        self.assertEqual(set(ignored["android"]), {"ignored_raw_denoise", "ignored_post_rgb_denoise"})
        self.assertEqual(set(ignored["windows"]), {"ignored_raw_denoise", "ignored_post_rgb_denoise"})
        retained = by_id["sdr-source-v1-pasted-retains-target-version"]["expect"]["notices"]
        self.assertEqual(retained, ["retained_target_processing_version"])

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
