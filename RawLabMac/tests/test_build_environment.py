"""Deployment targets must not reuse higher-minimum dependency binaries."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildEnvironmentTests(unittest.TestCase):
    def test_lens_minimum_os_check_consumes_large_tool_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "RawLabMac"
            tools = root / "tools"
            scripts.mkdir()
            tools.mkdir()
            for name in ("build-env.sh", "build-lens-dependency.sh"):
                shutil.copyfile(ROOT / "RawLabMac" / name, scripts / name)
            prefix, lens = root / "dependencies", root / "lens"
            for path in (prefix, lens):
                (path / "lib").mkdir(parents=True)
            (lens / "lib/liblensfun.dylib").touch()
            (lens / "libraries.json").write_text("{}")
            programs = {
                "pkg-config": '#!/bin/bash\nif [[ "$1" == --variable=prefix ]]; then\n'
                              '  if [[ "$2" == glib-2.0 ]]; then echo "$RAWLAB_DEPENDENCY_PREFIX"; '
                              'else echo "$RAWLAB_LENS_PREFIX"; fi\nfi\n',
                "lipo": "#!/bin/sh\nexit 0\n",
                "otool": f"#!{sys.executable}\nimport os, sys\n"
                         "if sys.argv[1] == '-l':\n"
                         "    legacy = os.environ['TEST_LOAD_COMMAND'] == 'legacy'\n"
                         "    print('cmd LC_VERSION_MIN_MACOSX' if legacy else 'cmd LC_BUILD_VERSION')\n"
                         "    print(('version ' if legacy else 'minos ') + os.environ['TEST_BINARY_MINIMUM'], flush=True)\n"
                         "    for _ in range(256):\n"
                         "        sys.stdout.write('other load command data ' * 512 + '\\n')\n"
                         "        sys.stdout.flush()\n",
            }
            for name, source in programs.items():
                path = tools / name
                path.write_text(source)
                path.chmod(0o755)
            env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                   "RAWLAB_ARCH": "arm64", "MACOSX_DEPLOYMENT_TARGET": "14.0",
                   "RAWLAB_DEPENDENCY_PREFIX": str(prefix), "RAWLAB_LENS_PREFIX": str(lens),
                   "RAWLAB_CI_CACHE_HIT": "true", "RAWLAB_LENS_LOG": str(root / "lens.log"),
                   "SDKROOT": "/unused/sdk", "CC": "cc", "CXX": "c++", "AR": "ar",
                   "CMAKE": "cmake", "JOBS": "1"}
            for command, minimum, expected in (("modern", "14.0", 0), ("modern", "15.0", 1),
                                                ("legacy", "14.0", 0), ("legacy", "15.0", 1)):
                with self.subTest(command=command, minimum=minimum):
                    result = subprocess.run(["bash", str(scripts / "build-lens-dependency.sh")],
                                            env={**env, "TEST_BINARY_MINIMUM": minimum,
                                                 "TEST_LOAD_COMMAND": command},
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    self.assertNotIn("BrokenPipeError", result.stdout + result.stderr)
                    if minimum == "15.0":
                        self.assertIn("Deployment target check failed", result.stdout)

    def test_libraw_stamp_tracks_patch_contents_not_timestamps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("RawLabMac/build-env.sh", "RawLabMac/build-dependencies.sh",
                         "lutools/cmake/libraw/CMakeLists.txt", "lutools/cmake/patch-libraw.cmake",
                         "lutools/cmake/libraw-cameras.cmake", "lutools/cmake/libraw-sony-arw6.cmake",
                         "lutools/cmake/libraw-vng.cmake", "lutools/third_party/libraw/vng_parallel.inc",
                         "lutools/third_party/rawspeed-camera-calibration.inc",
                         "lutools/third_party/nikon_he/entropy.cpp",
                         "lutools/third_party/libraw/sony_arw6.cpp"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("original")
            prefix = root / "prefix"
            stamp = prefix / "share/rawlab/libraw-patch.sha256"

            def invoke(function):
                return subprocess.run(
                    ["/bin/bash", "-euc", 'ROOT="$1"; source "$2"; ' + function,
                     "test", str(root), str(ROOT / "RawLabMac/build-env.sh")],
                    env={**os.environ, "RAWLAB_ARCH": "arm64", "RAWLAB_DEPENDENCY_PREFIX": str(prefix)},
                    capture_output=True, text=True)

            self.assertNotEqual(invoke("rawlab_libraw_patch_current").returncode, 0)
            fingerprint = invoke("rawlab_libraw_patch_fingerprint")
            self.assertEqual(fingerprint.returncode, 0, fingerprint.stderr)
            stamp.parent.mkdir(parents=True)
            stamp.write_text(fingerprint.stdout)
            self.assertEqual(invoke("rawlab_libraw_patch_current").returncode, 0)
            for name in ("lutools/third_party/nikon_he/entropy.cpp",
                         "lutools/third_party/libraw/sony_arw6.cpp", "lutools/cmake/libraw-cameras.cmake",
                         "lutools/cmake/libraw-vng.cmake", "lutools/third_party/libraw/vng_parallel.inc"):
                with self.subTest(source=name):
                    source = root / name
                    source.touch()
                    self.assertEqual(invoke("rawlab_libraw_patch_current").returncode, 0)
                    source.write_text("changed")
                    self.assertNotEqual(invoke("rawlab_libraw_patch_current").returncode, 0)
                    stamp.write_text(invoke("rawlab_libraw_patch_fingerprint").stdout)

    def environment(self, **overrides):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("RAWLAB_") and key != "MACOSX_DEPLOYMENT_TARGET"}
        env.update(overrides)
        command = ('ROOT="$1"; source "$ROOT/RawLabMac/build-env.sh"; '
                   'printf "%s\\0" "$MACOSX_DEPLOYMENT_TARGET" "$ARCH" '
                   '"$RAWLAB_DEPENDENCY_PREFIX" "$RAWLAB_LENS_PREFIX" "$RAWLAB_SOURCE_CACHE" '
                   '"${PKG_CONFIG_PATH:-}" "${PKG_CONFIG_LIBDIR:-}"')
        result = subprocess.run(["/bin/bash", "-euc", command, "test", str(ROOT)],
                                env=env, capture_output=True, text=True)
        return result

    def test_default_target_and_output_paths(self):
        result = self.environment(RAWLAB_ARCH="arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = result.stdout.split("\0")
        self.assertEqual(values[:4], ["14.0", "arm64",
                         str(ROOT / "build/macos-deps/14.0/arm64/install"),
                         str(ROOT / "build/lensfun/14.0/arm64/install")])
        common = subprocess.check_output(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                         cwd=ROOT, text=True).strip()
        self.assertEqual(Path(values[4]).resolve(),
                         (Path(common).parent / ".cache/shared/macos-sources").resolve())

    def test_architecture_and_target_outputs_are_distinct(self):
        results = [self.environment(RAWLAB_ARCH=arch, MACOSX_DEPLOYMENT_TARGET=target)
                   for arch, target in [("arm64", "14.0"), ("x86_64", "14.0"), ("arm64", "15.0")]]
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        paths = [result.stdout.split("\0")[2:4] for result in results]
        self.assertEqual(len({tuple(path) for path in paths}), 3)
        self.assertEqual(len({result.stdout.split("\0")[4] for result in results}), 1)

    def test_invalid_architecture_or_target_is_rejected(self):
        for overrides in ({"RAWLAB_ARCH": "unknown"}, {"MACOSX_DEPLOYMENT_TARGET": "../26.0"}):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(self.environment(**overrides).returncode, 0)

    def test_pkg_config_cannot_fall_back_to_another_build(self):
        result = self.environment(RAWLAB_ARCH="arm64", PKG_CONFIG_PATH="/foreign/build/lib/pkgconfig")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = result.stdout.split("\0")
        expected = f"{values[3]}/lib/pkgconfig:{values[2]}/lib/pkgconfig"
        self.assertEqual(values[5], expected)
        self.assertEqual(values[6], expected)

    def test_full_source_swift_builds_use_bounded_whole_module_compilation(self):
        for relative in ('RawLabMac/build.sh', 'RawLabMac/tests/mac-straighten-preview.sh'):
            with self.subTest(script=relative):
                source = (ROOT / relative).read_text()
                self.assertIn('-whole-module-optimization', source)
                self.assertIn('-num-threads "${JOBS:-$(sysctl -n hw.ncpu)}"', source)
                self.assertNotIn('-Ounchecked', source)

    def test_acceptance_scripts_link_the_requested_build_not_a_stale_default(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / "bin"
            binaries.mkdir()
            compiler = binaries / "swiftc"
            compiler.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nexit 73\n')
            package_config = binaries / "pkg-config"
            package_config.write_text("#!/bin/bash\nexit 0\n")
            compiler.chmod(0o755)
            package_config.chmod(0o755)
            build = root / "release candidate"
            env = {**os.environ, "PATH": f"{binaries}:{os.environ['PATH']}",
                   "RAWLAB_ARCH": "arm64", "RAWLAB_BUILD_DIR": str(build)}
            for script in ("wavelet-render.sh", "agent-recipe-render.sh", "edit-model.sh"):
                with self.subTest(script=script):
                    result = subprocess.run(["bash", str(ROOT / "RawLabMac/tests" / script),
                                             "/unused/raw", "/unused/cli"], env=env,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 73, result.stderr)
                    self.assertIn(str(build / "libsony2fuji_core.a"), result.stdout.splitlines())
                    self.assertNotIn(str(ROOT / "lutools/build-macos/libsony2fuji_core.a"),
                                     result.stdout.splitlines())


if __name__ == "__main__":
    unittest.main()
