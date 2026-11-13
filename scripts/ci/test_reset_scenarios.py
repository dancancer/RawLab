"""Contract for the shared reset-scenario fixture (P1 step 3).

The fixture pins what "reset" must mean on one shared scenario vector: a seeded
target state, the production reset scope, and the expected post-reset values in
protocol space. Expectations are expressed as ``@spec_default`` references into
``Shared/specs/adjustment-fields-v1.json`` so no platform test hardcodes its own
reset numbers. Four platforms read it, so the shape must stay stable.
"""
import json
from pathlib import Path
import unittest


FIXTURE = Path(__file__).parents[2] / "Shared" / "fixtures" / "reset-scenarios-v1.json"
SPEC = Path(__file__).parents[2] / "Shared" / "specs" / "adjustment-fields-v1.json"
PLATFORMS = {"macos", "ios", "android", "windows"}
TARGET_KINDS = {"sdr_raw", "hdr"}
SCOPE_KINDS = {"tool", "group", "all"}
TOOL_FIELDS = {"light.contrast", "detail.sharpening"}
GROUPS = {"light", "color", "geometry", "hdr_rendition"}
STATUSES = {"changed", "unchanged", "blocked"}
MARKERS = {"@spec_default"}


class ResetScenarioContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(FIXTURE.read_text(encoding="utf-8"))
        cls.scenarios = cls.document["scenarios"]
        spec = json.loads(SPEC.read_text(encoding="utf-8"))
        cls.transferable = {row["field_id"] for row in spec["fields"] if row["protocol"]["transferable"]}
        cls.hdr_only = {row["field_id"] for row in spec["fields"]
                        if row["protocol"]["transferable"] and row["protocol"].get("hdr_only")}

    def test_fixture_declares_its_version_and_is_not_empty(self):
        self.assertEqual(self.document["fixture_version"], 1)
        self.assertGreater(len(self.scenarios), 0)

    def test_scenario_ids_are_unique(self):
        seen = [scenario["id"] for scenario in self.scenarios]
        self.assertEqual(len(seen), len(set(seen)), "duplicate scenario id")

    def test_scope_uses_the_reset_vocabulary(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                scope = scenario["scope"]
                self.assertIn(scope["kind"], SCOPE_KINDS)
                if scope["kind"] == "tool":
                    self.assertIn(scope["field"], TOOL_FIELDS)
                elif scope["kind"] == "group":
                    self.assertIn(scope["group"], GROUPS)
                else:
                    self.assertEqual(set(scope), {"kind"})

    def test_targets_use_reset_target_kinds(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                self.assertIn(scenario["target"]["kind"], TARGET_KINDS)
                for key in ("lens_valid",):
                    self.assertIsInstance(scenario["target"][key], bool)

    def test_expected_status_uses_reset_vocabulary(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                self.assertIn(scenario["expect"]["status"], STATUSES)

    def test_expected_and_untouched_keys_are_transferable_and_disjoint(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                values = scenario["expect"].get("values", {})
                untouched = scenario["expect"]["untouched"]
                for key in list(values) + list(untouched):
                    self.assertIn(".", key, "reset key is not a field path")
                    self.assertIn(key, self.transferable, f"{key} is not transferable")
                self.assertLessEqual(set(values), self.transferable)
                self.assertEqual(set(values) & set(untouched), set(), "expect values and untouched overlap")

    def test_expectation_markers_are_declared_references(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                for key, marker in scenario["expect"].get("values", {}).items():
                    if isinstance(marker, str) and marker.startswith("@"):
                        self.assertIn(marker, MARKERS, f"unknown marker for {key}")

    def test_hdr_only_fields_only_reset_on_hdr_targets(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                kind = scenario["target"]["kind"]
                keys = set(scenario["expect"].get("values", {})) | set(scenario["expect"]["untouched"])
                if kind != "hdr":
                    self.assertEqual(keys & self.hdr_only, set(), "hdr-only field reset on non-hdr target")

    def test_platform_scoping_uses_known_names(self):
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                self.assertLessEqual(set(scenario.get("platforms", PLATFORMS)), PLATFORMS)

    def test_hdr_rendition_group_is_macos_only_for_now(self):
        # iOS/Android/Windows 尚无 hdr_rendition 重置组；该场景只能登记 macos。
        for scenario in self.scenarios:
            if scenario["scope"].get("group") == "hdr_rendition":
                self.assertLessEqual(set(scenario.get("platforms", PLATFORMS)), {"macos"},
                                     "hdr_rendition scenario must stay macos-only until other ends ship the group")

    def test_reset_vector_covers_single_group_and_all_scopes(self):
        kinds = {scenario["scope"]["kind"] for scenario in self.scenarios}
        self.assertEqual(kinds, SCOPE_KINDS, "reset vector must cover tool, group and all scopes")
        all_scopes = [scenario for scenario in self.scenarios if scenario["scope"]["kind"] == "all"]
        self.assertTrue(any(s["target"]["kind"] == "sdr_raw" for s in all_scopes))
        self.assertTrue(any(s["target"]["kind"] == "hdr" for s in all_scopes))

    def test_seed_payloads_are_full_payloads(self):
        for scenario in self.scenarios:
            seed = scenario["target"].get("seed_payload")
            if seed is None:
                continue
            with self.subTest(scenario=scenario["id"]):
                self.assertEqual(set(seed) - {"payload_version", "scope_version", "source", "values"}, set())
                self.assertIn("source", seed)
                self.assertIn("values", seed)

    def test_all_reset_raw_pins_the_full_sdr_transfer_surface(self):
        # all-reset-raw 必须钉住除 hdr-only 外的全部可迁移字段，防止后续加字段悄悄绕过重置契约。
        by_id = {scenario["id"]: scenario for scenario in self.scenarios}
        scenario = by_id["all-reset-raw"]
        expected = self.transferable - self.hdr_only
        self.assertEqual(set(scenario["expect"]["values"]), expected,
                         "all-reset-raw must pin every non-hdr transferable field")


if __name__ == "__main__":
    unittest.main()
