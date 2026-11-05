"""Exercise the iOS SDK floor without requiring Xcode on the contracts runner."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECK = Path(__file__).with_name("check-ios-sdk.sh")


class IOSSDKTests(unittest.TestCase):
    def run_check(self, versions, *sdks):
        with tempfile.TemporaryDirectory(prefix="rawlab-ios-sdk-") as directory:
            tools = Path(directory)
            xcrun = tools / "xcrun"
            xcrun.write_text(f'''#!{sys.executable}
import json, os, sys
if len(sys.argv) != 4 or sys.argv[1] != "--sdk" or sys.argv[3] != "--show-sdk-version":
    sys.exit("Unexpected SDK query")
version = json.loads(os.environ["RAWLAB_TEST_SDKS"]).get(sys.argv[2])
if version is None:
    sys.exit("SDK not found: " + sys.argv[2])
print(version)
''')
            xcrun.chmod(0o755)
            environment = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.defpath}",
                           "RAWLAB_TEST_SDKS": json.dumps(versions)}
            return subprocess.run(["bash", str(CHECK), *sdks], env=environment,
                                  capture_output=True, text=True)

    def test_accepts_27_1_and_newer_sdks_numerically(self):
        for version in ("27.1", "27.1.1", "27.10", "28.0"):
            with self.subTest(version=version):
                result = self.run_check({"iphoneos": version, "iphonesimulator": version})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rejects_old_sdks_with_actionable_error(self):
        for version in ("16.4", "26.4", "27.0"):
            with self.subTest(version=version):
                result = self.run_check({"iphoneos": version, "iphonesimulator": version})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("27.1", result.stderr)
                self.assertIn(version, result.stderr)
                self.assertIn("DEVELOPER_DIR", result.stderr)

    def test_new_device_sdk_does_not_hide_old_simulator_sdk(self):
        result = self.run_check({"iphoneos": "27.1", "iphonesimulator": "27.0"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("iphonesimulator", result.stderr)

    def test_checks_the_selected_sdk_path_instead_of_another_installed_sdk(self):
        selected = "/Applications/Xcode 27.1.app/SDKs/iPhoneSimulator27.1.sdk"
        result = self.run_check({selected: "27.1", "iphoneos": "27.0", "iphonesimulator": "27.0"}, selected)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_check({selected: "27.0", "iphoneos": "27.1", "iphonesimulator": "27.1"}, selected)
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_missing_or_invalid_sdk_versions(self):
        for version in (None, "", "unknown", "27.x"):
            with self.subTest(version=version):
                result = self.run_check({"iphoneos": version})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SDK", result.stderr)


if __name__ == "__main__":
    unittest.main()
