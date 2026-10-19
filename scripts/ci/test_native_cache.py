"""Native cache identity and product-output isolation regressions."""
import importlib.util
from pathlib import Path
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
                for path in ("lutools/CMakeLists.txt", "lutools/cmake/patch-libraw.cmake",
                             "lutools/cmake/dng-sdk/CMakeLists.txt", "lutools/cmake/lens-dependencies.json",
                             "lutools/third_party/rawspeed-camera-calibration.inc",
                             "lutools/third_party/nikon_he/codec.h",
                             "lutools/third_party/nikon_he/entropy.cpp",
                             "scripts/ci/native_cache.py", "scripts/ci/requirements.txt",
                             ".github/workflows/ci.yml#" + platform):
                    self.assertIn(path, inputs)
                self.assertNotIn("lutools/src/core/raw_processor.cpp", inputs)
                self.assertNotIn("RawLabMac/Sources/App.swift", inputs)

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
                ["lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64/build/rawlab_dng_sdk.build/a.o",
                 "lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64/cvconfig.h",
                 "lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64/raw-dependencies/libraw/Release-iphoneos/libraw.a",
                 "lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64/build/XCBuildData/build.db"],
                ["lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64/build/sony2fuji.build/a.o",
                 "lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64/lib/libsony2fuji_core.a",
                 "lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64/build/sony2fuji_core.build/a.o",
                 "lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64/output/sony2fuji.framework/sony2fuji",
                 "lutools/build-ios/sony2fuji.xcframework/sony2fuji"]),
            "android": (
                ["RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/_deps/rawlab_opencv-build/modules/core/a.o",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/opencv2/opencv_modules.hpp",
                 "RawLabAndroid/app/.cxx/Debug/hash/x86_64/dng-sdk/librawlab_dng_sdk.a",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/configure_fingerprint.bin",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/metadata_generation_command.txt",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/.ninja_deps"],
                ["RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/core/CMakeFiles/sony2fuji_core.dir/a.o",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/lib/libsony2fuji_core.a",
                 "RawLabAndroid/app/.cxx/Debug/hash/arm64-v8a/CMakeFiles/rawlab-jni.dir/a.o",
                 "RawLabAndroid/app/build/intermediates/cxx/Debug/hash/obj/arm64-v8a/librawlab-jni.so"]),
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


if __name__ == "__main__":
    unittest.main()
