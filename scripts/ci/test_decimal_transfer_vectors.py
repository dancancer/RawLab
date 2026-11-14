"""Contract for Shared/fixtures/adjustment-transfer-decimals-v1.json (D-05)."""

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "Shared" / "fixtures" / "adjustment-transfer-decimals-v1.json"
SPEC = ROOT / "Shared" / "specs" / "adjustment-fields-v1.json"
PLATFORMS = {"macos", "ios", "android", "windows"}
TARGET_KINDS = {"sdr_raw", "sdr_raster", "hdr"}
STATUSES = {"applied", "unchanged", "rejected"}
REASONS = {"invalid_payload", "incompatible", "unrepresentable", "missing_look"}
NOTICES = {"ignored_raw_denoise", "ignored_post_rgb_denoise", "retained_target_processing_version"}
D05_EFFECT_FIELDS = {
    "effects.vignette.amount",
    "effects.vignette.midpoint",
    "effects.vignette.roundness",
    "effects.vignette.feather",
    "effects.vignette.highlights",
    "effects.grain.amount",
    "effects.grain.size",
    "effects.grain.roughness",
}
PLATFORM_CONSUMERS = (
    ROOT / "RawLab" / "tests" / "AdjustmentTransferTests.swift",
    ROOT / "RawLabMac" / "tests" / "AdjustmentTransferTests.swift",
    ROOT / "RawLabAndroid" / "app" / "src" / "test" / "java" / "com" / "rawlab" / "android" / "adjustments" / "AdjustmentTransferTest.kt",
    ROOT / "RawLabWindows" / "tests" / "editing" / "AdjustmentTransferChecks.cs",
)


class DecimalTransferVectorContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(FIXTURE.read_text(encoding="utf-8"))
        cls.spec = json.loads(SPEC.read_text(encoding="utf-8"))
        cls.spec_fields = {f["field_id"]: f for f in cls.spec["fields"]}

    def test_fixture_structure_and_unique_ids(self):
        self.assertEqual(self.document["fixture_version"], 1)
        scenarios = self.document["scenarios"]
        rejected = self.document["rejected_payloads"]
        self.assertGreater(len(scenarios), 0)
        self.assertGreater(len(rejected), 0)

        scenario_ids = [s["id"] for s in scenarios]
        self.assertEqual(len(scenario_ids), len(set(scenario_ids)))
        rejected_ids = [r["id"] for r in rejected]
        self.assertEqual(len(rejected_ids), len(set(rejected_ids)))
        self.assertTrue(set(scenario_ids).isdisjoint(rejected_ids))

        for s in scenarios:
            with self.subTest(scenario=s["id"]):
                self.assertIn(s["target"]["kind"], TARGET_KINDS)
                self.assertIn("supports_raw_denoise", s["target"])
                expect = s["expect"]
                self.assertIn(expect["status"], STATUSES)
                self.assertLessEqual(set(s.get("platforms", PLATFORMS)), PLATFORMS)
                for key in expect.get("values", {}):
                    self.assertIn(key, self.spec_fields)
                declared_notices = set(expect.get("notices", []))
                for names in expect.get("notices_by_platform", {}).values():
                    declared_notices |= set(names)
                self.assertLessEqual(declared_notices, NOTICES)

        for r in rejected:
            with self.subTest(rejected=r["id"]):
                self.assertIn(r["reason"], REASONS)
                self.assertTrue(set(r["payload"]["values"]).issubset(self.spec_fields))

    def test_d05_decimal_half_overprecision_and_negative_coverage(self):
        scenarios = {s["id"]: s for s in self.document["scenarios"]}
        all_applied_values = {}
        has_half = False
        has_12_25 = False
        has_neg_decimal = False
        for s in scenarios.values():
            if s["expect"]["status"] in ("applied", "unchanged"):
                for k, v in s["expect"].get("values", {}).items():
                    all_applied_values.setdefault(k, []).append(v)
                    if isinstance(v, (int, float)):
                        if abs(v) == 12.5:
                            has_half = True
                        if abs(v) == 12.25:
                            has_12_25 = True
                        if v < 0 and v != int(v):
                            has_neg_decimal = True

        self.assertTrue(has_half, "Must cover 12.5 round-trip")
        self.assertTrue(has_12_25, "Must cover 12.25 over-precision decimal")
        self.assertTrue(has_neg_decimal, "Must cover negative decimals")
        self.assertTrue(D05_EFFECT_FIELDS.issubset(all_applied_values), "All 8 D-05 effects fields must be covered")
        for fid in D05_EFFECT_FIELDS:
            nums = [v for v in all_applied_values[fid] if isinstance(v, (int, float))]
            self.assertTrue(any(abs(v - int(v)) > 0 for v in nums), f"{fid} must exercise fractional values")
            fracs = {round(abs(v - int(v)), 4) for v in nums if abs(v - int(v)) > 0}
            self.assertIn(0.5, fracs, f"{fid} should exercise .5 decimals")
            self.assertTrue(0.25 in fracs or 0.75 in fracs, f"{fid} should exercise .25/.75 decimals")
            self.assertTrue(
                bool(fracs & {0.1, 0.2, 0.3, 0.4, 0.6, 0.7, 0.8, 0.9}),
                f"{fid} must exercise non-binary 0.1-step desktop decimals (e.g. .1/.3/.7/.9)",
            )
        self.assertIn("decimal-hdr-12-5-and-negatives-roundtrip", scenarios)
        self.assertIn("decimal-tenth-step-nonbinary-roundtrip", scenarios)
        self.assertIn("decimal-tenth-step-idempotent-hdr-roundtrip", scenarios)
        idempotent_hdr = scenarios["decimal-tenth-step-idempotent-hdr-roundtrip"]
        self.assertEqual(idempotent_hdr["expect"]["status"], "unchanged")

    def test_integer_protocol_fields_reject_fractional_values(self):
        integer_fields = {
            fid for fid, entry in self.spec_fields.items()
            if entry["protocol"]["transferable"] and entry["protocol"]["value_type"] == "integer"
        }
        rejected_fields = set()
        hdr_cam_keys_with_fraction = set()
        for item in self.document["rejected_payloads"]:
            if item["reason"] == "invalid_payload":
                values = item["payload"]["values"]
                rejected_fields |= set(values)
                cam = values.get("hdr.camera_development")
                if isinstance(cam, dict):
                    for k, v in cam.items():
                        if isinstance(v, float) and v != int(v):
                            hdr_cam_keys_with_fraction.add(k)
        self.assertTrue(integer_fields.issubset(rejected_fields),
                        f"Missing fractional rejection vectors for integer fields: {sorted(integer_fields - rejected_fields)}")
        self.assertIn("hdr.camera_development", rejected_fields)
        self.assertTrue({"fbdd_level", "version"}.issubset(hdr_cam_keys_with_fraction),
                        f"hdr.camera_development must test fractional rejections for both fbdd_level and version, got {sorted(hdr_cam_keys_with_fraction)}")

    @staticmethod
    def _strip_comments(source: str) -> str:
        # Remove // line comments and /* ... */ block comments without touching string literals.
        pattern = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)
        return pattern.sub(lambda m: m.group(0) if m.group(0).startswith('"') else "", source)

    def test_all_four_platforms_consume_decimal_fixture(self):
        fixture_name = "adjustment-transfer-decimals-v1.json"
        active_checks = {
            PLATFORM_CONSUMERS[0]: [  # iOS
                r"try\s+decimalFixtures\(\)",
                r"static\s+func\s+decimalFixtures\s*\([^)]*\).*?adjustment-transfer-decimals-v1\.json",
                r"try\s+scenarioFixtures\s*\(\s*at:\s*path\s*\)",
                r'root\["rejected_payloads"\].*?JSONDecoder\(\)\.decode\(\s*AdjustmentTransferPayload\.self',
            ],
            PLATFORM_CONSUMERS[1]: [  # macOS
                r"try\s+decimalFixtures\(\)",
                r"static\s+func\s+decimalFixtures\s*\([^)]*\).*?adjustment-transfer-decimals-v1\.json",
                r"try\s+sharedScenarioFixtures\s*\(\s*at:\s*path\s*\)",
                r'root\["rejected_payloads"\].*?JSONDecoder\(\)\.decode\(\s*AdjustmentTransferPayload\.self',
            ],
            PLATFORM_CONSUMERS[2]: [  # Android
                r"@Test\s+fun\s+decimalVectorFixtures\s*\(\)",
                r'runScenarioFixture\(\s*"adjustment-transfer-decimals-v1\.json"',
                r'root\.getJSONArray\(\s*"rejected_payloads"\s*\).*?AdjustmentPayload\.decode\(',
            ],
            PLATFORM_CONSUMERS[3]: [  # Windows
                r"\bDecimalVectors\(\)\s*;",
                r"private\s+static\s+void\s+DecimalVectors\s*\(\).*?adjustment-transfer-decimals-v1\.json",
                r"\bScenarios\(\s*path\b",
                r'GetProperty\(\s*"rejected_payloads"\s*\).*?AdjustmentPayload\.Parse\(',
            ],
        }
        for consumer, patterns in active_checks.items():
            self.assertTrue(consumer.is_file(), f"Missing consumer: {consumer}")
            active_code = self._strip_comments(consumer.read_text(encoding="utf-8"))
            self.assertIn(fixture_name, active_code, f"{consumer} lacks active reference to {fixture_name}")
            for pat in patterns:
                self.assertRegex(
                    active_code,
                    re.compile(pat, re.S),
                    f"{consumer} missing active non-commented call matching {pat!r}",
                )


if __name__ == "__main__":
    unittest.main()
