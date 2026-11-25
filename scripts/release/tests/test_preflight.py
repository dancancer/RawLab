"""Release preflight: steps fail fast with their name, and the Mac typecheck tracks RawLabMac/build.sh sources."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
PREFLIGHT = ROOT / "scripts/release/preflight.sh"


class PreflightTests(unittest.TestCase):
    def run_with_fake_python(self, fail_on):
        """Run the version/docs steps with a python3 stand-in that fails only for `fail_on`."""
        with tempfile.TemporaryDirectory(prefix="rawlab preflight ") as directory:
            fake = Path(directory) / "python3"
            calls = Path(directory) / "calls"
            fake.write_text(f'#!/bin/bash\nprintf "%s\\n" "$*" >> "{calls}"\n'
                            f'case "$*" in *"{fail_on}"*) echo "simulated failure: $*" >&2; exit 7 ;; esac\nexit 0\n')
            fake.chmod(0o755)
            result = subprocess.run(["/bin/bash", str(PREFLIGHT), "--skip-mac-compile", "--models", "none"],
                                    env={**os.environ, "PYTHON": str(fake)}, capture_output=True, text=True)
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_failure_inside_a_step_is_not_swallowed_by_later_commands(self):
        # generate.py --check fails but the following unittest call would succeed: the step
        # (and the whole preflight) must still fail and later steps must not run.
        result, calls = self.run_with_fake_python("generate.py --check")
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertIn('error: release preflight step "version" failed with exit code 7', result.stderr)
        self.assertIn("FAIL  version", result.stderr)
        self.assertEqual(len(calls), 1, f"later commands ran after the failure: {calls}")

    def test_later_step_failure_reports_earlier_passes(self):
        result, calls = self.run_with_fake_python("test_doc_links")
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertIn("PASS  version", result.stderr)
        self.assertIn('error: release preflight step "docs" failed with exit code 7', result.stderr)

    def test_all_steps_green_prints_summary(self):
        result, _ = self.run_with_fake_python("never-matches")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[preflight] PASS  version", result.stdout)
        self.assertIn("[preflight] PASS  docs", result.stdout)

    def test_unknown_or_empty_model_platform_is_rejected(self):
        result = subprocess.run(["/bin/bash", str(PREFLIGHT), "--models", "android"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Unknown --models platform: android", result.stderr)
        for value in ("--models=", "--models=macos,", "--models=,ios"):
            with self.subTest(value=value):
                result = subprocess.run(["/bin/bash", str(PREFLIGHT), value], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("--models needs macos,ios|macos|ios|none", result.stderr)

    def test_mac_typecheck_covers_every_source_set_of_the_app_build(self):
        build = (ROOT / "RawLabMac/build.sh").read_text(encoding="utf-8")
        preflight = PREFLIGHT.read_text(encoding="utf-8")
        app_compile = build[build.index("APP_SOURCES=()"):build.index('-o "$APP/Contents/MacOS/RawLabMac"')]
        inputs = re.findall(r'find "\$ROOT/[^"]+" -name \'\*\.swift\'', app_compile)
        inputs += re.findall(r'"\$ROOT"/\S+\.swift', app_compile)
        inputs += re.findall(r'-import-objc-header "[^"]+"', app_compile)
        inputs += re.findall(r'-fmodule-map-file=[^"]+', build)
        self.assertGreaterEqual(len(inputs), 5, inputs)
        for item in inputs:
            self.assertIn(item, preflight, f"preflight typecheck no longer matches RawLabMac/build.sh input {item}")


if __name__ == "__main__":
    unittest.main()
