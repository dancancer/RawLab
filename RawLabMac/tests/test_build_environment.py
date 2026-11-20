"""Deployment targets must not reuse higher-minimum dependency binaries."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildEnvironmentTests(unittest.TestCase):
    @unittest.skipUnless(Path("/usr/libexec/PlistBuddy").exists(), "macOS plist tooling is required")
    def test_sparkle_link_check_consumes_large_tool_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "RawLab.app"
            framework = app / "Contents/Frameworks/Sparkle.framework"
            (framework / "Versions/B").mkdir(parents=True)
            (framework / "Versions/Current").symlink_to("B")
            for name in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
                         "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
                         "XPCServices/Installer.xpc/Contents/MacOS/Installer"):
                binary = framework / name
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.touch()
                binary.chmod(0o755)
            notices = app / "Contents/Resources/Licenses"
            notices.mkdir(parents=True)
            (notices / "Sparkle-LICENSE.txt").touch()
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(
                {"SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False}))
            tools = root / "tools"
            tools.mkdir()
            (tools / "codesign").write_text("#!/bin/sh\nexit 0\n")
            (tools / "otool").write_text(
                f"#!{sys.executable}\nimport os, sys\n"
                "print(os.environ['TEST_LINKED_FRAMEWORK'], flush=True)\n"
                "for _ in range(256):\n"
                "    sys.stdout.write('/System/Library/Frameworks/Other.framework/Other\\n' * 256)\n"
                "    sys.stdout.flush()\n")
            for tool in tools.iterdir():
                tool.chmod(0o755)
            for linked, expected in (("@rpath/Sparkle.framework/Versions/B/Sparkle", 0),
                                     ("/System/Library/Frameworks/Foundation.framework/Foundation", 1)):
                with self.subTest(linked=linked):
                    result = subprocess.run(["bash", str(ROOT / "RawLabMac/tests/sparkle-bundle.sh"), str(app)],
                        env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "RAWLAB_ARCH": "",
                             "TEST_LINKED_FRAMEWORK": linked}, capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    self.assertNotIn("BrokenPipeError", result.stdout + result.stderr)

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
                         "lutools/cmake/libraw/CMakeLists.txt", "lutools/cmake/libraw/libraw.cmake",
                         "lutools/cmake/libraw/manifest.json", "lutools/cmake/libraw/manifest.py",
                         "lutools/cmake/patch-libraw.cmake",
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
                         "lutools/cmake/libraw/manifest.json",
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

    def test_acceptance_scripts_link_the_requested_build_not_a_stale_default(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / "bin"
            binaries.mkdir()
            compiler = binaries / "swiftc"
            compiler.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nexit 73\n')
            package_config = binaries / "pkg-config"
            package_config.write_text("#!/bin/bash\nexit 0\n")
            xcrun_cli = binaries / "xcrun"
            xcrun_cli.write_text('#!/bin/bash\nif [[ "$*" == *"--show-sdk-path"* ]]; then\n  printf "/unused/sdk\\n"\nfi\n')
            xcode_select_cli = binaries / "xcode-select"
            xcode_select_cli.write_text('#!/bin/bash\nprintf "/unused/Developer\\n"\n')
            swift_cli = binaries / "swift"
            swift_cli.write_text(
                '#!/bin/bash\n'
                'set -euo pipefail\n'
                'scratch=""\n'
                'show_bin=0\n'
                'while [ "$#" -gt 0 ]; do\n'
                '  case "$1" in\n'
                '    --scratch-path) scratch="$2"; shift 2 ;;\n'
                '    --show-bin-path) show_bin=1; shift ;;\n'
                '    *) shift ;;\n'
                '  esac\n'
                'done\n'
                'test -n "$scratch"\n'
                'bin="$scratch/fake-bin"\n'
                'if [ "$show_bin" = 1 ]; then printf "%s\\n" "$bin"; exit 0; fi\n'
                'mkdir -p "$bin/Modules"\n'
                'touch "$bin/Modules/RawLabKit.swiftmodule" "$bin/libRawLabKit.a"\n'
            )
            for tool in (compiler, package_config, xcrun_cli, xcode_select_cli, swift_cli):
                tool.chmod(0o755)
            build = root / "release candidate"
            env = {key: value for key, value in os.environ.items()
                   if key not in ("RAWLAB_SWIFTPM_CACHE", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET")}
            env.update({"PATH": f"{binaries}:{os.environ['PATH']}",
                        "RAWLAB_ARCH": "arm64", "RAWLAB_BUILD_DIR": str(build)})
            for script in ("wavelet-render.sh", "agent-recipe-render.sh", "edit-model.sh"):
                with self.subTest(script=script):
                    result = subprocess.run(["bash", str(ROOT / "RawLabMac/tests" / script),
                                             "/unused/raw", "/unused/cli"], env=env,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 73, result.stderr)
                    args = result.stdout.splitlines()
                    self.assertIn(str(build / "libsony2fuji_core.a"), args)
                    self.assertNotIn(str(ROOT / "lutools/build-macos/libsony2fuji_core.a"), args)
                    self.assertTrue(any(arg.endswith("/fake-bin/libRawLabKit.a") for arg in args), args)
                    self.assertIn("arm64-apple-macosx14.0", args)

    def test_swiftpm_helper_supports_native_modules_and_rejects_noop_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / "bin"
            binaries.mkdir()
            swift_cli = binaries / "swift"
            swift_cli.write_text(
                '#!/bin/bash\n'
                'set -euo pipefail\n'
                'scratch=""\n'
                'show_bin=0\n'
                'while [ "$#" -gt 0 ]; do\n'
                '  case "$1" in\n'
                '    --scratch-path) scratch="$2"; shift 2 ;;\n'
                '    --show-bin-path) show_bin=1; shift ;;\n'
                '    *) shift ;;\n'
                '  esac\n'
                'done\n'
                'bin="$scratch/fake-bin"\n'
                'if [ "$show_bin" = 1 ]; then printf "%s\\n" "$bin"; exit 0; fi\n'
                'case "$TEST_LAYOUT" in\n'
                '  swiftbuild)\n'
                '    mkdir -p "$bin/RawLabKit.swiftmodule"\n'
                '    touch "$bin/libRawLabKit.a"\n'
                '    ;;\n'
                '  native)\n'
                '    mkdir -p "$bin/Modules"\n'
                '    touch "$bin/Modules/RawLabKit.swiftmodule" "$bin/libRawLabKit.a"\n'
                '    ;;\n'
                '  noop)\n'
                '    mkdir -p "$bin"\n'
                '    ;;\n'
                'esac\n'
            )
            swift_cli.chmod(0o755)
            helper = ROOT / "scripts/ci/swiftpm-rawlabkit.sh"
            for layout, mode, expected_code in (
                ("swiftbuild", "typecheck", 0),
                ("native", "typecheck", 0),
                ("native", "link", 0),
                ("noop", "typecheck", 1),
                ("noop", "link", 1),
            ):
                with self.subTest(layout=layout, mode=mode):
                    scratch = root / f"scratch-{layout}-{mode}"
                    cmd = (
                        f'ROOT="{ROOT}"; SDKROOT=/unused/sdk; '
                        f'source "{helper}"; '
                        f'rawlabkit_flags "{mode}" "{scratch}" macos 0; '
                        f'printf "%s\\n" "${{RAWLABKIT_SWIFTC_FLAGS[@]}}"'
                    )
                    test_env = {key: value for key, value in os.environ.items() if key != "RAWLAB_SWIFTPM_CACHE"}
                    test_env.update({"PATH": f"{binaries}:{os.environ['PATH']}",
                                     "TEST_LAYOUT": layout, "RAWLAB_ARCH": "arm64"})
                    result = subprocess.run(
                        ["bash", "-ec", cmd],
                        env=test_env,
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    if expected_code == 0:
                        lines = result.stdout.splitlines()
                        if layout == "native":
                            self.assertTrue(any(line.endswith("/fake-bin/Modules") for line in lines), lines)
                        if mode == "link":
                            self.assertTrue(any(line.endswith("/fake-bin/libRawLabKit.a") for line in lines), lines)

    def _make_sparkle_tools(self, tools_dir: Path, expected_sha: str) -> None:
        tools_dir.mkdir(parents=True, exist_ok=True)
        shasum_tool = tools_dir / "shasum"
        shasum_tool.write_text(
            f"#!/bin/bash\nprintf '%s  %s\\n' '{expected_sha}' \"${{@: -1}}\"\n"
        )
        ditto_tool = tools_dir / "ditto"
        ditto_tool.write_text(
            "#!/bin/bash\n"
            "dest=\"$4\"\n"
            "fw=\"$dest/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework\"\n"
            "mkdir -p \"$fw/Updater.app/Contents/MacOS\"\n"
            "touch \"$fw/Sparkle\" \"$fw/Autoupdate\" \"$fw/Updater.app/Contents/MacOS/Updater\"\n"
        )
        for tool in (shasum_tool, ditto_tool):
            tool.chmod(0o755)

    def test_prepare_sparkle_resolves_cache_without_git(self):
        expected_sha = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            tools = base / "tools"
            self._make_sparkle_tools(tools, expected_sha)

            # 1) Standalone .git-less tarball checkout, unset RAWLAB_SPARKLE_CACHE
            root = base / "tarball-checkout"
            (root / "RawLabMac").mkdir(parents=True)
            shutil.copy2(ROOT / "RawLabMac/prepare-sparkle.sh", root / "RawLabMac/prepare-sparkle.sh")
            default_archive = root / ".cache/shared/sparkle/2.10.0/Sparkle-for-Swift-Package-Manager.zip"
            default_archive.parent.mkdir(parents=True)
            default_archive.write_text("fake-zip")

            env = {key: value for key, value in os.environ.items() if key != "RAWLAB_SPARKLE_CACHE"}
            env["PATH"] = f"{tools}:{env['PATH']}"
            res = subprocess.run(
                ["bash", str(root / "RawLabMac/prepare-sparkle.sh")],
                cwd=root, env=env, capture_output=True, text=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(
                Path(res.stdout.strip()).resolve(),
                (root / ".cache/shared/sparkle/2.10.0/unpacked/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework").resolve(),
            )

            # 2) Custom RAWLAB_SPARKLE_CACHE without .git
            custom_cache = base / "custom-sparkle"
            custom_cache.mkdir()
            (custom_cache / "Sparkle-for-Swift-Package-Manager.zip").write_text("fake-zip")
            res_custom = subprocess.run(
                ["bash", str(root / "RawLabMac/prepare-sparkle.sh")],
                cwd=root, env={**env, "RAWLAB_SPARKLE_CACHE": str(custom_cache)},
                capture_output=True, text=True,
            )
            self.assertEqual(res_custom.returncode, 0, res_custom.stderr)
            self.assertEqual(
                Path(res_custom.stdout.strip()).resolve(),
                (custom_cache / "unpacked/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework").resolve(),
            )

            # 3) .git-less checkout nested inside an unrelated outer git repository
            if shutil.which("git"):
                outer = base / "outer-repo"
                outer.mkdir()
                subprocess.run(["git", "init", "-q"], cwd=outer, check=True)
                nested = outer / "unpacked-tarball"
                (nested / "RawLabMac").mkdir(parents=True)
                shutil.copy2(ROOT / "RawLabMac/prepare-sparkle.sh", nested / "RawLabMac/prepare-sparkle.sh")
                nested_archive = nested / ".cache/shared/sparkle/2.10.0/Sparkle-for-Swift-Package-Manager.zip"
                nested_archive.parent.mkdir(parents=True)
                nested_archive.write_text("fake-zip")
                res_nested = subprocess.run(
                    ["bash", str(nested / "RawLabMac/prepare-sparkle.sh")],
                    cwd=nested, env=env, capture_output=True, text=True,
                )
                self.assertEqual(res_nested.returncode, 0, res_nested.stderr)
                self.assertEqual(
                    Path(res_nested.stdout.strip()).resolve(),
                    (nested / ".cache/shared/sparkle/2.10.0/unpacked/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework").resolve(),
                )
                self.assertFalse((outer / ".cache").exists())

    @unittest.skipUnless(shutil.which("git"), "git is required")
    def test_prepare_sparkle_shares_cache_across_git_worktree(self):
        expected_sha = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            tools = base / "tools"
            self._make_sparkle_tools(tools, expected_sha)

            main_repo = base / "main-repo"
            (main_repo / "RawLabMac").mkdir(parents=True)
            shutil.copy2(ROOT / "RawLabMac/prepare-sparkle.sh", main_repo / "RawLabMac/prepare-sparkle.sh")
            subprocess.run(["git", "init", "-q"], cwd=main_repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=main_repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=main_repo, check=True)
            subprocess.run(["git", "add", "RawLabMac/prepare-sparkle.sh"], cwd=main_repo, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=main_repo, check=True)

            wt = base / "worktree"
            subprocess.run(["git", "worktree", "add", "-q", "-b", "wt-branch", str(wt)], cwd=main_repo, check=True)

            shared_archive = main_repo / ".cache/shared/sparkle/2.10.0/Sparkle-for-Swift-Package-Manager.zip"
            shared_archive.parent.mkdir(parents=True)
            shared_archive.write_text("fake-zip")

            env = {key: value for key, value in os.environ.items() if key != "RAWLAB_SPARKLE_CACHE"}
            env["PATH"] = f"{tools}:{env['PATH']}"
            res = subprocess.run(
                ["bash", str(wt / "RawLabMac/prepare-sparkle.sh")],
                cwd=wt, env=env, capture_output=True, text=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(
                Path(res.stdout.strip()).resolve(),
                (main_repo / ".cache/shared/sparkle/2.10.0/unpacked/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework").resolve(),
            )

    @unittest.skipUnless(Path("/usr/libexec/PlistBuddy").exists(), "macOS plist tooling is required")
    def test_non_release_build_cleans_stale_bundle_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "RawLabMac"
            scripts.mkdir(parents=True)
            for name in ("build.sh", "build-env.sh", "release-config.sh", "Info.plist"):
                shutil.copy2(ROOT / "RawLabMac" / name, scripts / name)
            (scripts / "Sources").mkdir()
            (scripts / "Sources/Main.swift").write_text("print(\"ok\")\n")
            (scripts / "Resources/Licenses").mkdir(parents=True)
            (scripts / "Resources/Licenses/local.txt").write_text("ok\n")
            (scripts / "Resources/ThirdPartyNotices.md").write_text("notices\n")
            (scripts / "Resources/en.lproj").mkdir(parents=True)
            (scripts / "Resources/en.lproj/Localizable.strings").write_text('"ok" = "ok";\n')
            (scripts / "Resources/MasterRecipeIcons").mkdir(parents=True)
            (scripts / "Resources/MasterRecipeIcons/icon.png").write_text("png")
            (scripts / "Resources/FilmIcons").mkdir(parents=True)
            (scripts / "Resources/FilmIcons/ektar.png").write_text("png")
            (scripts / "tests").mkdir()
            (scripts / "tests/bundle.sh").write_text("#!/bin/bash\nexit 0\n")

            sparkle_root = root / "sparkle-cache/unpacked/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
            (sparkle_root / "Versions/B").mkdir(parents=True)
            (sparkle_root.parent.parent.parent / "LICENSE").write_text("MIT\n")
            (scripts / "prepare-sparkle.sh").write_text(f"#!/bin/bash\nprintf '%s\\n' '{sparkle_root}'\n")
            (scripts / "build-lens-dependency.sh").write_text("#!/bin/bash\nexit 0\n")
            (scripts / "build-icon.sh").write_text('#!/bin/bash\ntouch "$1"\n')
            (scripts / "sign-bundle.sh").write_text("#!/bin/bash\nexit 0\n")

            libraw_dir = root / "lutools/cmake/libraw"
            libraw_dir.mkdir(parents=True)
            for name in ("manifest.json", "manifest.py"):
                shutil.copy2(ROOT / "lutools/cmake/libraw" / name, libraw_dir / name)
            for p in (
                "LICENSE",
                "LICENSE-ALIYUN-RUM-EXCEPTION",
                "docs/reference/licensing.md",
                "lutools/third_party/Adobe-DNG-SDK-LICENSE.txt",
                "lutools/third_party/nlohmann/LICENSE.MIT",
                "lutools/third_party/nikon_he/README.md",
                "lutools/third_party/nikon_he/LICENSE.LGPL-2.1",
                "lutools/third_party/lensfun/version_1/slr.xml",
                "lutools/third_party/lensfun/license.txt",
                "lutools/third_party/lensfun/license.md",
                "lutools/flog-2-new/test.cube",
                "Shared/master-recipes.json",
                "Shared/BundledLooks/catalog.json",
                "Shared/BundledLooks/NOTICE.md",
                "Shared/BundledLooks/look.cube",
                "Shared/BundledLooks/HDR/hdr.cube",
                "Shared/BundledLooks/Artwork/art.png",
            ):
                target = root / p
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture\n")
            (root / "scripts/assets").mkdir(parents=True)
            (root / "scripts/assets/prepare.py").write_text("import sys\n")

            build_dir = root / "lutools/build-macos"
            (build_dir / "licenses/libultrahdr").mkdir(parents=True)
            (build_dir / "licenses/libjpeg-turbo").mkdir(parents=True)
            (build_dir / "licenses/libspng").mkdir(parents=True)
            (build_dir / "CMakeCache.txt").write_text("SONY2FUJI_ENABLE_X3F:BOOL=OFF\n")
            (build_dir / "dng_jxl_tests").write_text("#!/bin/sh\nexit 0\n")
            (build_dir / "dng_jxl_tests").chmod(0o755)
            (build_dir / "hdr-codec/lib").mkdir(parents=True)
            (build_dir / "raw-jpeg/install/lib").mkdir(parents=True)

            opencv_prefix = root / "deps/opencv"
            (opencv_prefix / "share/licenses/opencv4").mkdir(parents=True)
            (opencv_prefix / "share/licenses/opencv4/LICENSE").write_text("ok")
            chroma_prefix = root / "build/macos-deps/14.0/arm64/install"
            (chroma_prefix / "share/licenses/wavelib").mkdir(parents=True)
            (chroma_prefix / "share/licenses/wavelib/COPYRIGHT").write_text("ok")
            (chroma_prefix / "share/licenses/libtiff").mkdir(parents=True)
            (chroma_prefix / "share/licenses/libtiff/LICENSE.md").write_text("ok")
            (chroma_prefix / "share/licenses/rawlab-dng-sdk").mkdir(parents=True)
            (chroma_prefix / "share/licenses/rawlab-dng-sdk/LICENSE.txt").write_text("ok")
            lens_prefix = root / "build/lensfun/14.0/arm64/install"
            (lens_prefix / "licenses/lensfun").mkdir(parents=True)
            (lens_prefix / "licenses/lensfun/COPYING").write_text("ok")

            tools = root / "tools"
            tools.mkdir()
            tool_scripts = {
                "pkg-config": f"#!/bin/bash\nif [[ \"${{1:-}}\" == --variable=prefix ]]; then echo '{opencv_prefix}'; fi\nexit 0\n",
                "cmake": "#!/bin/sh\nexit 0\n",
                "swift": (
                    "#!/bin/bash\n"
                    "scratch=''\nshow_bin=0\n"
                    "while [ $# -gt 0 ]; do\n"
                    "  case \"$1\" in --scratch-path) scratch=\"$2\"; shift 2 ;; --show-bin-path) show_bin=1; shift ;; *) shift ;; esac\n"
                    "done\n"
                    "bin=\"$scratch/bin\"\n"
                    "if [ \"$show_bin\" = 1 ]; then echo \"$bin\"; exit 0; fi\n"
                    "mkdir -p \"$bin/Modules\"\n"
                    "touch \"$bin/Modules/RawLabKit.swiftmodule\" \"$bin/libRawLabKit.a\"\n"
                ),
                "swiftc": "#!/bin/bash\nout=''\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) out=\"$2\"; shift 2 ;; *) shift ;; esac; done\nmkdir -p \"$(dirname \"$out\")\"\ntouch \"$out\"\nchmod +x \"$out\"\n",
                "sips": "#!/bin/bash\nout=''\nwhile [ $# -gt 0 ]; do case \"$1\" in --out) out=\"$2\"; shift 2 ;; *) shift ;; esac; done\ntouch \"$out\"\n",
                "otool": "#!/bin/sh\nexit 0\n",
                "codesign": "#!/bin/sh\nexit 0\n",
            }
            for name, content in tool_scripts.items():
                p = tools / name
                p.write_text(content)
                p.chmod(0o755)

            app = root / "build/RawLab Mac.app"
            stale_paths = [
                app / "Contents/Resources/LUTs/stale.cube",
                app / "Contents/Resources/FilmIcons/stale.png",
                app / "Contents/Resources/FilmIcons/Thumbnails/stale@2x.png",
                app / "Contents/Resources/MasterRecipes/stale.cube",
                app / "Contents/Resources/Licenses/stale.txt",
                app / "Contents/Frameworks/Stale.framework/Stale",
            ]
            for sp in stale_paths:
                sp.parent.mkdir(parents=True, exist_ok=True)
                sp.write_text("stale")

            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("RAWLAB_") and key != "MACOSX_DEPLOYMENT_TARGET"}
            env.update({
                "PATH": f"{tools}:{os.environ['PATH']}",
                "RAWLAB_ARCH": "arm64",
                "RAWLAB_CI_CACHE_HIT": "true",
                "RAWLAB_RUM": "0",
                "RAWLAB_RUM_LOCAL": "0",
                "SDKROOT": "/unused/sdk",
            })
            res = subprocess.run(["bash", str(scripts / "build.sh")], cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            for sp in stale_paths:
                self.assertFalse(sp.exists(), f"Stale artifact survived non-release build: {sp}")
            self.assertTrue((app / "Contents/MacOS/RawLabMac").is_file())
            self.assertTrue((app / "Contents/Resources/bundled-looks.json").is_file())
            self.assertTrue((app / "Contents/Frameworks/Sparkle.framework").is_dir())

            # Release build must still refuse pre-existing release output
            release_app = root / "release-existing.app"
            release_app.mkdir(parents=True)
            res_rel = subprocess.run(
                ["bash", str(scripts / "build.sh")], cwd=root,
                env={**env, "RAWLAB_RELEASE": "1", "RAWLAB_APP_PATH": str(release_app)},
                capture_output=True, text=True,
            )
            self.assertEqual(res_rel.returncode, 2, res_rel.stdout + res_rel.stderr)


if __name__ == "__main__":
    unittest.main()
