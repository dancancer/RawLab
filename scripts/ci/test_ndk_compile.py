"""Exercise NDK toolchain selection in RawLabAndroid/tests/ndk-compile.sh."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "RawLabAndroid/tests/ndk-compile.sh"


class NDKCompileSelectionTests(unittest.TestCase):
    def run_script(self, root, *, ndk_versions=(), valid_versions=()):
        tools = root / "bin"
        tools.mkdir()
        log = root / "cmake.log"
        cmake = tools / "cmake"
        cmake.write_text(f'''#!{sys.executable}
import os, sys
with open(os.environ["RAWLAB_NDK_TEST_LOG"], "a", encoding="utf-8") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\\n")
''')
        cmake.chmod(0o755)

        sdk = root / "sdk"
        ndk_root = sdk / "ndk"
        ndk_root.mkdir(parents=True)
        for version in ndk_versions:
            version_dir = ndk_root / version
            version_dir.mkdir(parents=True, exist_ok=True)
            if version in valid_versions:
                toolchain = version_dir / "build/cmake/android.toolchain.cmake"
                toolchain.parent.mkdir(parents=True, exist_ok=True)
                toolchain.write_text("# stub toolchain\n", encoding="utf-8")

        env = {k: v for k, v in os.environ.items() if k != "ANDROID_NDK_HOME"}
        env.update(
            PATH=f"{tools}{os.pathsep}/usr/bin{os.pathsep}/bin",
            ANDROID_HOME=str(sdk),
            RAWLAB_NDK_TEST_LOG=str(log),
        )
        result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
        return result, log.read_text(encoding="utf-8") if log.exists() else ""

    def test_skips_stray_or_partial_ndk_dirs_and_picks_highest_valid_version(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-ndk-select-") as directory:
            root = Path(directory)
            result, log = self.run_script(
                root,
                ndk_versions=("27.1.12297006", "27.10.0", "28.0.0-partial"),
                valid_versions=("27.1.12297006", "27.10.0"),
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(
                f"-DCMAKE_TOOLCHAIN_FILE={root / 'sdk/ndk/27.10.0/build/cmake/android.toolchain.cmake'}",
                log,
            )

    def test_partial_pinned_version_does_not_shadow_valid_ndk(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-ndk-pinned-") as directory:
            root = Path(directory)
            result, log = self.run_script(
                root,
                ndk_versions=("27.2.12479018", "27.3.13750724"),
                valid_versions=("27.3.13750724",),
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(
                f"-DCMAKE_TOOLCHAIN_FILE={root / 'sdk/ndk/27.3.13750724/build/cmake/android.toolchain.cmake'}",
                log,
            )

    def test_empty_or_invalid_sdk_fails_closed(self):
        for versions in ((), ("28.0.0-partial",)):
            with self.subTest(versions=versions):
                with tempfile.TemporaryDirectory(prefix="rawlab-ndk-empty-") as directory:
                    root = Path(directory)
                    result, log = self.run_script(root, ndk_versions=versions)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Android NDK toolchain not found", result.stderr)
                    self.assertEqual(log, "")


if __name__ == "__main__":
    unittest.main()
