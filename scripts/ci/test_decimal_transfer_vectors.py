"""Contract for Shared/fixtures/adjustment-transfer-decimals-v1.json (D-05)."""

import json
from pathlib import Path
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
        self.assertIn("decimal-hdr-12-5-and-negatives-roundtrip", scenarios)

    def test_integer_protocol_fields_reject_fractional_values(self):
        integer_fields = {
            fid for fid, entry in self.spec_fields.items()
            if entry["protocol"]["transferable"] and entry["protocol"]["value_type"] == "integer"
        }
        rejected_fields = set()
        for item in self.document["rejected_payloads"]:
            if item["reason"] == "invalid_payload":
                rejected_fields |= set(item["payload"]["values"])
        self.assertTrue(integer_fields.issubset(rejected_fields),
                        f"Missing fractional rejection vectors for integer fields: {sorted(integer_fields - rejected_fields)}")
        self.assertIn("hdr.camera_development", rejected_fields)

    def test_all_four_platforms_consume_decimal_fixture(self):
        for consumer in PLATFORM_CONSUMERS:
            self.assertTrue(consumer.is_file(), f"Missing consumer: {consumer}")
            text = consumer.read_text(encoding="utf-8")
            self.assertIn("adjustment-transfer-decimals-v1.json", text)
            self.assertIn("rejected_payloads", text)


if __name__ == "__main__":
    unittest.main()
