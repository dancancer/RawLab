"""Contracts for target-built Lensfun/GLib dependency configuration."""
import argparse
import ast
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


BUILDER_PATH = Path(__file__).parents[1] / "cmake" / "build-lens-dependencies.py"
SPEC = importlib.util.spec_from_file_location("build_lens_dependencies", BUILDER_PATH)
BUILDER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BUILDER)


class LensDependencyContracts(unittest.TestCase):
    ROOT = BUILDER_PATH.parents[2]

    def test_android_abis_map_and_reject_unknown(self):
        """An unsupported ABI must be rejected instead of silently building x86_64."""
        self.assertEqual(BUILDER.android_triple("arm64-v8a"), "aarch64-linux-android")
        self.assertEqual(BUILDER.android_triple("x86_64"), "x86_64-linux-android")
        for arch in ("armeabi-v7a", "x86", ""):
            with self.assertRaisesRegex(RuntimeError, "Unsupported Android ABI"):
                BUILDER.android_triple(arch)

    def test_invalid_download_is_never_published_to_shared_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            sources = Path(temporary)
            spec = {"file": "dependency.tar.gz", "url": "https://example.invalid/archive", "sha256": "0" * 64}
            with mock.patch.object(BUILDER.urllib.request, "urlopen", return_value=io.BytesIO(b"invalid")):
                with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                    BUILDER.fetch(spec, sources, None)
            self.assertFalse((sources / spec["file"]).exists())
            self.assertEqual(list(sources.iterdir()), [])

    @staticmethod
    def fake_tool_pins(cache):
        """Write wheel-shaped archives into cache and pin them like the manifest does."""
        binary = "ninja-1.13.2.data/scripts/" + ("ninja.exe" if os.name == "nt" else "ninja")
        pins = {}
        for name, member in (("meson", "mesonbuild/__init__.py"), ("ninja", binary)):
            key = BUILDER.tool_wheel_key(name)
            wheel = cache / (key + ".whl")
            with zipfile.ZipFile(wheel, "w") as package:
                package.writestr(member, "fake " + name)
            pins[key] = {"url": "https://example.invalid/" + wheel.name, "file": wheel.name,
                         "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest()}
        return pins

    def test_tool_wheels_install_offline_from_pinned_source_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = root / "cache"
            cache.mkdir()
            pins = self.fake_tool_pins(cache)
            with mock.patch.object(BUILDER.urllib.request, "urlopen", side_effect=AssertionError("network used")):
                BUILDER.install_tools(root / "tools", pins, root / "sources", cache)
            self.assertTrue((root / "tools" / "mesonbuild" / "__init__.py").is_file())
            self.assertTrue((root / "tools" / "bin" / ("ninja.exe" if os.name == "nt" else "ninja")).is_file())

    def test_tampered_tool_wheel_fails_manifest_checksum(self):
        for name in ("meson", "ninja"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                cache = root / "cache"
                cache.mkdir()
                pins = self.fake_tool_pins(cache)
                wheel = cache / pins[BUILDER.tool_wheel_key(name)]["file"]
                data = bytearray(wheel.read_bytes())
                data[-1] ^= 1
                wheel.write_bytes(bytes(data))
                with mock.patch.object(BUILDER.urllib.request, "urlopen", side_effect=AssertionError("network used")):
                    with self.assertRaisesRegex(RuntimeError, "checksum mismatch: " + wheel.name):
                        BUILDER.install_tools(root / "tools", pins, root / "sources", cache)

    def test_missing_host_tool_pin_is_an_explicit_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pins = {"meson": {"url": "https://example.invalid/m.whl", "file": "m.whl", "sha256": "0" * 64}}
            with mock.patch.object(BUILDER, "fetch") as fetch, \
                    mock.patch.object(BUILDER.platform, "machine", return_value="riscv64"), \
                    mock.patch.object(BUILDER.sys, "platform", "linux"), \
                    mock.patch.object(BUILDER.os, "name", "posix"):
                with self.assertRaisesRegex(RuntimeError, "No pinned Meson/Ninja wheel .*: ninja-linux-riscv64$"):
                    BUILDER.install_tools(root / "tools", pins, root / "sources", None)
            fetch.assert_not_called()

    def test_manifest_pins_tool_wheels_for_supported_build_hosts(self):
        manifest = json.loads((self.ROOT / "lutools/cmake/lens-dependencies.json").read_text())
        pins = manifest["tools"]
        self.assertEqual(set(pins), {"meson", "ninja-macos", "ninja-windows-amd64",
                                     "ninja-linux-x86_64", "ninja-linux-aarch64"})
        for key, spec in pins.items():
            version = "meson-1.12.1-" if key == "meson" else "ninja-1.13.2-"
            self.assertTrue(spec["file"].startswith(version), spec["file"])
            self.assertTrue(spec["url"].endswith("/" + spec["file"]), spec["url"])
            self.assertRegex(spec["sha256"], "^[0-9a-f]{64}$")
        for key in ("ninja-linux-x86_64", "ninja-linux-aarch64"):
            self.assertIn("-manylinux", pins[key]["file"])

    @staticmethod
    def mac_args():
        return argparse.Namespace(
            platform="macos",
            arch="arm64",
            cc="/usr/bin/clang",
            cxx="/usr/bin/clang++",
            ar="/usr/bin/ar",
            sysroot="/Applications/Xcode.app/SDKs/MacOSX.sdk",
            minimum="14.0",
        )

    def test_macos_cross_file_uses_darwin_and_minimum_target(self):
        cross = BUILDER.cross_file(self.mac_args())

        self.assertIn("system = 'darwin'", cross)
        self.assertIn("objc = '/usr/bin/clang'", cross)
        self.assertIn("'-mmacosx-version-min=14.0'", cross)
        self.assertIn("'-isysroot', '/Applications/Xcode.app/SDKs/MacOSX.sdk'", cross)

    def test_macos_glib_build_is_shared_and_pins_shared_fallbacks(self):
        options = BUILDER.glib_options("macos")

        self.assertIn("-Ddefault_library=shared", options)
        for name in ("pcre2", "libffi", "intl", "zlib"):
            self.assertIn(f"-D{name}:default_library=shared", options)

    def test_mobile_glib_build_remains_static(self):
        options = BUILDER.glib_options("ios")

        self.assertIn("-Ddefault_library=static", options)
        self.assertNotIn("-Dpcre2:default_library=shared", options)

    def test_macos_version_check_uses_numeric_components(self):
        helper = self.ROOT / "RawLabMac" / "build-env.sh"
        cases = {
            ("13.6", "14.0"): True,
            ("14.0", "14.0"): True,
            ("14.0.1", "14.1"): True,
            ("14.0.2", "14.0.1"): False,
            ("14.10", "14.2"): False,
            ("14.2", "14.10"): True,
            ("", "14.0"): False,
        }
        for (actual, required), expected in cases.items():
            with self.subTest(actual=actual, required=required):
                result = subprocess.run(
                    ["bash", "-c",
                     'ROOT="$1"; source "$ROOT/RawLabMac/build-env.sh"; '
                     'rawlab_macos_version_at_most "$2" "$3"',
                     "test", str(self.ROOT), actual, required],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_macos_reads_archives_from_shared_cache_without_copying(self):
        target = Path("/target/arch/sources")
        shared = Path("/shared/macos-sources")

        self.assertEqual(BUILDER.archive_sources("macos", target, shared), shared)
        self.assertEqual(BUILDER.archive_sources("ios", target, shared), target)

    def test_only_macos_lensfun_configure_requests_fresh_cmake_cache(self):
        self.assertEqual(BUILDER.cmake_fresh_args("macos"), ["--fresh"])
        self.assertEqual(BUILDER.cmake_fresh_args("android"), [])
        self.assertEqual(BUILDER.cmake_fresh_args("ios"), [])

    def test_windows_lensfun_data_stays_inside_the_install_prefix(self):
        tree = ast.parse(BUILDER_PATH.read_text())
        condition = ast.dump(ast.parse('args.platform == "windows"', mode='eval').body)
        branches = [node for node in ast.walk(tree) if isinstance(node, ast.If)
                    and ast.dump(node.test) == condition
                    and any(isinstance(child, ast.AugAssign)
                            and isinstance(child.target, ast.Name)
                            and child.target.id == 'configure' for child in node.body)]
        self.assertEqual(len(branches), 1)
        prefix = Path('C:/ci/lens-dependencies/install')
        scope = {'configure': [], 'prefix': prefix}
        # Exercise the real Windows options without downloading or compiling dependencies.
        options = ast.Module(body=branches[0].body, type_ignores=[])
        exec(compile(options, str(BUILDER_PATH), 'exec'), scope)
        self.assertIn('-DPLATFORM_WINDOWS=ON', scope['configure'])
        self.assertIn('-DCMAKE_INSTALL_DATAROOTDIR=' + str(prefix / 'share'), scope['configure'])

    def test_lipo_input_precedes_variadic_architecture_option(self):
        script = (self.ROOT / "RawLabMac" / "build-lens-dependency.sh").read_text()
        calls = [shlex.split(line) for line in script.splitlines()
                 if line.strip().startswith("lipo ")]
        # Xcode 26 treats every argument after -verify_arch as an architecture.
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:4], ["lipo", "$binary", "-verify_arch", "$ARCH"])


if __name__ == "__main__":
    unittest.main()
