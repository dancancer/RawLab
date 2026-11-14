"""Exercise exact-hit dependency reuse without downloading third-party code."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("cmake"), "CMake is required")
class CachedLensTests(unittest.TestCase):
    def configure(self, hit, missing_library=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = root / "lens-dependencies.cmake"
            shutil.copy2(ROOT / "lutools/cmake/lens-dependencies.cmake", module)
            (root / "build-lens-dependencies.py").write_text("raise SystemExit('Dependency build requested')\n")
            (root / "CMakeLists.txt").write_text(
                'cmake_minimum_required(VERSION 3.22)\nproject(CacheTest LANGUAGES C)\n'
                'set(IOS ON)\nset(CMAKE_OSX_ARCHITECTURES arm64)\n'
                'include("${CMAKE_CURRENT_SOURCE_DIR}/lens-dependencies.cmake")\n')
            prefix = root / "build/lens-dependencies/install"
            (prefix / "include/lensfun").mkdir(parents=True)
            (prefix / "include/lensfun/lensfun.h").touch()
            (prefix / "licenses").mkdir()
            (prefix / "lib").mkdir()
            libraries = {}
            for name in ("lensfun", "glib-2.0", "pcre2-8", "intl"):
                path = prefix / "lib" / f"lib{name}.a"
                if not (missing_library and name == "lensfun"):
                    path.touch()
                libraries[name] = str(path)
            (prefix / "libraries.json").write_text(json.dumps(libraries))
            return subprocess.run(
                ["cmake", "-S", str(root), "-B", str(root / "build"), f"-DPython3_EXECUTABLE={sys.executable}"],
                env={**os.environ, "RAWLAB_CI_CACHE_HIT": hit}, text=True, capture_output=True)

    def test_exact_hit_uses_existing_libraries_without_running_builder(self):
        result = self.configure("true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cold_or_partial_hit_still_builds_dependencies(self):
        for hit in ("", "false"):
            with self.subTest(hit=hit):
                result = self.configure(hit)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Dependency build requested", result.stderr)

    def test_missing_cached_library_is_not_accepted(self):
        result = self.configure("true", missing_library=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing Lensfun dependency", result.stdout + result.stderr)


class CachedMacTests(unittest.TestCase):
    def build(self, hit, python=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "RawLabMac"
            scripts.mkdir()
            for name in ("build.sh", "build-env.sh", "release-config.sh"):
                shutil.copy2(ROOT / "RawLabMac" / name, scripts / name)
            for name in ("build-dependencies.sh", "build-chroma-dependency.sh",
                         "build-wavelet-dependency.sh", "build-tiff-dependency.sh"):
                (scripts / name).write_text(f"echo 'Dependency build requested: {name}' >&2\nexit 29\n")
            (scripts / "build-lens-dependency.sh").write_text("echo 'Lensfun validation retained'\n")
            # 本测试在产品配置处终止；Sparkle 打包由独立 bundle 检查负责。
            (scripts / "prepare-sparkle.sh").write_text(
                "echo 'Sparkle prepared' >&2\nprintf '%s\\n' /unused/Sparkle.framework\n")
            tools = root / "tools"
            tools.mkdir()
            for name, content in (("pkg-config", "exit 0"),
                                  ("cmake", "echo 'Product configure reached'\n"
                                            'echo "cmake args: $*"\nexit 31')):
                executable = tools / name
                executable.write_text("#!/bin/sh\n" + content + "\n")
                executable.chmod(0o755)
            env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                   "RAWLAB_RUM": "0", "RAWLAB_RUM_LOCAL": "0", "RAWLAB_ARCH": "arm64",
                   "MACOSX_DEPLOYMENT_TARGET": "14.0", "RAWLAB_CI_CACHE_HIT": hit}
            env.pop("PYTHON", None)
            expected = shutil.which("python3")
            if python is not None:
                env["PYTHON"] = python
                if not os.path.isabs(python):
                    interpreter = root / python
                    interpreter.parent.mkdir(parents=True, exist_ok=True)
                    interpreter.write_text("#!/bin/sh\nexit 0\n")
                    interpreter.chmod(0o755)
                    expected = str(interpreter.resolve())
            result = subprocess.run(
                ["bash", str(scripts / "build.sh")], text=True, capture_output=True,
                cwd=root, env=env)
            return result, expected

    def test_exact_hit_still_configures_product_and_validates_lensfun(self):
        result, _ = self.build("true")
        self.assertEqual(result.returncode, 31, result.stdout + result.stderr)
        self.assertIn("Lensfun validation retained", result.stdout)
        self.assertIn("Product configure reached", result.stdout)
        self.assertNotIn("Dependency build requested", result.stderr)

    def test_local_build_does_not_reuse_libraw_without_current_patch_stamp(self):
        result, _ = self.build("")
        self.assertEqual(result.returncode, 29, result.stdout + result.stderr)
        self.assertIn("Dependency build requested: build-dependencies.sh", result.stderr)

    def test_missing_python_exits_2_before_any_download_or_build(self):
        for hit in ("", "true"):
            with self.subTest(hit=hit):
                result, _ = self.build(hit, python="/no/such/python")
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("Python interpreter not found", result.stderr)
                combined = result.stdout + result.stderr
                for marker in ("Sparkle prepared", "Dependency build requested",
                               "Lensfun validation retained", "Product configure reached"):
                    self.assertNotIn(marker, combined)

    @unittest.skipUnless(shutil.which("python3"), "python3 is required on PATH")
    def test_default_python_reaches_cmake_as_absolute_executable(self):
        result, expected = self.build("true")
        self.assertEqual(result.returncode, 31, result.stdout + result.stderr)
        self.assertTrue(os.path.isabs(expected))
        self.assertIn(f"-DPython3_EXECUTABLE={expected}", result.stdout)

    def test_relative_python_is_resolved_to_absolute_for_cmake_and_not_dropped(self):
        result, expected = self.build("true", python=".venv/bin/python3")
        self.assertEqual(result.returncode, 31, result.stdout + result.stderr)
        self.assertTrue(os.path.isabs(expected))
        self.assertIn(f"-DPython3_EXECUTABLE={expected}", result.stdout)


if __name__ == "__main__":
    unittest.main()
