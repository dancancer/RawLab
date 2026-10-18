"""A real Xcode build must reuse dependencies, never cached RawLab objects."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from native_cache import cache_paths, selected_files


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcodebuild"), "Requires Xcode")
class XcodeCacheBoundaryTests(unittest.TestCase):
    def run_command(self, arguments):
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def copy_files(self, source, destination, paths):
        for path in paths:
            target = destination / path.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            if path.is_symlink():
                target.symlink_to(os.readlink(path))
            else:
                shutil.copy2(path, target)

    def test_restored_dependencies_are_unchanged_but_modified_product_rebuilds(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "work"
            source = root / "project"
            shutil.copytree(Path(__file__).with_name("fixtures") / "native-cache", source)
            build = root / "lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64"
            configure = ["cmake", "-S", str(source), "-B", str(build), "-G", "Xcode",
                         "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO"]
            compile_command = ["cmake", "--build", str(build), "--config", "Release", "--target", "sony2fuji", "-j", "2"]
            self.run_command(configure)
            self.run_command(compile_command)
            binary = build / "output/sony2fuji.framework/sony2fuji"
            inspect = [sys.executable, "-c", "import ctypes,sys; print(ctypes.CDLL(sys.argv[1]).answer())", str(binary)]
            self.assertEqual(self.run_command(inspect).strip(), "41")
            objects = list(build.glob("build/rawlab_dng_sdk.build/**/*.o"))
            self.assertTrue(objects, "Fixture did not exercise Xcode dependency objects")
            timestamps = {path: path.stat().st_mtime_ns for path in objects}
            files = selected_files(root, cache_paths("ios", "arm64-x86_64"))
            self.assertTrue(set(objects).issubset(files))
            self.assertFalse(any("sony2fuji" in str(path.relative_to(build)) for path in files))
            archive = Path(temporary) / "cache"
            self.copy_files(root, archive, files)
            shutil.rmtree(build)
            self.copy_files(archive, root, [path for path in archive.rglob("*") if path.is_file() or path.is_symlink()])
            self.assertFalse(binary.exists())
            product = source / "product.cpp"
            product.write_text(product.read_text().replace("+ 1", "+ 2"))
            self.run_command(configure)
            self.run_command(compile_command)
            self.assertEqual(self.run_command(inspect).strip(), "42")
            self.assertEqual(timestamps, {path: path.stat().st_mtime_ns for path in objects},
                             "A cache hit must not silently recompile unchanged dependencies")


if __name__ == "__main__":
    unittest.main()
