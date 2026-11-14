"""Contract for the shared reset-scenario fixture (V-RESET wire contract).

The fixture pins what "reset" must produce on one shared scenario vector: a seeded
target state, the production reset scope, and the explicit canonical wire JSON
post-reset values. No runner may locally resolve ``@spec_default``; true platform
serialization differences must be registered in that platform's divergence ledger.
"""
import json
from pathlib import Path
import unittest


FIXTURE = Path(__file__).parents[2] / "Shared" / "fixtures" / "reset-scenarios-v1.json"
SPEC = Path(__file__).parents[2] / "Shared" / "specs" / "adjustment-fields-v1.json"
PLATFORMS = {"macos", "ios", "android", "windows"}
TARGET_KINDS = {"sdr_raw", "hdr"}
SCOPE_KINDS = {"tool", "group", "all"}
HDR_RENDITION_TOOLS = {"hdr.peak_limit_ev", "hdr.sdr_exposure_ev", "hdr.sdr_contrast", "hdr.sdr_saturation"}
TOOL_FIELDS = {"light.contrast", "detail.sharpening"} | HDR_RENDITION_TOOLS
GROUPS = {"light", "color", "geometry", "detail", "hdr_rendition"}
STATUSES = {"changed", "unchanged", "blocked"}


def _contains_at_ref(value) -> bool:
    if isinstance(value, str):
        return value.startswith("@")
    if isinstance(value, list):
        return any(_contains_at_ref(item) for item in value)
    if isinstance(value, dict):
        return any(_contains_at_ref(item) for item in value.values())
    return False


class ResetScenarioContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(FIXTURE.read_text(encoding="utf-8"))
        cls.scenarios = cls.document["scenarios"]
        spec = json.loads(SPEC.read_text(encoding="utf-8"))
        cls.fields = {row["field_id"]: row for row in spec["fields"]}
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
                target = scenario["target"]
                self.assertIn(target["kind"], TARGET_KINDS)
                for key in ("lens_valid", "supports_raw_denoise"):
                    self.assertIsInstance(target[key], bool, f"target.{key} must be a bool")
                self.assertIsInstance(target["available_looks"], list, "target.available_looks must be a list")

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

    def test_expectations_are_explicit_wire_values(self):
        # 期望值必须是显式 wire 级 JSON 字面量；禁止 @spec_default 等本地展开标记。
        self.assertNotIn("default_source", self.document, "fixture must not declare local spec default_source resolution")
        self.assertFalse(_contains_at_ref(self.document), "fixture must not contain @spec_default or @ references")
        for scenario in self.scenarios:
            with self.subTest(scenario=scenario["id"]):
                for key, value in scenario["expect"].get("values", {}).items():
                    proto = self.fields[key]["protocol"]
                    if value is None:
                        self.assertTrue(proto["nullable"], f"{key}: null expectation requires nullable protocol field")
                        self.assertNotIn(key, {"detail.denoise.chroma_mode", "detail.denoise.wavelet"},
                                         f"{key}: canonical wire expectation must not mask Mac null divergence")
                        continue
                    vtype = proto["value_type"]
                    if vtype == "boolean":
                        self.assertIsInstance(value, bool, f"{key}: expected bool")
                    elif vtype == "string":
                        self.assertIsInstance(value, str, f"{key}: expected str")
                        if proto.get("allowed_values"):
                            self.assertIn(value, proto["allowed_values"], f"{key}: value not in allowed_values")
                    elif vtype == "integer":
                        self.assertTrue(isinstance(value, int) and not isinstance(value, bool), f"{key}: expected int")
                    elif vtype == "number":
                        self.assertTrue(isinstance(value, (int, float)) and not isinstance(value, bool), f"{key}: expected number")
                    elif vtype == "object":
                        self.assertIsInstance(value, dict, f"{key}: expected object")
                        if proto.get("object_keys"):
                            self.assertEqual(set(value), set(proto["object_keys"]), f"{key}: object keys mismatch")

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

    def test_hdr_rendition_scopes_are_macos_only_for_now(self):
        # iOS/Android/Windows 尚无 hdr_rendition 组/单项重置入口；相关场景必须显式声明仅 macos。
        for scenario in self.scenarios:
            scope = scenario["scope"]
            if scope.get("group") == "hdr_rendition" or scope.get("field") in HDR_RENDITION_TOOLS:
                self.assertIn("platforms", scenario, f"{scenario['id']}: must declare platforms when excluding ends lacking hdrRendition")
                self.assertLessEqual(set(scenario["platforms"]), {"macos"},
                                     f"{scenario['id']}: hdrRendition scenario must stay macos-only until other ends ship it")

    def test_hdr_rendition_and_detail_coverage(self):
        rendition = [
            s for s in self.scenarios
            if s["scope"].get("group") == "hdr_rendition" or s["scope"].get("field") in HDR_RENDITION_TOOLS
        ]
        self.assertGreaterEqual(len(rendition), 2, "must cover at least 2 .hdrRendition reset scenarios")
        self.assertEqual({s["expect"]["status"] for s in rendition} & {"changed", "unchanged"},
                         {"changed", "unchanged"}, ".hdrRendition must cover both changed and unchanged")
        self.assertEqual({s["scope"]["kind"] for s in rendition}, {"group", "tool"},
                         ".hdrRendition must cover both group and tool reset")
        self.assertTrue(
            any("detail.denoise.post_rgb" in s["expect"]["untouched"]
                and s["target"]["seed_payload"]["source"].get("hdr_processing_version", 0) >= 6
                for s in rendition),
            "must cover HDR v6+ detail.denoise.post_rgb preserved across .hdrRendition reset",
        )
        by_id = {s["id"]: s for s in self.scenarios}
        detail_group = by_id["group-reset-detail-raw"]
        self.assertEqual(detail_group["scope"], {"kind": "group", "group": "detail"})
        self.assertEqual(detail_group["expect"]["values"]["detail.denoise.chroma_mode"], 0)
        self.assertEqual(
            detail_group["expect"]["values"]["detail.denoise.wavelet"],
            {"enabled": False, "luma": 0, "chroma": 46, "coarse": 50, "preset": "detail"},
        )

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
