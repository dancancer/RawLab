"""Release hygiene contract checks for RawLab iOS (#511)."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]

FORBIDDEN_PRODUCTION_SYMBOLS = (
    "RAWLAB_SMOKE_TEST",
    "runBundledSampleSmokeTest",
    "writeSmokeTestResult",
    "-RawLab.testBusyEditor",
    "didAutoLoadSample",
    "sampleResourceName",
    "sampleResourceExtension",
    "RawEditorViewModel+IOHelpers.swift",
    "rawLUTID",
    "rawLUTApplied",
)


def _ios_and_shared_swift_files():
    files = sorted((ROOT / "RawLab/RawLab").rglob("*.swift"))
    files += sorted((ROOT / "Shared").rglob("*.swift"))
    return [p for p in files if "/tests/" not in p.as_posix()]


class IOSReleaseHygieneTests(unittest.TestCase):
    def test_no_smoke_test_switches_or_dead_helpers_in_production_sources(self):
        scan_files = _ios_and_shared_swift_files() + [
            ROOT / "RawLab/RawLab.xcodeproj/project.pbxproj"
        ]
        hits = []
        for path in scan_files:
            text = path.read_text(encoding="utf-8")
            for symbol in FORBIDDEN_PRODUCTION_SYMBOLS:
                if symbol in text:
                    hits.append(f"{path.relative_to(ROOT)}: {symbol}")
        self.assertEqual(hits, [], f"Forbidden test switches or dead smoke symbols found: {hits}")

    def test_io_helpers_file_removed(self):
        self.assertFalse(
            (ROOT / "RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+IOHelpers.swift").exists(),
            "Dead RawEditorViewModel+IOHelpers.swift must be removed",
        )

    def test_rawlab_app_begins_usage_analytics_unconditionally(self):
        app_text = (ROOT / "RawLab/RawLab/App/RawLabApp.swift").read_text(encoding="utf-8")
        self.assertIn("UsageAnalytics.shared.beginSession()", app_text)
        lines = app_text.splitlines()
        for idx, line in enumerate(lines):
            if "UsageAnalytics.shared.beginSession()" in line:
                context = "\n".join(lines[max(0, idx - 3):idx + 1])
                self.assertNotIn("environment[", context,
                                 "UsageAnalytics.shared.beginSession() must not be gated by an environment flag")

    def test_camera_loopback_fixture_is_debug_simulator_only(self):
        for path in sorted((ROOT / "RawLab/RawLab").rglob("*.swift")):
            lines = path.read_text(encoding="utf-8").splitlines()
            depth_stack = []
            for lineno, line in enumerate(lines, start=1):
                stripped = line.strip()
                if stripped.startswith("#if "):
                    depth_stack.append(stripped)
                elif stripped.startswith("#endif") and depth_stack:
                    depth_stack.pop()
                if "RAWLAB_CAMERA_LOOPBACK_FIXTURE" in line:
                    self.assertTrue(
                        any("DEBUG" in cond and "targetEnvironment(simulator)" in cond for cond in depth_stack),
                        f"{path.relative_to(ROOT)}:{lineno}: RAWLAB_CAMERA_LOOPBACK_FIXTURE must be gated by #if DEBUG && targetEnvironment(simulator)",
                    )


if __name__ == "__main__":
    unittest.main()
