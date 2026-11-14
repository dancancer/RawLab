"""Contract for the shared reset-scenario fixture (V-RESET wire contract).

The fixture pins what "reset" must produce on one shared scenario vector: a seeded
target state, the production reset scope, and the explicit canonical wire JSON
post-reset values. No runner may locally resolve ``@spec_default``; true platform
serialization differences must be registered per `(scenario, field)` under each
platform's monotonically non-increasing divergence ratchet.

Ratchet & closure ledger (P2-23 / S1):
- Baseline after removing `@spec_default`: macOS has 4 `(scenario, field)` wire
  serialization divergences (2 scenarios x 2 fields: `detail.denoise.chroma_mode`
  null vs 0 and `detail.denoise.wavelet` null vs disabled object), while iOS,
  Android, and Windows have 0.
- `KNOWN_FIELD_CEILINGS` enforces monotonic non-increase (`<= 4` on macOS, `0`
  on iOS/Android/Windows). Once macOS SDR `Adjustments` aligns nil-vs-default
  serialization under P2-23/S1, close `4 -> 0`; never raise ceilings.
"""
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).parents[2]
FIXTURE = ROOT / "Shared" / "fixtures" / "reset-scenarios-v1.json"
SPEC = ROOT / "Shared" / "specs" / "adjustment-fields-v1.json"
RUNNERS = {
    "macos": ROOT / "RawLabMac" / "tests" / "ResetScenarioTests.swift",
    "ios": ROOT / "RawLab" / "tests" / "ResetScenarioTests.swift",
    "android": ROOT / "RawLabAndroid" / "app" / "src" / "test" / "java" / "com" / "rawlab" / "android" / "adjustments" / "ResetScenarioTest.kt",
    "windows": ROOT / "RawLabWindows" / "tests" / "editing" / "ResetScenarioChecks.cs",
}
# Monotonic-decrease ceilings in `(scenario, field)` entries.
# Closure plan (P2-23 / S1): macos 4 -> 0 when SDR chromaNoiseReduction/waveletNoiseReduction stop emitting wire null.
KNOWN_FIELD_CEILINGS = {"macos": 4, "ios": 0, "android": 0, "windows": 0}
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
                    return text[start:i + 1]
        i += 1
    raise AssertionError(f"Unbalanced {open_ch}{close_ch} block starting at {start}")


def _extract_string_pairs(mapping_body: str, separator: str) -> dict[str, str]:
    pairs: dict[str, str] = {}
    pattern = re.compile(rf'"((?:\\.|[^"\\])*)"\s*{re.escape(separator)}\s*"((?:\\.|[^"\\])*)"')
    for match in pattern.finditer(mapping_body):
        key = json.loads(f'"{match.group(1)}"')
        val = json.loads(f'"{match.group(2)}"')
        if key in pairs:
            raise AssertionError(f"Duplicate divergence field key: {key}")
        pairs[key] = val
    return pairs


def parse_runner_divergences(platform: str, raw_source: str) -> tuple[int, dict[str, dict]]:
    source = _strip_comments(raw_source)
    if platform in ("macos", "ios"):
        cap_m = re.search(r"static\s+let\s+maxKnownFieldDivergences\s*=\s*(\d+)", source)
        assert cap_m, f"{platform}: missing `static let maxKnownFieldDivergences = <int>` ratchet ceiling"
        decl_m = re.search(r"static\s+let\s+knownResetDivergences\s*:\s*\[String:\s*ResetDivergence\]\s*=", source)
        assert decl_m, f"{platform}: missing knownResetDivergences"
        brace_idx = source.find("[", decl_m.end())
        block = _extract_balanced(source, brace_idx, "[", "]")
        parsed: dict[str, dict] = {}
        for item in re.finditer(r'"([^"]+)"\s*:\s*ResetDivergence\s*\(', block):
            sid = item.group(1)
            call_block = _extract_balanced(block, item.end() - 1, "(", ")")
            led_m = re.search(r'ledgerId\s*:\s*"((?:\\.|[^"\\])*)"', call_block)
            fr_m = re.search(r'fieldReasons\s*:\s*\[', call_block)
            assert led_m and fr_m, f"{platform} {sid}: ResetDivergence must specify ledgerId and per-field fieldReasons"
            fr_block = _extract_balanced(call_block, fr_m.end() - 1, "[", "]")
            assert re.search(r'"[^"]+"\s*:', fr_block) or fr_block.strip("[] \n\t:") == "", f"{platform} {sid}: malformed fieldReasons"
            parsed[sid] = {
                "ledger_id": json.loads(f'"{led_m.group(1)}"'),
                "field_reasons": _extract_string_pairs(fr_block, ":"),
            }
        return int(cap_m.group(1)), parsed
    if platform == "android":
        cap_m = re.search(r"private\s+val\s+maxKnownFieldDivergences\s*=\s*(\d+)", source)
        assert cap_m, "android: missing `private val maxKnownFieldDivergences = <int>` ratchet ceiling"
        if re.search(r"private\s+val\s+knownResetDivergences\s*:\s*Map<String,\s*ResetDivergence>\s*=\s*emptyMap\(\)", source):
            return int(cap_m.group(1)), {}
        decl_m = re.search(r"private\s+val\s+knownResetDivergences\s*:\s*Map<String,\s*ResetDivergence>\s*=\s*mapOf\s*\(", source)
        assert decl_m, "android: missing knownResetDivergences"
        block = _extract_balanced(source, decl_m.end() - 1, "(", ")")
        parsed = {}
        for item in re.finditer(r'"([^"]+)"\s+to\s+ResetDivergence\s*\(', block):
            sid = item.group(1)
            call_block = _extract_balanced(block, item.end() - 1, "(", ")")
            led_m = re.search(r'ledgerId\s*=\s*"((?:\\.|[^"\\])*)"', call_block)
            fr_m = re.search(r'fieldReasons\s*=\s*mapOf\s*\(', call_block)
            assert led_m and fr_m, f"android {sid}: ResetDivergence must specify ledgerId and fieldReasons"
            fr_block = _extract_balanced(call_block, fr_m.end() - 1, "(", ")")
            parsed[sid] = {
                "ledger_id": json.loads(f'"{led_m.group(1)}"'),
                "field_reasons": _extract_string_pairs(fr_block, "to"),
            }
        return int(cap_m.group(1)), parsed
    if platform == "windows":
        cap_m = re.search(r"private\s+const\s+int\s+MaxKnownFieldDivergences\s*=\s*(\d+)\s*;", source)
        assert cap_m, "windows: missing `private const int MaxKnownFieldDivergences = <int>;` ratchet ceiling"
        decl_m = re.search(r"KnownResetDivergences\s*=\s*new\s+Dictionary<string,\s*ResetDivergence>\s*(?:\(\s*\))?\s*(?:;|\{)", source)
        assert decl_m, "windows: missing KnownResetDivergences"
        if decl_m.group(0).endswith(";"):
            return int(cap_m.group(1)), {}
        block = _extract_balanced(source, decl_m.end() - 1, "{", "}")
        parsed = {}
        for item in re.finditer(r'\[\s*"([^"]+)"\s*\]\s*=\s*new(?:\s+ResetDivergence)?\s*\(', block):
            sid = item.group(1)
            call_block = _extract_balanced(block, item.end() - 1, "(", ")")
            led_m = re.search(r'^\(\s*(?:LedgerId:\s*)?"((?:\\.|[^"\\])*)"', call_block)
            fr_m = re.search(r'new\s+Dictionary<string,\s*string>\s*(?:\(\s*\)\s*)?\{', call_block)
            assert led_m and fr_m, f"windows {sid}: ResetDivergence must specify LedgerId and FieldReasons dictionary"
            fr_block = _extract_balanced(call_block, fr_m.end() - 1, "{", "}")
            pairs: dict[str, str] = {}
            for pair in re.finditer(r'\[\s*"((?:\\.|[^"\\])*)"\s*\]\s*=\s*"((?:\\.|[^"\\])*)"', fr_block):
                pairs[json.loads(f'"{pair.group(1)}"')] = json.loads(f'"{pair.group(2)}"')
            parsed[sid] = {"ledger_id": json.loads(f'"{led_m.group(1)}"'), "field_reasons": pairs}
        return int(cap_m.group(1)), parsed
    raise AssertionError(f"Unknown platform {platform}")


def validate_runner_divergences(sources: dict[str, str], scenarios: list[dict], ceilings: dict[str, int] = KNOWN_FIELD_CEILINGS) -> None:
    by_id = {s["id"]: s for s in scenarios}
    for platform, source in sources.items():
        declared_cap, entries = parse_runner_divergences(platform, source)
        max_cap = ceilings[platform]
        assert declared_cap <= max_cap, (
            f"{platform}: declared ratchet cap {declared_cap} exceeds allowed monotonic ceiling {max_cap}"
        )
        total_fields = 0
        for sid, entry in entries.items():
            assert sid in by_id, f"{platform}: unknown scenario id {sid} in divergence registry"
            allowed_platforms = set(by_id[sid].get("platforms", PLATFORMS))
            assert platform in allowed_platforms, f"{platform}: scenario {sid} is excluded for this platform"
            assert entry["ledger_id"].strip(), f"{platform} {sid}: ledgerId must not be blank"
            field_reasons = entry["field_reasons"]
            assert len(field_reasons) > 0, f"{platform} {sid}: fieldReasons must not be empty"
            valid_keys = set(by_id[sid]["expect"].get("values", {})) | set(by_id[sid]["expect"].get("untouched", [])) | {"status"}
            for field_key, reason in field_reasons.items():
                assert field_key in valid_keys, f"{platform} {sid}: {field_key} is not observed by this scenario"
                assert reason.strip(), f"{platform} {sid}.{field_key}: divergence reason must not be blank"
                total_fields += 1
        assert total_fields <= declared_cap, (
            f"{platform}: registered field divergence count {total_fields} exceeds runner cap {declared_cap}"
        )


def validate_windows_wire_presence(raw_source: str) -> None:
    sig_m = re.search(r"private\s+static\s+bool\s+Same\s*\(\s*JsonElement\?\s*a\s*,\s*JsonElement\?\s*b\s*\)", raw_source)
    assert sig_m, "Windows ResetScenarioChecks.Same signature missing"
    brace_idx = raw_source.find("{", sig_m.end())
    same_body = _strip_comments(_extract_balanced(raw_source, brace_idx, "{", "}"))
    assert "a == null && b == null" in same_body, (
        "Windows Same() must strictly check `a == null && b == null` without equating missing keys to JsonValueKind.Null"
    )
    assert "JsonValueKind.Null" not in same_body.split("switch", 1)[0], (
        "Windows Same() null guard must not treat JsonValueKind.Null as equal to C# null (missing wire key)"
    )
    assert "VerifyWirePresenceContract()" in raw_source, (
        "Windows ResetScenarioChecks.Run() must execute VerifyWirePresenceContract() to lock missing-key vs null checks"
    )


def validate_wire_presence_self_tests(sources: dict[str, str]) -> None:
    validate_windows_wire_presence(sources["windows"])
    for platform in ("macos", "ios", "android"):
        assert "verifyWirePresenceContract()" in sources[platform], (
            f"{platform}: runner must call verifyWirePresenceContract() to lock missing-key vs null checks"
        )


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

    def test_runner_divergence_ratchet_and_per_field_reasons(self):
        self.assertEqual(
            KNOWN_FIELD_CEILINGS,
            {"macos": 4, "ios": 0, "android": 0, "windows": 0},
            "Monotonic ceiling must not silently expand without explicit ledger update",
        )
        sources = {platform: path.read_text(encoding="utf-8") for platform, path in RUNNERS.items()}
        validate_runner_divergences(sources, self.scenarios, KNOWN_FIELD_CEILINGS)

    def test_windows_same_distinguishes_missing_key_from_explicit_null(self):
        validate_wire_presence_self_tests({p: path.read_text(encoding="utf-8") for p, path in RUNNERS.items()})

    def test_ratchet_and_wire_presence_contracts_detect_regressions(self):
        sources = {platform: path.read_text(encoding="utf-8") for platform, path in RUNNERS.items()}
        # 1. Increasing macOS ceiling above 4 (upward inflation) must fail.
        bad_mac = dict(sources)
        bad_mac["macos"] = sources["macos"].replace("static let maxKnownFieldDivergences = 4", "static let maxKnownFieldDivergences = 5")
        with self.assertRaisesRegex(AssertionError, r"macos: declared ratchet cap 5"):
            validate_runner_divergences(bad_mac, self.scenarios, KNOWN_FIELD_CEILINGS)

        # 2. Registering any new Windows/iOS/Android divergence (> 0) must fail.
        bad_win = dict(sources)
        bad_win["windows"] = sources["windows"].replace(
            "private static readonly IReadOnlyDictionary<string, ResetDivergence> KnownResetDivergences =\n        new Dictionary<string, ResetDivergence>();",
            'private static readonly IReadOnlyDictionary<string, ResetDivergence> KnownResetDivergences =\n        new Dictionary<string, ResetDivergence> { ["all-reset-raw"] = new("P2-23", new Dictionary<string, string> { ["light.exposure"] = "regressed" }) };',
        )
        with self.assertRaisesRegex(AssertionError, r"windows: registered field divergence count 1"):
            validate_runner_divergences(bad_win, self.scenarios, KNOWN_FIELD_CEILINGS)

        # 3. Reverting macOS entry to blank reason must fail.
        blank_mac = dict(sources)
        blank_mac["macos"] = re.sub(
            r'("detail\.denoise\.chroma_mode"\s*:\s*")[^"]+(")',
            r'\1   \2',
            sources["macos"],
            count=1,
        )
        with self.assertRaisesRegex(AssertionError, r"reason must not be blank"):
            validate_runner_divergences(blank_mac, self.scenarios, KNOWN_FIELD_CEILINGS)

        # 4. Reverting Windows Same() or removing any wire-presence self-test must fail.
        buggy_win = sources["windows"].replace(
            "if (a == null || b == null) return a == null && b == null;",
            "if (a == null || b == null) return (a == null || a.Value.ValueKind == JsonValueKind.Null) && (b == null || b.Value.ValueKind == JsonValueKind.Null);",
        )
        with self.assertRaisesRegex(AssertionError, r"a == null && b == null|JsonValueKind\.Null"):
            validate_windows_wire_presence(buggy_win)

        missing_selftest = dict(sources)
        missing_selftest["windows"] = sources["windows"].replace("VerifyWirePresenceContract()", "NoOp()")
        with self.assertRaisesRegex(AssertionError, r"VerifyWirePresenceContract"):
            validate_wire_presence_self_tests(missing_selftest)

        missing_mac_selftest = dict(sources)
        missing_mac_selftest["macos"] = sources["macos"].replace("verifyWirePresenceContract()", "noop()")
        with self.assertRaisesRegex(AssertionError, r"verifyWirePresenceContract"):
            validate_wire_presence_self_tests(missing_mac_selftest)


if __name__ == "__main__":
    unittest.main()
