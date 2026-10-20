"""Exercise framework embedding with real iOS Mach-O deployment targets."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("embed-ios.sh")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "Requires Xcode")
class EmbedIOSFrameworkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sdk = self.root / "sdk"
        self.build = self.root / "build"

    def run_command(self, arguments, **kwargs):
        result = subprocess.run(arguments, capture_output=True, text=True, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def make_framework(self, slice_name, targets):
        framework = self.sdk / "AlibabaCloudRUMSDK.xcframework" / slice_name / "AlibabaCloudRUMSDK.framework"
        framework.mkdir(parents=True)
        (self.sdk / "AlibabaCloudRUM.xcframework" / slice_name).mkdir(parents=True)
        source = self.root / "library.c"
        source.write_text("int answer(void) { return 42; }\n")
        binaries = []
        for target in targets:
            sdk = "iphonesimulator" if target.endswith("-simulator") else "iphoneos"
            sdk_path = self.run_command(["xcrun", "--sdk", sdk, "--show-sdk-path"])
            binary = self.root / target
            self.run_command(["xcrun", "clang", "-target", target, "-isysroot", sdk_path,
                              "-dynamiclib", str(source), "-o", str(binary)])
            binaries.append(binary)
        self.run_command(["xcrun", "lipo", "-create", *map(str, binaries), "-output",
                          str(framework / "AlibabaCloudRUMSDK")])
        with (framework / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleExecutable": "AlibabaCloudRUMSDK", "MinimumOSVersion": "100.0"}, output)
        return framework

    def embed(self, slice_name, conditions="RAWLAB_RUM"):
        self.run_command(["bash", str(SCRIPT)], env={
            **os.environ,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": conditions,
            "RAWLAB_RUM_SDK_DIR": str(self.sdk),
            "RAWLAB_RUM_SLICE": slice_name,
            "TARGET_BUILD_DIR": str(self.build),
            "FRAMEWORKS_FOLDER_PATH": "RawLab.app/Frameworks",
            "CODE_SIGNING_ALLOWED": "NO",
        })
        return self.build / "RawLab.app/Frameworks/AlibabaCloudRUMSDK.framework"

    def assert_embedded_target(self, slice_name, targets, expected):
        source = self.make_framework(slice_name, targets)
        before = {file.name: file.read_bytes() for file in source.iterdir()}
        embedded = self.embed(slice_name)
        with (embedded / "Info.plist").open("rb") as stream:
            self.assertEqual(plistlib.load(stream)["MinimumOSVersion"], expected)
        self.assertEqual((embedded / "AlibabaCloudRUMSDK").read_bytes(), before["AlibabaCloudRUMSDK"])
        self.assertEqual({file.name: file.read_bytes() for file in source.iterdir()}, before,
                         "Embedding must not mutate the shared vendor SDK")

    def test_device_metadata_matches_binary_deployment_target(self):
        self.assert_embedded_target("ios-arm64", ["arm64-apple-ios12.0"], "12.0")

    def test_simulator_metadata_covers_both_architecture_targets(self):
        self.assert_embedded_target("ios-arm64_x86_64-simulator",
                                    ["x86_64-apple-ios12.0-simulator", "arm64-apple-ios14.0-simulator"], "14.0")

    def test_build_without_rum_does_not_require_vendor_sdk(self):
        self.assertFalse(self.embed("ios-arm64", conditions="DEBUG").exists())


if __name__ == "__main__":
    unittest.main()
