"""Contracts and behavioral tests for the single LibRaw manifest across all 4 platforms."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = ROOT / "lutools/cmake/libraw/manifest.json"
MANIFEST_HELPER_PATH = ROOT / "lutools/cmake/libraw/manifest.py"
LIBRAW_CMAKE_PATH = ROOT / "lutools/cmake/libraw/libraw.cmake"

CONSUMER_FILES = (
    "lutools/CMakeLists.txt",
    "lutools/cmake/libraw/CMakeLists.txt",
    "lutools/cmake/libraw/libraw.cmake",
    "RawLabMac/build.sh",
    "RawLabMac/build-dependencies.sh",
    "RawLabMac/build-env.sh",
    "lutools/platform/ios/build-framework.sh",
    "lutools/platform/ios/verify-framework.sh",
    "lutools/platform/ios/dng-jxl.sh",
    "lutools/platform/ios/raw-compatibility.sh",
    "lutools/tests/raw-codecs-ios.sh",
    "RawLabAndroid/app/src/main/cpp/CMakeLists.txt",
    "RawLabWindows/native/CMakeLists.txt",
    "scripts/ci/native_cache.py",
)

SHELL_SCRIPTS = (
    "RawLabMac/build.sh",
    "RawLabMac/build-dependencies.sh",
    "RawLabMac/build-env.sh",
    "lutools/platform/ios/build-framework.sh",
    "lutools/platform/ios/verify-framework.sh",
    "lutools/platform/ios/dng-jxl.sh",
    "lutools/platform/ios/raw-compatibility.sh",
    "lutools/tests/raw-codecs-ios.sh",
)


def _load_manifest_module():
    spec = importlib.util.spec_from_file_location("libraw_manifest", MANIFEST_HELPER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _load_native_cache_module():
    path = ROOT / "scripts/ci/native_cache.py"
    spec = importlib.util.spec_from_file_location("native_cache_for_libraw_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _make_dummy_tar_gz(archive_path: Path, top_dir: str, files: dict[str, str]) -> str:
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    staging = archive_path.parent / f".stage-{archive_path.stem}"
    if staging.exists():
        shutil.rmtree(staging)
    for rel, content in files.items():
        target = staging / top_dir / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    with tarfile.open(archive_path, "w:gz") as tar:
        tar.add(staging / top_dir, arcname=top_dir)
    shutil.rmtree(staging)
    return hashlib.sha256(archive_path.read_bytes()).hexdigest()


class LibRawSingleManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest_mod = _load_manifest_module()
        cls.manifest = cls.manifest_mod.load_manifest(MANIFEST_PATH)

    def test_manifest_schema_and_pinned_fields_are_consistent(self):
        self.assertEqual(self.manifest["schema_version"], 1)
        libraw = self.manifest["libraw"]
        cmake_wrap = self.manifest["libraw_cmake"]

        version = libraw["version"]
        self.assertTrue(version)
        self.assertEqual(libraw["tag"], f"{version}-Release")
        self.assertEqual(libraw["archive"], f"LibRaw-{version}.tar.gz")
        self.assertEqual(libraw["directory"], f"LibRaw-{version}")
        self.assertIn(version, libraw["url"])
        self.assertRegex(libraw["sha256"], r"^[0-9a-f]{64}$")
        self.assertGreaterEqual(len(libraw["license_files"]), 1)

        revision = cmake_wrap["revision"]
        self.assertRegex(revision, r"^[0-9a-f]{40}$")
        self.assertIn(revision[:7], cmake_wrap["archive"])
        self.assertEqual(cmake_wrap["directory"], f"LibRaw-cmake-{revision}")
        self.assertIn(revision, cmake_wrap["url"])
        self.assertRegex(cmake_wrap["sha256"], r"^[0-9a-f]{64}$")

    def test_no_platform_script_or_cmake_duplicates_libraw_pins(self):
        libraw = self.manifest["libraw"]
        cmake_wrap = self.manifest["libraw_cmake"]
        forbidden_literals = (
            libraw["version"],
            libraw["sha256"],
            libraw["url"],
            cmake_wrap["revision"],
            cmake_wrap["revision"][:7],
            cmake_wrap["sha256"],
            cmake_wrap["url"],
        )
        for rel in CONSUMER_FILES:
            text = (ROOT / rel).read_text(encoding="utf-8")
            for literal in forbidden_literals:
                with self.subTest(file=rel, literal=literal):
                    self.assertNotIn(
                        literal,
                        text,
                        f"{rel} hardcodes LibRaw manifest value {literal!r}",
                    )

        # Verify each platform entrypoint actually binds to the shared manifest/module.
        self.assertIn("cmake/libraw/libraw.cmake", (ROOT / "lutools/CMakeLists.txt").read_text(encoding="utf-8"))
        self.assertIn("libraw.cmake", (ROOT / "lutools/cmake/libraw/CMakeLists.txt").read_text(encoding="utf-8"))
        self.assertIn("lutools/cmake/libraw/libraw.cmake", (ROOT / "RawLabAndroid/app/src/main/cpp/CMakeLists.txt").read_text(encoding="utf-8"))
        self.assertIn("rawlab_add_libraw_shared()", (ROOT / "RawLabAndroid/app/src/main/cpp/CMakeLists.txt").read_text(encoding="utf-8"))
        self.assertIn("lutools/cmake/libraw/libraw.cmake", (ROOT / "RawLabWindows/native/CMakeLists.txt").read_text(encoding="utf-8"))
        self.assertIn("rawlab_add_libraw_shared()", (ROOT / "RawLabWindows/native/CMakeLists.txt").read_text(encoding="utf-8"))
        self.assertIn("lutools/cmake/libraw/manifest.py", (ROOT / "RawLabMac/build-dependencies.sh").read_text(encoding="utf-8"))
        self.assertIn("lutools/cmake/libraw/manifest.py", (ROOT / "RawLabMac/build.sh").read_text(encoding="utf-8"))
        self.assertIn("cmake/libraw/manifest.py", (ROOT / "lutools/platform/ios/build-framework.sh").read_text(encoding="utf-8"))
        self.assertIn("lutools/cmake/libraw/manifest.json", (ROOT / "scripts/ci/native_cache.py").read_text(encoding="utf-8"))

    def test_shell_scripts_pass_bash_syntax_check(self):
        for rel in SHELL_SCRIPTS:
            with self.subTest(script=rel):
                result = subprocess.run(["bash", "-n", str(ROOT / rel)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_manifest_helper_resolves_mutated_manifest_for_shell_and_fields(self):
        mutated = {
            "schema_version": 1,
            "libraw": {
                "version": "9.99.1",
                "tag": "9.99.1-Release",
                "archive": "LibRaw-9.99.1.tar.gz",
                "directory": "LibRaw-9.99.1",
                "url": "https://example.invalid/LibRaw-9.99.1.tar.gz",
                "sha256": "a" * 64,
                "license_files": ["COPYRIGHT", "LICENSE.LGPL"],
            },
            "libraw_cmake": {
                "revision": "b" * 40,
                "archive": "LibRaw-cmake-bbbbbbb.tar.gz",
                "directory": "LibRaw-cmake-" + ("b" * 40),
                "url": "https://example.invalid/LibRaw-cmake.tar.gz",
                "sha256": "c" * 64,
            },
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.json"
            path.write_text(json.dumps(mutated), encoding="utf-8")

            shell_script = (
                f'env_out="$({sys.executable} {MANIFEST_HELPER_PATH} --manifest {path} --shell)"\n'
                'eval "$env_out"\n'
                'printf "%s\\n" "$RAWLAB_LIBRAW_VERSION" "$RAWLAB_LIBRAW_TAG" '
                '"$RAWLAB_LIBRAW_ARCHIVE" "$RAWLAB_LIBRAW_DIRECTORY" '
                '"$RAWLAB_LIBRAW_URL" "$RAWLAB_LIBRAW_SHA256" '
                '"$RAWLAB_LIBRAW_CMAKE_REVISION" "$RAWLAB_LIBRAW_CMAKE_DIRECTORY" '
                '"${RAWLAB_LIBRAW_LICENSE_FILES[*]}"\n'
            )
            res = subprocess.run(["bash", "-euc", shell_script], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(
                res.stdout.splitlines(),
                [
                    "9.99.1",
                    "9.99.1-Release",
                    "LibRaw-9.99.1.tar.gz",
                    "LibRaw-9.99.1",
                    "https://example.invalid/LibRaw-9.99.1.tar.gz",
                    "a" * 64,
                    "b" * 40,
                    "LibRaw-cmake-" + ("b" * 40),
                    "COPYRIGHT LICENSE.LGPL",
                ],
            )

            field_res = subprocess.run(
                [sys.executable, str(MANIFEST_HELPER_PATH), "--manifest", str(path), "--field", "libraw.version"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(field_res.returncode, 0, field_res.stderr)
            self.assertEqual(field_res.stdout.strip(), "9.99.1")

            mutated["schema_version"] = 99
            path.write_text(json.dumps(mutated), encoding="utf-8")
            with self.assertRaises(ValueError):
                self.manifest_mod.load_manifest(path)

    @unittest.skipUnless(shutil.which("cmake"), "CMake is required")
    def test_cmake_module_loads_mutated_manifest_and_configures_shared_target(self):
        for android_mode in (False, True):
            with self.subTest(android=android_mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                cmake_dir = root / "lutools/cmake"
                libraw_dir = cmake_dir / "libraw"
                libraw_dir.mkdir(parents=True)
                shutil.copy2(LIBRAW_CMAKE_PATH, libraw_dir / "libraw.cmake")

                archive = root / "cache/LibRaw-9.99.1.tar.gz"
                sha256 = _make_dummy_tar_gz(
                    archive,
                    "LibRaw-9.99.1",
                    {
                        "src/dummy.cpp": "int rawlab_dummy_libraw() { return 1; }\n",
                        "src/placeholder_ph.cpp": "#error placeholder must be excluded\n",
                        "COPYRIGHT": "copyright\n",
                        "LICENSE.LGPL": "lgpl\n",
                    },
                )
                mutated = {
                    "schema_version": 1,
                    "libraw": {
                        "version": "9.99.1",
                        "tag": "9.99.1-Release",
                        "archive": "LibRaw-9.99.1.tar.gz",
                        "directory": "LibRaw-9.99.1",
                        "url": "https://example.invalid/unreachable/LibRaw-9.99.1.tar.gz"
                        if android_mode
                        else archive.as_uri(),
                        "sha256": sha256,
                        "license_files": ["COPYRIGHT", "LICENSE.LGPL"],
                    },
                    "libraw_cmake": {
                        "revision": "b" * 40,
                        "archive": "LibRaw-cmake-bbbbbbb.tar.gz",
                        "directory": "LibRaw-cmake-" + ("b" * 40),
                        "url": "https://example.invalid/LibRaw-cmake.tar.gz",
                        "sha256": "c" * 64,
                    },
                }
                (libraw_dir / "manifest.json").write_text(json.dumps(mutated), encoding="utf-8")

                # Stub sibling includes so configure exercises rawlab_add_libraw_shared without network.
                (cmake_dir / "patch-libraw.cmake").write_text(
                    'if(NOT EXISTS "${LIBRAW_SOURCE_DIR}/src/dummy.cpp")\n'
                    '  message(FATAL_ERROR "Missing LIBRAW_SOURCE_DIR")\n'
                    'endif()\n'
                    'file(WRITE "${CMAKE_BINARY_DIR}/patched.txt" "${LIBRAW_SOURCE_DIR}")\n',
                    encoding="utf-8",
                )
                (cmake_dir / "raw-jpeg.cmake").write_text(
                    "add_library(rawlab_jpeg INTERFACE)\n", encoding="utf-8"
                )
                (cmake_dir / "dng-sdk.cmake").write_text(
                    "add_library(rawlab_dng_sdk INTERFACE)\n", encoding="utf-8"
                )

                project_dir = root / "consumer"
                project_dir.mkdir()
                (project_dir / "CMakeLists.txt").write_text(
                    "cmake_minimum_required(VERSION 3.22)\n"
                    "project(LibRawConsumerTest LANGUAGES CXX)\n"
                    f"set(ANDROID {'TRUE' if android_mode else 'FALSE'})\n"
                    f'include("{libraw_dir.as_posix()}/libraw.cmake")\n'
                    "rawlab_add_libraw_shared()\n"
                    'get_target_property(raw_type raw TYPE)\n'
                    'get_target_property(raw_srcs raw SOURCES)\n'
                    'file(WRITE "${CMAKE_BINARY_DIR}/report.json" '
                    '"{\\"version\\":\\"${RAWLAB_LIBRAW_VERSION}\\",'
                    '\\"target\\":\\"${SONY2FUJI_LIBRAW_TARGET}\\",'
                    '\\"dng\\":\\"${SONY2FUJI_DNGSDK_TARGET}\\",'
                    '\\"type\\":\\"${raw_type}\\",'
                    '\\"licenses\\":\\"${RAWLAB_LIBRAW_LICENSE_FILES}\\",'
                    '\\"srcs\\":\\"${raw_srcs}\\",'
                    '\\"source_dir\\":\\"${LIBRAW_SOURCE_DIR}\\"}")\n',
                    encoding="utf-8",
                )

                build_dir = root / "build"
                env = dict(os.environ)
                if android_mode:
                    env["RAWLAB_ANDROID_SOURCE_CACHE"] = str(archive.parent)
                res = subprocess.run(
                    ["cmake", "-S", str(project_dir), "-B", str(build_dir)],
                    env=env,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                report = json.loads((build_dir / "report.json").read_text(encoding="utf-8"))
                self.assertEqual(report["version"], "9.99.1")
                self.assertEqual(report["target"], "raw")
                self.assertEqual(report["dng"], "rawlab_dng_sdk")
                self.assertEqual(report["type"], "SHARED_LIBRARY")
                self.assertEqual(report["licenses"], "COPYRIGHT;LICENSE.LGPL")
                self.assertIn("dummy.cpp", report["srcs"])
                self.assertNotIn("placeholder_ph.cpp", report["srcs"])
                self.assertEqual((build_dir / "patched.txt").read_text(encoding="utf-8"), report["source_dir"])
                if android_mode:
                    self.assertEqual(
                        Path(report["source_dir"]).resolve(),
                        (build_dir / "_deps/libraw-9.99.1-src").resolve(),
                    )

    def test_macos_and_ios_scripts_resolve_mutated_manifest_dynamically(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel in (
                "scripts/ci/apple-sdk-env.sh",
                "RawLabMac/build-env.sh",
                "RawLabMac/build-dependencies.sh",
                "lutools/platform/ios/build-framework.sh",
                "lutools/cmake/libraw/manifest.py",
            ):
                dst = root / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / rel, dst)

            (root / "lutools/cmake/patch-libraw.cmake").write_text("# stub\n", encoding="utf-8")

            sources = root / "fake-sources"
            libraw_tar = sources / "LibRaw-9.99.1.tar.gz"
            libraw_sha = _make_dummy_tar_gz(libraw_tar, "LibRaw-9.99.1", {"COPYRIGHT": "c\n"})
            cmake_tar = sources / "LibRaw-cmake-bbbbbbb.tar.gz"
            cmake_sha = _make_dummy_tar_gz(cmake_tar, "LibRaw-cmake-" + ("b" * 40), {"CMakeLists.txt": ""})

            mutated = {
                "schema_version": 1,
                "libraw": {
                    "version": "9.99.1",
                    "tag": "9.99.1-Release",
                    "archive": "LibRaw-9.99.1.tar.gz",
                    "directory": "LibRaw-9.99.1",
                    "url": "https://example.invalid/LibRaw-9.99.1.tar.gz",
                    "sha256": libraw_sha,
                    "license_files": ["COPYRIGHT"],
                },
                "libraw_cmake": {
                    "revision": "b" * 40,
                    "archive": "LibRaw-cmake-bbbbbbb.tar.gz",
                    "directory": "LibRaw-cmake-" + ("b" * 40),
                    "url": "https://example.invalid/LibRaw-cmake.tar.gz",
                    "sha256": cmake_sha,
                },
            }
            (root / "lutools/cmake/libraw/manifest.json").write_text(json.dumps(mutated), encoding="utf-8")

            tools = root / "bin"
            tools.mkdir()
            log = root / "calls.log"
            (tools / "curl").write_text(
                "#!/bin/sh\n"
                'echo "UNEXPECTED CURL $*" >> "$TEST_LOG"\n'
                "exit 99\n",
                encoding="utf-8",
            )
            (tools / "cmake").write_text(
                "#!/bin/sh\n"
                'echo "cmake $*" >> "$TEST_LOG"\n'
                'case "$*" in *"-S "*) exit 42 ;; esac\n',
                encoding="utf-8",
            )
            (tools / "xcrun").write_text("#!/bin/sh\necho /unused/sdk\n", encoding="utf-8")
            for tool in tools.iterdir():
                tool.chmod(0o755)

            base_env = {
                **os.environ,
                "PATH": f"{tools}:{os.environ['PATH']}",
                "TEST_LOG": str(log),
                "RAWLAB_ARCH": "arm64",
                "MACOSX_DEPLOYMENT_TARGET": "14.0",
                "DEVELOPER_DIR": "/unused/dev",
                "SDKROOT": "/unused/sdk",
            }

            # 1) Test iOS build-framework.sh stops at stubbed cmake -S with manifest paths resolved.
            ios_cache = root / "lutools/build-ios-libraw/9.99.1/sources"
            ios_cache.mkdir(parents=True)
            shutil.copy2(libraw_tar, ios_cache / libraw_tar.name)
            shutil.copy2(cmake_tar, ios_cache / cmake_tar.name)
            # Pre-populate non-LibRaw archives so fetch() skips curl for them too.
            for other in (
                "opencv-4.12.0.tar.gz",
                "opencv_contrib-4.12.0.tar.gz",
                "wavelib-7f61bf5.tar.gz",
            ):
                (ios_cache / other).write_text("stub", encoding="utf-8")
            (tools / "shasum").write_text(
                f"#!{sys.executable}\n"
                "import sys\n"
                "line = sys.stdin.read().strip()\n"
                "digest, path = line.split(None, 1)\n"
                "if 'LibRaw' in path:\n"
                "    import hashlib\n"
                "    actual = hashlib.sha256(open(path, 'rb').read()).hexdigest()\n"
                "    sys.exit(0 if actual == digest else 1)\n"
                "sys.exit(0)\n",
                encoding="utf-8",
            )
            (tools / "shasum").chmod(0o755)
            # Extract directories for non-LibRaw stubs so tar isn't called on dummy text.
            for other_dir in (
                "opencv-4.12.0",
                "opencv_contrib-4.12.0",
                "wavelib-7f61bf592f3c470b2a7d8199431fde821d7253ac",
            ):
                (ios_cache / other_dir).mkdir(parents=True, exist_ok=True)

            ios_res = subprocess.run(
                ["bash", str(root / "lutools/platform/ios/build-framework.sh")],
                env=base_env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(ios_res.returncode, 42, ios_res.stdout + ios_res.stderr)
            calls = log.read_text(encoding="utf-8")
            self.assertIn(f"-DLIBRAW_SOURCE_DIR={ios_cache}/LibRaw-9.99.1", calls)
            self.assertIn(f"-DLIBRAW_PATH={ios_cache}/LibRaw-9.99.1", calls)
            self.assertIn(f"-DLIBRAW_CMAKE_SOURCE_DIR={ios_cache}/LibRaw-cmake-{'b' * 40}", calls)
            self.assertNotIn("UNEXPECTED CURL", calls)

            # 2) Test RawLabMac/build-dependencies.sh resolves manifest archive/dir/patch path.
            log.unlink()
            mac_cache = root / "mac-source-cache"
            mac_cache.mkdir()
            shutil.copy2(libraw_tar, mac_cache / libraw_tar.name)
            shutil.copy2(cmake_tar, mac_cache / cmake_tar.name)
            mac_sources = root / "build/macos-deps/14.0/arm64/sources"
            mac_sources.mkdir(parents=True)
            for other_archive, other_dir in (
                ("libjpeg-turbo-3.1.3.tar.gz", "libjpeg-turbo-3.1.3"),
                ("jasper-4.2.8.tar.gz", "jasper-version-4.2.8"),
                ("lcms2.17.tar.gz", "Little-CMS-lcms2.17"),
                ("openmp-21.1.8.src.tar.xz", "openmp-21.1.8.src"),
                ("cmake-21.1.8.src.tar.xz", "cmake-21.1.8.src"),
            ):
                (mac_cache / other_archive).write_text("stub", encoding="utf-8")
                (mac_sources / other_dir).mkdir(parents=True, exist_ok=True)
            mac_res = subprocess.run(
                ["bash", str(root / "RawLabMac/build-dependencies.sh")],
                env={**base_env, "RAWLAB_SOURCE_CACHE": str(mac_cache)},
                capture_output=True,
                text=True,
            )
            self.assertEqual(mac_res.returncode, 42, mac_res.stdout + mac_res.stderr)
            mac_calls = log.read_text(encoding="utf-8")
            self.assertIn(f"-DLIBRAW_SOURCE_DIR={mac_sources}/LibRaw-9.99.1", mac_calls)
            self.assertNotIn("UNEXPECTED CURL", mac_calls)

    def test_native_cache_resolves_ios_paths_from_manifest(self):
        cache = _load_native_cache_module()
        expected_version = self.manifest["libraw"]["version"]
        paths = cache.cache_paths("ios", "arm64-x86_64")
        self.assertTrue(any(f"lutools/build-ios-libraw/{expected_version}/" in p for p in paths))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest_path = root / "lutools/cmake/libraw/manifest.json"
            manifest_path.parent.mkdir(parents=True)
            mutated = json.loads(json.dumps(self.manifest))
            mutated["libraw"]["version"] = "9.99.1"
            manifest_path.write_text(json.dumps(mutated), encoding="utf-8")
            mutated_paths = cache.cache_paths("ios", "arm64-x86_64", root=root)
            self.assertEqual(mutated_paths[0], "lutools/build-ios-libraw/9.99.1/sources")


if __name__ == "__main__":
    unittest.main()
