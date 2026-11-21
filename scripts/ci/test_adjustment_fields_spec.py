"""Contract and codegen freshness tests for Shared/specs/adjustment-fields-v1.json."""

from __future__ import annotations

import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC_PATH = ROOT / "Shared/specs/adjustment-fields-v1.json"
GENERATOR = ROOT / "scripts/specs/generate.py"
PLATFORMS = ("macos", "ios", "android", "windows")
VALID_GROUPS = ("looks", "light", "color", "detail", "effects", "geometry")
VALID_CATS = ("step", "range", "default_unit", "missing", "protocol_metadata")
GENERATED_FILES = (
    "Shared/RawLabKit/AdjustmentFieldSpec.generated.swift",
    "RawLabAndroid/app/src/main/java/com/rawlab/android/adjustments/AdjustmentFieldSpec.kt",
    "RawLabWindows/Core/AdjustmentFieldSpec.g.cs",
)
SCALES = {"p": lambda p: p, "-p": lambda p: -p, "p - 1": lambda p: p - 1.0, "p * 100": lambda p: p * 100.0, "-p * 100": lambda p: -p * 100.0, "(p - 1) * 100": lambda p: (p - 1.0) * 100.0}


def validate_spec_document(doc: dict) -> None:
    if doc.get("spec_version") != 1 or len(doc["fields"]) != 83:
        raise AssertionError("Spec must be version 1 with 83 fields")
    fields = doc["fields"]
    if len({f["field_id"] for f in fields}) != 83:
        raise AssertionError("Duplicate field_id in spec")
    summary, policy = doc["summary"], doc["divergence_policy"]
    if not policy.get("monotonic_non_increasing") or policy["max_divergent_fields"] > 65:
        raise AssertionError("Invalid divergence_policy ratchet")
    allowed_milestones = policy.get("allowed_expiration_milestones")
    if (
        not isinstance(allowed_milestones, list)
        or not allowed_milestones
        or not all(isinstance(m, str) and m.strip() for m in allowed_milestones)
    ):
        raise AssertionError(
            "divergence_policy.allowed_expiration_milestones must be a non-empty list of milestone strings"
        )
    default_wave = policy.get("default_expiration_wave")
    if not isinstance(default_wave, str) or default_wave not in allowed_milestones:
        raise AssertionError(
            f"default_expiration_wave={default_wave!r} must belong to allowed_expiration_milestones={allowed_milestones!r}"
        )
    all_div = [f for f in fields if f["divergence"]["has_divergence"]]
    transfer = [f for f in fields if f["protocol"]["transferable"]]
    if len(transfer) != 81 or summary["divergent_fields"] != len(all_div) or summary["identical_fields"] != 83 - len(all_div):
        raise AssertionError("Summary counts mismatch")
    if summary["divergent_fields"] > policy["max_divergent_fields"]:
        raise AssertionError(f"divergent_fields={summary['divergent_fields']} exceeds max_divergent_fields={policy['max_divergent_fields']}")

    for entry in fields:
        fid, div, proto = entry["field_id"], entry["divergence"], entry["protocol"]
        if entry["group"] not in VALID_GROUPS or set(entry["model"]) != set(PLATFORMS) or set(entry["ui"]) != set(PLATFORMS):
            raise AssertionError(f"Invalid group/platforms on {fid}")
        cats = set(div["categories"])
        if not cats.issubset(VALID_CATS):
            raise AssertionError(f"Unknown divergence categories on {fid}: {cats}")
        if div["has_divergence"]:
            if not cats or not isinstance(div.get("expires_wave"), str) or not div["expires_wave"].strip():
                raise AssertionError(f"{fid} divergent field requires categories and expires_wave")
            if div["expires_wave"] not in allowed_milestones:
                raise AssertionError(
                    f"{fid} expires_wave={div['expires_wave']!r} must belong to allowed_expiration_milestones={allowed_milestones!r}"
                )
        elif cats or "expires_wave" in div or any(entry["ui"][p] != entry["ui"][PLATFORMS[0]] for p in PLATFORMS[1:]):
            raise AssertionError(f"{fid} non-divergent entry inconsistent")

        exposed = [entry["ui"][p] for p in PLATFORMS if entry["ui"][p]["exposed"]]
        derived = set()
        if len(exposed) > 1:
            r = exposed[0]
            if any(u["step"] != r["step"] for u in exposed[1:]):
                derived.add("step")
            if any(u["unit"] != r["unit"] or u["default"] != r["default"] for u in exposed[1:]):
                derived.add("default_unit")
            if any(u["min"] != r["min"] or u["max"] != r["max"] or u.get("hdr_min") != r.get("hdr_min") or u.get("hdr_max") != r.get("hdr_max") for u in exposed[1:]):
                derived.add("range")
            if any(u.get("channels") != r.get("channels") for u in exposed[1:]):
                derived.add("missing")
        if any(entry["ui"][p]["exposed"] != entry["ui"][PLATFORMS[0]]["exposed"] or entry["ui"][p]["modes"] != entry["ui"][PLATFORMS[0]]["modes"] for p in PLATFORMS[1:]):
            derived.add("missing")
        if any(entry["model"][p]["supported"] != entry["model"][PLATFORMS[0]]["supported"] or entry["model"][p]["modes"] != entry["model"][PLATFORMS[0]]["modes"] for p in PLATFORMS[1:]):
            derived.add("missing")
        if not derived.issubset(cats):
            raise AssertionError(f"{fid} derived divergence {sorted(derived - cats)} missing from {sorted(cats)}")
        for plat in PLATFORMS:
            m = entry["model"][plat]
            if m["supported"] and proto["transferable"] and proto["value_type"] == "number" and proto["min"] is not None and fid != "light.exposure":
                vals = sorted((SCALES[m["scale_from_protocol"]](float(proto["min"])), SCALES[m["scale_from_protocol"]](float(proto["max"]))))
                if round(vals[0], 6) != round(float(m["min"]), 6) or round(vals[1], 6) != round(float(m["max"]), 6):
                    raise AssertionError(f"scale_from_protocol mismatch on {fid}.{plat}")


class AdjustmentFieldsSpecTests(unittest.TestCase):
    def test_spec_schema_policy_and_expiration(self) -> None:
        doc = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
        validate_spec_document(doc)
        over = copy.deepcopy(doc)
        over["divergence_policy"]["max_divergent_fields"] = 64
        with self.assertRaisesRegex(AssertionError, r"exceeds max_divergent_fields"):
            validate_spec_document(over)
        missing_exp = copy.deepcopy(doc)
        next(f for f in missing_exp["fields"] if f["divergence"]["has_divergence"])["divergence"].pop("expires_wave")
        with self.assertRaisesRegex(AssertionError, r"expires_wave"):
            validate_spec_document(missing_exp)

    def test_expiration_milestones_are_registered_and_reject_fictional_waves(self) -> None:
        doc = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
        policy = doc["divergence_policy"]
        self.assertEqual(policy["allowed_expiration_milestones"], ["v0.12"])
        self.assertEqual(policy["default_expiration_wave"], "v0.12")
        for field in doc["fields"]:
            if field["divergence"]["has_divergence"]:
                self.assertIn(field["divergence"]["expires_wave"], policy["allowed_expiration_milestones"])

        bad_field_wave = copy.deepcopy(doc)
        next(f for f in bad_field_wave["fields"] if f["divergence"]["has_divergence"])["divergence"]["expires_wave"] = "W4"
        with self.assertRaisesRegex(AssertionError, r"allowed_expiration_milestones"):
            validate_spec_document(bad_field_wave)

        bad_default_wave = copy.deepcopy(doc)
        bad_default_wave["divergence_policy"]["default_expiration_wave"] = "W4"
        with self.assertRaisesRegex(AssertionError, r"default_expiration_wave"):
            validate_spec_document(bad_default_wave)

        missing_allowed = copy.deepcopy(doc)
        missing_allowed["divergence_policy"].pop("allowed_expiration_milestones")
        with self.assertRaisesRegex(AssertionError, r"allowed_expiration_milestones"):
            validate_spec_document(missing_allowed)

    def test_codegen_check_determinism_and_mutations(self) -> None:
        res = subprocess.run([sys.executable, str(GENERATOR), "--check"], capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        with tempfile.TemporaryDirectory(prefix="rawlab-spec-codegen-") as tmp:
            tmp_root = Path(tmp)
            for rel in ("Shared/specs/adjustment-fields-v1.json", *GENERATED_FILES):
                dst = tmp_root / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / rel, dst)
            self.assertEqual(subprocess.run([sys.executable, str(GENERATOR), "--check", "--root", str(tmp_root)], capture_output=True, text=True).returncode, 0)
            for rel in GENERATED_FILES:
                target = tmp_root / rel
                orig = target.read_text(encoding="utf-8")
                target.write_text(orig + "// drift\n", encoding="utf-8")
                self.assertNotEqual(subprocess.run([sys.executable, str(GENERATOR), "--check", "--root", str(tmp_root)], capture_output=True, text=True).returncode, 0)
                self.assertEqual(target.read_text(encoding="utf-8"), orig + "// drift\n")
                target.write_text(orig, encoding="utf-8")
            spec_copy = tmp_root / "Shared/specs/adjustment-fields-v1.json"
            mutated = json.loads(spec_copy.read_text(encoding="utf-8"))
            next(f for f in mutated["fields"] if f["field_id"] == "light.exposure")["protocol"]["max"] = 15.0
            spec_copy.write_text(json.dumps(mutated), encoding="utf-8")
            self.assertNotEqual(subprocess.run([sys.executable, str(GENERATOR), "--check", "--root", str(tmp_root)], capture_output=True, text=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
