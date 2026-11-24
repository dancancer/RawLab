"""Native cache identity and product-output isolation regressions."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = Path(__file__).with_name("native_cache.py")


class NativeCacheTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if MODULE_PATH.exists():
            spec = importlib.util.spec_from_file_location("native_cache", MODULE_PATH)
            cls.cache = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.cache)
        else:
            cls.cache = None

    def setUp(self):
        self.assertIsNotNone(self.cache, "Native dependency cache helper is missing")

    def test_every_text_io_declares_utf8(self):
        """The Windows runner's default codec is not UTF-8, so text IO must not rely on it."""
        import ast

        tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
        offenders = []
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            name = getattr(node.func, "attr", getattr(node.func, "id", ""))
            if name not in {"read_text", "write_text", "open"}:
                continue
            if name == "open" and len(node.args) >= 2:
                mode = node.args[1]
                if isinstance(mode, ast.Constant) and "b" in str(mode.value):
                    continue
            if not any(keyword.arg == "encoding" for keyword in node.keywords):
                offenders.append(f"{MODULE_PATH.name}:{node.lineno}:{name}")
        self.assertEqual(offenders, [], "text IO without an explicit encoding: " + ", ".join(offenders))

    def test_workflow_with_non_ascii_comments_loads(self):
        """ci.yml carries Chinese comments, so the loader must not depend on the locale codec."""
        identity = self.cache.workflow_identity(ROOT, "windows", "x86_64")
        self.assertTrue(identity)

    def test_toolchain_architecture_and_workspace_change_identity(self):
        inputs = {"dependency.cmake": "abc123"}
        environment = {"compiler": "clang 18", "sdk": "26.0", "workspace": "/work/RawLab"}
        key = self.cache.cache_key("macos", "arm64", inputs, environment)
        self.assertEqual(key, self.cache.cache_key("macos", "arm64", inputs, dict(reversed(list(environment.items())))))
        for field, value in (("compiler", "clang 19"), ("sdk", "27.0"),
                             ("workspace", "/different/RawLab")):
            with self.subTest(field=field):
                self.assertNotEqual(key, self.cache.cache_key("macos", "arm64", inputs, {**environment, field: value}))
        self.assertNotEqual(key, self.cache.cache_key("macos", "x86_64", inputs, environment))
        self.assertNotEqual(key, self.cache.cache_key("ios", "arm64", inputs, environment))
        self.assertNotEqual(key, self.cache.cache_key("macos", "arm64", {"dependency.cmake": "changed"}, environment))

    def test_all_platforms_hash_patches_and_dependency_definitions(self):
        for platform in ("macos", "windows", "android", "ios"):
            with self.subTest(platform=platform):
                inputs = self.cache.dependency_inputs(ROOT, platform)
                for path in ("lutools/cmake/ThirdPartyDeps.cmake", "lutools/cmake/patch-libraw.cmake",
                             "lutools/cmake/libraw/CMakeLists.txt", "lutools/cmake/libraw/libraw.cmake",
                             "lutools/cmake/libraw/manifest.json", "lutools/cmake/libraw/manifest.py",
                             "lutools/cmake/dng-sdk/CMakeLists.txt", "lutools/cmake/lens-dependencies.json",
                             "lutools/third_party/rawspeed-camera-calibration.inc",
                             "lutools/third_party/nikon_he/codec.h",
                             "lutools/third_party/nikon_he/entropy.cpp",
                             "lutools/third_party/libraw/sony_arw6.cpp",
                             "lutools/cmake/libraw-vng.cmake", "lutools/third_party/libraw/vng_parallel.inc",
                             "scripts/ci/native_cache.py", "scripts/ci/requirements.txt",
                             ".github/workflows/ci.yml#" + platform):
                    self.assertIn(path, inputs)
                self.assertNotIn("lutools/CMakeLists.txt", inputs)
                self.assertNotIn("lutools/src/core/raw_processor.cpp", inputs)
                self.assertNotIn("RawLabMac/Sources/App.swift", inputs)

    def _copy_cache_inputs(self, dst_root):
        patterns = set(self.cache.COMMON_INPUTS) | {"lutools/CMakeLists.txt", ".github/workflows/ci.yml"}
        for p_list in self.cache.PLATFORM_INPUTS.values():
            patterns.update(p_list)
        for pattern in patterns:
            for src in ROOT.glob(pattern):
                if src.is_file():
                    dst = dst_root / src.relative_to(ROOT)
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)

    def test_first_party_cmakelists_edits_preserve_cache_key_across_all_platforms(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._copy_cache_inputs(root)
            env = {"compiler": "fixed", "sdk": "fixed"}
            before = {
                platform: self.cache.cache_key(platform, "x86_64", self.cache.dependency_inputs(root, platform, "arm64" if platform == "macos" else None), env)
                for platform in self.cache.PLATFORM_INPUTS
            }
            cmakelists = root / "lutools/CMakeLists.txt"
            cmakelists.write_text(
                cmakelists.read_text(encoding="utf-8")
                + "\n# simulated W-C first-party source and test\n"
                + "rawlab_add_test(NAME synthetic_first_party SOURCES tests/synthetic.cpp LIBRARIES sony2fuji_core)\n",
                encoding="utf-8",
            )
            for platform in self.cache.PLATFORM_INPUTS:
                after = self.cache.cache_key(platform, "x86_64", self.cache.dependency_inputs(root, platform, "arm64" if platform == "macos" else None), env)
                self.assertEqual(before[platform], after, f"First-party CMakeLists.txt edit busted {platform} cache key")

    def test_third_party_cmake_edits_invalidate_cache_key_across_all_platforms(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._copy_cache_inputs(root)
            env = {"compiler": "fixed", "sdk": "fixed"}
            for target_rel in ("lutools/cmake/ThirdPartyDeps.cmake", "lutools/cmake/dng-sdk.cmake"):
                with self.subTest(edited=target_rel):
                    before = {
                        platform: self.cache.cache_key(platform, "x86_64", self.cache.dependency_inputs(root, platform, "arm64" if platform == "macos" else None), env)
                        for platform in self.cache.PLATFORM_INPUTS
                    }
                    target = root / target_rel
                    target.write_text(target.read_text(encoding="utf-8") + "\n# simulated third-party change\n", encoding="utf-8")
                    for platform in self.cache.PLATFORM_INPUTS:
                        after = self.cache.cache_key(platform, "x86_64", self.cache.dependency_inputs(root, platform, "arm64" if platform == "macos" else None), env)
                        self.assertNotEqual(before[platform], after, f"Third-party edit to {target_rel} did not invalidate {platform}")

    def test_lutools_cmakelists_delegates_third_party_deps_to_cmake_dir(self):
        import re

        text = (ROOT / "lutools/CMakeLists.txt").read_text(encoding="utf-8")
        non_comment = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        self.assertIn("include(cmake/ThirdPartyDeps.cmake)", non_comment)
        forbidden_patterns = (
            r"\bFetchContent_",
            r"\bExternalProject_",
            r"\bpkg_check_modules\s*\(",
            r"\bfind_package\s*\(\s*(?:PkgConfig|ZLIB|OpenMP|OpenCV)\b",
            r"\bset\s*\(\s*CMAKE_(?:CXX|OBJCXX)_STANDARD\b",
            r"\boption\s*\(\s*SONY2FUJI_BUILD_(?:RAW|LENS|TIFF|DENOISE)_DEPS\b",
            r"\boption\s*\(\s*SONY2FUJI_ENABLE_(?:OPENMP|LENSFUN|DNGSDK|CHROMA_DENOISE|WAVELET_DENOISE)\b",
            r"\boption\s*\(\s*SONY2FUJI_TEST_PORTABLE_HDR\b",
            r"\binclude\s*\([^)]*(?:x3f|tiff-dependencies|libraw|lens-dependencies|denoise-dependencies|raw-png|hdr-codec|hdr-portable)\.cmake",
            r"\badd_subdirectory\s*\([^)]*cmake/libraw",
        )
        for pattern in forbidden_patterns:
            self.assertIsNone(
                re.search(pattern, non_comment),
                f"lutools/CMakeLists.txt must delegate third-party configuration ({pattern}) to lutools/cmake/ThirdPartyDeps.cmake",
            )

    def test_windows_batch_selection_edits_do_not_change_windows_native_cache_key(self):
        workflow = yaml.load((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / ".github/workflows/ci.yml"
            path.parent.mkdir(parents=True)
            path.write_text(yaml.safe_dump(workflow), encoding="utf-8")
            before = self.cache.workflow_identity(root, "windows", "x86_64")
            workflow["jobs"]["windows-batch-selection"]["steps"].append({"run": "echo mutated batch-selection"})
            path.write_text(yaml.safe_dump(workflow), encoding="utf-8")
            self.assertEqual(before, self.cache.workflow_identity(root, "windows", "x86_64"))

    def test_workflow_identity_is_platform_specific_and_keeps_shared_defaults(self):
        workflow = yaml.load((ROOT / '.github/workflows/ci.yml').read_text(), Loader=yaml.BaseLoader)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / '.github/workflows/ci.yml'
            path.parent.mkdir(parents=True)
            path.write_text(yaml.safe_dump(workflow))
            before = {platform: self.cache.workflow_identity(root, platform) for platform in self.cache.PLATFORM_INPUTS}
            path.write_text(yaml.safe_dump(workflow, sort_keys=False, indent=4))
            for platform in self.cache.PLATFORM_INPUTS:
                self.assertEqual(before[platform], self.cache.workflow_identity(root, platform))
            workflow['jobs']['windows']['env']['JOBS'] = '6'
            path.write_text(yaml.safe_dump(workflow))
            for platform in self.cache.PLATFORM_INPUTS:
                after = self.cache.workflow_identity(root, platform)
                self.assertEqual(before[platform] == after, platform != 'windows')
            workflow['env']['RAWLAB_RUM_LOCAL'] = '1'
            path.write_text(yaml.safe_dump(workflow))
            for platform in self.cache.PLATFORM_INPUTS:
                self.assertNotEqual(before[platform], self.cache.workflow_identity(root, platform))
            workflow['jobs'].pop('ios')
            path.write_text(yaml.safe_dump(workflow))
            with self.assertRaises(ValueError):
                self.cache.workflow_identity(root, 'ios')

    def test_macos_hashes_build_tools_not_unrelated_homebrew_packages(self):
        with mock.patch.object(self.cache, 'command', return_value='tool version') as command:
            self.cache.toolchain_identity('macos')
        command.assert_any_call('brew', 'list', '--versions', 'autoconf', 'automake',
                                'libtool', 'm4', 'pkgconf')
        self.assertNotIn(mock.call('brew', 'list', '--versions'), command.call_args_list)

    def test_mac_matrix_rows_have_separate_workflow_identities(self):
        workflow = yaml.load((ROOT / '.github/workflows/ci.yml').read_text(), Loader=yaml.BaseLoader)
        workflow['jobs']['macos']['strategy']['matrix']['include'] = self.cache.macos_matrix('full')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / '.github/workflows/ci.yml'
            path.parent.mkdir(parents=True)
            path.write_text(yaml.safe_dump(workflow))
            before = {arch: self.cache.workflow_identity(root, 'macos', arch) for arch in ('arm64', 'x86_64')}
            workflow['jobs']['macos']['strategy']['matrix']['include'][0]['jobs'] = '4'
            path.write_text(yaml.safe_dump(workflow))
            self.assertNotEqual(before['arm64'], self.cache.workflow_identity(root, 'macos', 'arm64'))
            self.assertEqual(before['x86_64'], self.cache.workflow_identity(root, 'macos', 'x86_64'))
            workflow['jobs']['macos']['steps'].append({'run': 'changed shared build command'})
            path.write_text(yaml.safe_dump(workflow))
            self.assertNotEqual(before['x86_64'], self.cache.workflow_identity(root, 'macos', 'x86_64'))
            with self.assertRaises(ValueError):
                self.cache.workflow_identity(root, 'macos', 'unsupported')

    def test_dynamic_mac_matrix_hashes_resolved_architecture_configuration(self):
        before = self.cache.workflow_identity(ROOT, 'macos', 'arm64')
        rows = self.cache.macos_matrix('full')
        rows[0]['jobs'] = '3'
        with mock.patch.object(self.cache, 'macos_matrix', return_value=rows):
            self.assertNotEqual(before, self.cache.workflow_identity(ROOT, 'macos', 'arm64'))

    def test_content_not_file_timestamp_controls_dependency_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "dependency.cmake"
            source.write_text("version 1")
            first = self.cache.hash_inputs(root, [source])
            source.touch()
            self.assertEqual(first, self.cache.hash_inputs(root, [source]))
            source.write_text("version 2")
            self.assertNotEqual(first, self.cache.hash_inputs(root, [source]))

    def test_allowlist_selects_dependencies_but_never_product_outputs(self):
        cases = {
            "macos": (
                ["build/macos-deps/14.0/arm64/install/lib/libraw.dylib",
                 "build/lensfun/14.0/arm64/install/lib/liblensfun.dylib"],
                ["lutools/build-macos/libsony2fuji_core.a", "build/RawLab Mac.app/Contents/MacOS/RawLabMac"]),
            "windows": (
                ["build/windows-native/_deps/rawlab_opencv-build/modules/core/opencv_core.dir/Release/a.obj",
                 "build/windows-native/cvconfig.h",
                 "build/windows-native/dng-sdk/Release/rawlab_dng_sdk.lib",
                 "build/windows-native/lens-dependencies/install/lib/lensfun.lib"],
                ["build/windows-native/core/Release/sony2fuji.dll", "build/windows-native/cli/Release/sony2fuji.exe",
                 "build/windows-native/lib/sony2fuji_core.lib",
                 "build/windows-native/core/CMakeFiles/sony2fuji_core.dir/a.obj"]),
            "ios": (
                [f"lutools/build-ios-libraw/{self.cache.libraw_version(ROOT)}/core-iphoneos-arm64/build/rawlab_dng_sdk.build/a.o",
                 f"lutools/build-ios-libraw/{self.cache.libraw_version(ROOT)}/core-iphoneos-arm64/cvconfig.h",
                 f"lutools/build-ios-libraw/{self.cache.libraw_version(ROOT)}/core-iphoneos-arm64/raw-dependencies/libraw/Release-iphoneos/libraw.a",
                 f"lutools/build-ios-libraw/{self.cache.libraw_version(ROOT)}/core-iphoneos-arm64/build/XCBuildData/build.db"],
                [f"lutools/build-ios-libraw/{self.cache.libraw_version(ROOT)}/core-iphoneos-arm64/build/sony2fuji.build/a.o",
                 f"lutools/build-ios-libraw/{self.cache.libraw_version(ROOT)}/core-iphoneos-arm64/lib/libsony2fuji_core.a",
                 f"lutools/build-ios-libraw/{self.cache.libraw_version(ROOT)}/core-iphoneos-arm64/build/sony2fuji_core.build/a.o",
                 f"lutools/build-ios-libraw/{self.cache.libraw_version(ROOT)}/core-iphoneos-arm64/output/sony2fuji.framework/sony2fuji",
                 "lutools/build-ios/sony2fuji.xcframework/sony2fuji"]),
            "android": (
                ["RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/_deps/rawlab_opencv-build/modules/core/a.o",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/opencv2/opencv_modules.hpp",
                 "RawLabAndroid/app/.cxx/Debug/hash/x86_64/dng-sdk/librawlab_dng_sdk.a",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/configure_fingerprint.bin",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/metadata_generation_command.txt",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/.ninja_deps",
                 "RawLabAndroid/app/.cxx/RelWithDebInfo/hash/arm64-v8a/_deps/rawlab_opencv-build/modules/core/a.o",
                 "RawLabAndroid/app/.cxx/RelWithDebInfo/hash/x86_64/dng-sdk/librawlab_dng_sdk.a",
                 "RawLabAndroid/app/.cxx/RelWithDebInfo/hash/arm64-v8a/configure_fingerprint.bin"],
                ["RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/core/CMakeFiles/sony2fuji_core.dir/a.o",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/lib/libsony2fuji_core.a",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/CMakeFiles/rawlab-jni.dir/a.o",
                 "RawLabAndroid/app/build/intermediates/cxx/Debug/hash/obj/arm64-v8a/librawlab-jni.so",
                 "RawLabAndroid/app/.cxx/RelWithDebInfo/hash/arm64-v8a/lib/libsony2fuji_core.a",
                 "RawLabAndroid/app/.cxx/RelWithDebInfo/hash/arm64-v8a/CMakeFiles/rawlab-jni.dir/a.o",
                 "RawLabAndroid/app/build/intermediates/cxx/RelWithDebInfo/hash/obj/arm64-v8a/librawlab-jni.so"]),
        }
        for platform, (included, excluded) in cases.items():
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for relative in included + excluded:
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.touch()
                selected = self.cache.selected_files(root, self.cache.cache_paths(platform, "arm64"))
                self.assertEqual({str(path.relative_to(root)) for path in selected}, set(included))


class DependencyArchiveKeyTests(unittest.TestCase):
    """归档缓存键只随下载归档 (URL, SHA256) pin 集合变化，与 toolchain 键解耦。"""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("native_cache_archives", MODULE_PATH)
        cls.cache = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.cache)

    def test_key_covers_every_configured_archive_pin(self):
        pairs = self.cache.dependency_archives(ROOT)
        # 4 个 cmake pin（dng/tiff/opencv/opencv_contrib）+ 5 个 hdr manifest pin；
        # 新增或漏抓都会改变数量，强制有意识地更新归档缓存合同。
        self.assertEqual(len(pairs), 9)
        urls = {url for url, _ in pairs}
        for fragment in ("dng_sdk_1_7_1_2724_20260908.zip", "tiff-4.7.1.tar.gz",
                         "opencv/opencv/archive/refs/tags/4.12.0.tar.gz",
                         "opencv/opencv_contrib/archive/refs/tags/4.12.0.tar.gz",
                         "libultrahdr", "libjpeg-turbo"):
            self.assertTrue(any(fragment in url for url in urls), f"archive pin not hashed: {fragment}")
        self.assertTrue(all(len(sha) == 64 and all(c in "0123456789abcdef" for c in sha) for _, sha in pairs))

    def test_key_is_stable_and_follows_the_pin_set(self):
        pairs = self.cache.dependency_archives(ROOT)
        key = self.cache.archives_key("windows", "x86_64", pairs)
        self.assertEqual(key, self.cache.archives_key("windows", "x86_64", self.cache.dependency_archives(ROOT)))
        self.assertNotEqual(key, self.cache.archives_key("windows", "x86_64", [(url + "x", sha) for url, sha in pairs]))
        self.assertNotEqual(key, self.cache.archives_key("windows", "x86_64", pairs[:-1]))


if __name__ == "__main__":
    unittest.main()
