"""Contract for the shared persisted editing-record golden fixture (P2-01 / S1).

Pins:
1. Full 83-field coverage anchored to Shared/specs/adjustment-fields-v1.json.
2. X1 read-side unknown-field scenarios, cross-version compatibility, and boundary rejections.
3. Monotonically non-increasing per-platform divergence ledgers with non-blank ledgerId and reason.
4. Explicit CI inclusion in scripts/ci/apple-models.sh and RawLabWindows/tests/editing/Program.cs
   (executed by scripts/ci/windows-models.ps1).
"""
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).parents[2]
FIXTURE = ROOT / "Shared" / "fixtures" / "edit-records-v1.json"
SPEC = ROOT / "Shared" / "specs" / "adjustment-fields-v1.json"
APPLE_MODELS = ROOT / "scripts" / "ci" / "apple-models.sh"
WINDOWS_MODELS = ROOT / "scripts" / "ci" / "windows-models.ps1"
WINDOWS_PROGRAM = ROOT / "RawLabWindows" / "tests" / "editing" / "Program.cs"

RUNNERS = {
    "macos": ROOT / "RawLabMac" / "tests" / "EditRecordFixtureTests.swift",
    "ios": ROOT / "RawLab" / "tests" / "EditRecordFixtureTests.swift",
    "android": ROOT / "RawLabAndroid" / "app" / "src" / "test" / "java" / "com" / "rawlab" / "android" / "settings" / "EditRecordFixtureTest.kt",
    "windows": ROOT / "RawLabWindows" / "tests" / "editing" / "EditRecordFixtureChecks.cs",
}
KNOWN_DIVERGENCE_CEILINGS = {
    "macos": 14,
    "ios": 14,
    "android": 24,
    "windows": 17,
}
REQUIRED_X1_SCOPES = {
    "store_root",
    "store_sibling_entry",
    "record_root",
    "settings_root",
    "processing",
    "tone_controls",
    "atmosphere",
    "color_grading",
    "color_grading_zone",
    "tone_curve",
    "tone_curve_channels",
    "geometry",
    "lens",
    "denoise",
    "effects",
    "hdr",
    "hdr_tone",
    "hdr_color",
    "hdr_rendition",
    "hdr_effects",
    "hdr_detail",
    "hdr_look",
    "hdr_camera_development",
    "hdr_camera_profile",
}
REQUIRED_COMPAT_KINDS = {
    "legacy_omitted_extensions",
    "sdr_reset_preserves_dormant_hdr",
    "future_processing_version",
    "corrupt_entry",
    "negative_zero",
}


def _strip_comments(source: str) -> str:
    out = []
    i, n = 0, len(source)
    in_str = False
    while i < n:
        ch = source[i]
        if in_str:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if ch == '"':
                in_str = False
            i += 1
        elif ch == '"':
            in_str = True
            out.append(ch)
            i += 1
        elif source.startswith("//", i):
            nl = source.find("\n", i)
            i = n if nl == -1 else nl
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            i = n if end == -1 else end + 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def _extract_balanced(text: str, start: int, open_ch: str, close_ch: str) -> str:
    depth = 0
    in_str = False
    i = start
    while i < len(text):
        ch = text[i]
        if in_str:
            if ch == "\\" and i + 1 < len(text):
                i += 2
                continue
            if ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == open_ch:
                depth += 1
            elif ch == close_ch:
                depth -= 1
                if depth == 0:
                    return text[start : i + 1]
        i += 1
    raise AssertionError(f"Unbalanced {open_ch}{close_ch} starting at {start}")


def parse_runner_divergences(platform: str, raw_source: str) -> tuple[int, dict[str, dict[str, str]]]:
    source = _strip_comments(raw_source)
    if platform in ("macos", "ios"):
        cap_m = re.search(r"private\s+let\s+maxKnownEditRecordDivergences\s*=\s*(\d+)", source)
        assert cap_m, f"{platform}: missing `private let maxKnownEditRecordDivergences = <int>`"
        decl_m = re.search(
            r"private\s+let\s+knownEditRecordDivergences\s*:\s*\[\s*String\s*:\s*EditRecordDivergence\s*\]\s*=\s*\[",
            source,
        )
        assert decl_m, f"{platform}: missing knownEditRecordDivergences"
        block = _extract_balanced(source, decl_m.end() - 1, "[", "]")
        parsed = {}
        for item in re.finditer(r'"([^"]+)"\s*:\s*EditRecordDivergence\s*\(', block):
            sid = item.group(1)
            call_block = _extract_balanced(block, item.end() - 1, "(", ")")
            led_m = re.search(r'ledgerId\s*:\s*"((?:\\.|[^"\\])*)"', call_block)
            rsn_m = re.search(r'reason\s*:\s*"((?:\\.|[^"\\])*)"', call_block)
            assert led_m and rsn_m, f"{platform} {sid}: EditRecordDivergence must specify ledgerId and reason"
            parsed[sid] = {
                "ledger_id": json.loads(f'"{led_m.group(1)}"'),
                "reason": json.loads(f'"{rsn_m.group(1)}"'),
            }
        return int(cap_m.group(1)), parsed

    if platform == "android":
        cap_m = re.search(r"private\s+val\s+maxKnownEditRecordDivergences\s*=\s*(\d+)", source)
        assert cap_m, "android: missing `private val maxKnownEditRecordDivergences = <int>`"
        decl_m = re.search(
            r"private\s+val\s+knownEditRecordDivergences\s*:\s*Map<String,\s*EditRecordDivergence>\s*=\s*mapOf\s*\(",
            source,
        )
        assert decl_m, "android: missing knownEditRecordDivergences"
        block = _extract_balanced(source, decl_m.end() - 1, "(", ")")
        parsed = {}
        for item in re.finditer(r'"([^"]+)"\s+to\s+EditRecordDivergence\s*\(', block):
            sid = item.group(1)
            call_block = _extract_balanced(block, item.end() - 1, "(", ")")
            led_m = re.search(r'ledgerId\s*=\s*"((?:\\.|[^"\\])*)"', call_block)
            rsn_m = re.search(r'reason\s*=\s*"((?:\\.|[^"\\])*)"', call_block)
            assert led_m and rsn_m, f"android {sid}: EditRecordDivergence must specify ledgerId and reason"
            parsed[sid] = {
                "ledger_id": json.loads(f'"{led_m.group(1)}"'),
                "reason": json.loads(f'"{rsn_m.group(1)}"'),
            }
        return int(cap_m.group(1)), parsed

    if platform == "windows":
        cap_m = re.search(r"private\s+const\s+int\s+MaxKnownEditRecordDivergences\s*=\s*(\d+)\s*;", source)
        assert cap_m, "windows: missing `private const int MaxKnownEditRecordDivergences = <int>;`"
        decl_m = re.search(
            r"KnownEditRecordDivergences\s*=\s*new\s+Dictionary<string,\s*EditRecordDivergence>\s*(?:\(\s*StringComparer\.Ordinal\s*\))?\s*\{",
            source,
        )
        assert decl_m, "windows: missing KnownEditRecordDivergences"
        block = _extract_balanced(source, decl_m.end() - 1, "{", "}")
        parsed = {}
        for item in re.finditer(r'\[\s*"([^"]+)"\s*\]\s*=\s*new(?:\s+EditRecordDivergence)?\s*\(', block):
            sid = item.group(1)
            call_block = _extract_balanced(block, item.end() - 1, "(", ")")
            pair_m = re.search(r'^\(\s*"((?:\\.|[^"\\])*)"\s*,\s*"((?:\\.|[^"\\])*)"\s*\)$', call_block, re.DOTALL)
            assert pair_m, f"windows {sid}: expected new(\"ledgerId\", \"reason\")"
            parsed[sid] = {
                "ledger_id": json.loads(f'"{pair_m.group(1)}"'),
                "reason": json.loads(f'"{pair_m.group(2)}"'),
            }
        return int(cap_m.group(1)), parsed

    raise AssertionError(f"Unknown platform {platform}")


def validate_runner_divergences(
    sources: dict[str, str],
    scenario_ids: set[str],
    ceilings: dict[str, int] = KNOWN_DIVERGENCE_CEILINGS,
) -> None:
    for platform, source in sources.items():
        declared_cap, entries = parse_runner_divergences(platform, source)
        max_cap = ceilings[platform]
        assert declared_cap <= max_cap, (
            f"{platform}: declared ratchet cap {declared_cap} exceeds allowed monotonic ceiling {max_cap}"
        )
        for sid, entry in entries.items():
            assert sid in scenario_ids, f"{platform}: unknown scenario id {sid} in divergence registry"
            assert entry["ledger_id"].strip(), f"{platform} {sid}: ledgerId must not be blank"
            assert entry["reason"].strip(), f"{platform} {sid}: divergence reason must not be blank"
        assert len(entries) <= declared_cap, (
            f"{platform}: registered divergence count {len(entries)} exceeds runner cap {declared_cap}"
        )


class EditRecordFixtureContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(FIXTURE.read_text(encoding="utf-8"))
        spec = json.loads(SPEC.read_text(encoding="utf-8"))
        cls.spec_fields = {row["field_id"]: row for row in spec["fields"]}
        cls.scenario_ids = (
            {f"roundtrip:{r['id']}" for r in cls.document["roundtrip_records"]}
            | {s["id"] for s in cls.document["unknown_field_scenarios"]}
            | {s["id"] for s in cls.document["compatibility_scenarios"]}
            | {s["id"] for s in cls.document["boundary_scenarios"]}
        )

    def test_fixture_header_and_unique_ids(self):
        self.assertEqual(self.document["fixture_version"], 1)
        self.assertEqual(self.document["spec_version"], 1)
        all_ids = []
        for section in ("roundtrip_records", "unknown_field_scenarios", "compatibility_scenarios", "boundary_scenarios"):
            items = self.document[section]
            self.assertGreater(len(items), 0, f"{section} must not be empty")
            ids = [item["id"] for item in items]
            self.assertEqual(len(ids), len(set(ids)), f"duplicate id in {section}")
            all_ids.extend(f"roundtrip:{i}" if section == "roundtrip_records" else i for i in ids)
        self.assertEqual(len(all_ids), len(set(all_ids)), "scenario ids must be globally unique")

    def test_roundtrip_records_cover_all_83_spec_fields_without_drift(self):
        self.assertEqual(len(self.spec_fields), 83, "expected 83 fields in adjustment-fields-v1.json")
        covered_any = set()
        covered_hdr = set()
        covered_local_true = set()
        for rec in self.document["roundtrip_records"]:
            for bag_name in ("sdr_values", "hdr_values", "dormant_hdr_values", "local_values"):
                bag = rec.get(bag_name) or {}
                for field_id in bag:
                    self.assertIn(field_id, self.spec_fields, f"{rec['id']}.{bag_name}: unknown field {field_id}")
                    covered_any.add(field_id)
                if bag_name == "hdr_values":
                    covered_hdr |= set(bag)
            local = rec.get("local_values") or {}
            for k, v in local.items():
                if v is True:
                    covered_local_true.add(k)

        self.assertEqual(covered_any, set(self.spec_fields), "roundtrip_records must cover all 83 spec fields")
        hdr_only_transferable = {
            fid for fid, row in self.spec_fields.items()
            if row["protocol"]["transferable"] and row["protocol"].get("hdr_only")
        }
        self.assertLessEqual(hdr_only_transferable, covered_hdr, "active hdr_values must cover all transferable hdr_only fields")
        local_only = {fid for fid, row in self.spec_fields.items() if not row["protocol"]["transferable"]}
        self.assertEqual(covered_local_true, local_only, "local_only fields must be exercised with true in roundtrip_records")

    def test_hdr_camera_ai_record_respects_mutual_exclusion(self):
        by_id = {r["id"]: r for r in self.document["roundtrip_records"]}
        ai_rec = by_id["hdr-camera-ai-raw"]
        self.assertTrue(ai_rec["local_values"]["local.hdr_camera_ai_enabled"])
        self.assertIsNone(ai_rec["metadata"].get("pro_raw_decode_version"))
        cam = ai_rec["hdr_values"]["hdr.camera_development"]
        self.assertEqual(cam["fbdd_level"], 0)
        self.assertNotIn("camera_profile", ai_rec["metadata"].get("hdr_camera_development_extra", {}))

    def test_x1_compat_and_boundary_coverage_complete(self):
        x1_scopes = {s["target_scope"] for s in self.document["unknown_field_scenarios"]}
        self.assertEqual(x1_scopes, REQUIRED_X1_SCOPES)
        compat_kinds = {s["kind"] for s in self.document["compatibility_scenarios"]}
        self.assertEqual(compat_kinds, REQUIRED_COMPAT_KINDS)

        by_id = {r["id"]: r for r in self.document["roundtrip_records"]}
        for section in ("unknown_field_scenarios", "compatibility_scenarios", "boundary_scenarios"):
            for sc in self.document[section]:
                self.assertIn(sc["base_record_id"], by_id, f"{sc['id']}: missing base_record_id")
                if "sibling_record_id" in sc:
                    self.assertIn(sc["sibling_record_id"], by_id, f"{sc['id']}: missing sibling_record_id")

    def test_runner_divergence_ratchet_and_ledger_entries(self):
        self.assertEqual(KNOWN_DIVERGENCE_CEILINGS, {"macos": 14, "ios": 14, "android": 24, "windows": 17})
        sources = {p: path.read_text(encoding="utf-8") for p, path in RUNNERS.items()}
        validate_runner_divergences(sources, self.scenario_ids, KNOWN_DIVERGENCE_CEILINGS)

    def test_ratchet_detects_cap_inflation_blank_reason_and_unknown_id(self):
        sources = {p: path.read_text(encoding="utf-8") for p, path in RUNNERS.items()}

        inflated = dict(sources)
        inflated["macos"] = sources["macos"].replace(
            "private let maxKnownEditRecordDivergences = 14",
            "private let maxKnownEditRecordDivergences = 15",
        )
        with self.assertRaisesRegex(AssertionError, r"macos: declared ratchet cap 15"):
            validate_runner_divergences(inflated, self.scenario_ids)

        blank_win = dict(sources)
        blank_win["windows"] = re.sub(
            r'new\("P2-01-WIN-X1-01",\s*"[^"]+"\)',
            'new("P2-01-WIN-X1-01", "   ")',
            sources["windows"],
            count=1,
        )
        with self.assertRaisesRegex(AssertionError, r"divergence reason must not be blank"):
            validate_runner_divergences(blank_win, self.scenario_ids)

        blank_android = dict(sources)
        blank_android["android"] = re.sub(
            r'reason\s*=\s*"[^"]+"',
            'reason = "   "',
            sources["android"],
            count=1,
        )
        with self.assertRaisesRegex(AssertionError, r"divergence reason must not be blank"):
            validate_runner_divergences(blank_android, self.scenario_ids)

        unknown_id = dict(sources)
        unknown_id["ios"] = sources["ios"].replace(
            '"x1-processing-unknown-field"',
            '"non-existent-edit-record-scenario"',
            1,
        )
        with self.assertRaisesRegex(AssertionError, r"unknown scenario id non-existent-edit-record-scenario"):
            validate_runner_divergences(unknown_id, self.scenario_ids)

    def test_ci_inclusion_lines_present(self):
        apple_sh = APPLE_MODELS.read_text(encoding="utf-8")
        mac_block = apple_sh.split("macos)", 1)[1].split(";;", 1)[0]
        ios_block = apple_sh.split("ios)", 1)[1].split(";;", 1)[0]
        self.assertIn("RawLabMac/tests/edit-records.sh", mac_block)
        self.assertIn("RawLab/tests/edit-records.sh", ios_block)
        self.assertTrue((ROOT / "RawLabMac" / "tests" / "edit-records.sh").is_file())
        self.assertTrue((ROOT / "RawLab" / "tests" / "edit-records.sh").is_file())

        win_prog = WINDOWS_PROGRAM.read_text(encoding="utf-8")
        self.assertIn("EditRecordFixtureChecks.Run();", win_prog)
        win_ps1 = WINDOWS_MODELS.read_text(encoding="utf-8")
        self.assertIn("editing/EditWorkflow.Tests.csproj", win_ps1)


if __name__ == "__main__":
    unittest.main()
