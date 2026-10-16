"""Contracts for target-built Lensfun/GLib dependency configuration."""
import argparse
import importlib.util
import io
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock


BUILDER_PATH = Path(__file__).parents[1] / "cmake" / "build-lens-dependencies.py"
SPEC = importlib.util.spec_from_file_location("build_lens_dependencies", BUILDER_PATH)
BUILDER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BUILDER)


class LensDependencyContracts(unittest.TestCase):
    ROOT = BUILDER_PATH.parents[2]

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

    def test_lipo_input_precedes_variadic_architecture_option(self):
        script = (self.ROOT / "RawLabMac" / "build-lens-dependency.sh").read_text()
        calls = [shlex.split(line) for line in script.splitlines()
                 if line.strip().startswith("lipo ")]
        # Xcode 26 treats every argument after -verify_arch as an architecture.
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:4], ["lipo", "$binary", "-verify_arch", "$ARCH"])


if __name__ == "__main__":
    unittest.main()
