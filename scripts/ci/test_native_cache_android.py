"""Exercise AGP's configure/restore boundary using its real native build tasks."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from native_cache import ROOT, cache_paths, selected_files


@unittest.skipUnless(os.environ.get("RAWLAB_TEST_ANDROID_CACHE") == "1", "Requires the Android toolchain and cached AGP")
class AndroidCacheBoundaryTests(unittest.TestCase):
    def test_gradle_keeps_restored_dependencies_and_rebuilds_product(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "work"
            project = root / "RawLabAndroid"
            shutil.copytree(Path(__file__).with_name("fixtures") / "android-cache", project)
            command = [str(ROOT / "RawLabAndroid/gradlew"), "-p", str(project),
                       ":app:buildCMakeDebug[arm64-v8a]", "--offline", "--no-daemon", "--max-workers=2"]
            result = subprocess.run(command, env={**os.environ, "RAWLAB_CI_CACHE_HIT": "false"},
                                    capture_output=True, text=True, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            binaries = list(project.glob("app/build/intermediates/cxx/Debug/*/obj/arm64-v8a/librawlab-jni.so"))
            self.assertEqual(len(binaries), 1)
            original = binaries[0].read_bytes()
            files = selected_files(root, cache_paths("android", "arm64-x86_64"))
            self.assertTrue(any(path.name == "libraries.json" for path in files))
            for metadata in ("configure_fingerprint.bin", "metadata_generation_command.txt"):
                self.assertTrue(any(path.name == metadata for path in files), metadata)
            objects = {path: (path.stat().st_mtime_ns, path.read_bytes())
                       for path in files if path.suffix == ".o"}
            self.assertTrue(objects, "The cache must contain a compiled dependency")
            archive = Path(temporary) / "cache"
            for path in files:
                target = archive / path.relative_to(root)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
            shutil.rmtree(project / "app/.cxx")
            shutil.rmtree(project / ".gradle")
            shutil.rmtree(project / "app/build", ignore_errors=True)
            shutil.copytree(archive, root, dirs_exist_ok=True)
            self.assertFalse(binaries[0].exists(), "Product binaries must not come from the cache")
            source = project / "app/src/main/cpp/product.cpp"
            source.write_text(source.read_text().replace("+ 2", "+ 3"))
            result = subprocess.run(command, env={**os.environ, "RAWLAB_CI_CACHE_HIT": "true"},
                                    capture_output=True, text=True, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(objects, {path: (path.stat().st_mtime_ns, path.read_bytes()) for path in objects})
            self.assertNotEqual(original, binaries[0].read_bytes())


if __name__ == "__main__":
    unittest.main()
