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
