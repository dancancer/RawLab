"""CI lint and behavioral contract tests for Apple test shell hygiene (#503, #543)."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAC_TESTS = ROOT / "RawLabMac/tests"
IOS_TESTS = ROOT / "RawLab/tests"
SHARED_TESTS = ROOT / "Shared/tests"
COMPILE_LIB = ROOT / "RawLabMac/tests/lib/compile.sh"
IOS_LIB = ROOT / "RawLab/tests/lib/ios-harness.sh"

# Exact policy rules exposed as pure functions so negative lint tests can verify
# revert-to-red behavior on synthetic snippets without mutating the repo.
HARDCODED_SDK_PATTERN = re.compile(r"MacOSX26\.5|/Library/Developer/CommandLineTools/SDKs/MacOSX")
HARDCODED_TARGET_PATTERN = re.compile(r"macosx(?:26\.0|15\.0|14\.0)\b")
BARE_SWIFTC_PATTERN = re.compile(r"(?:^|\s)(?:xcrun\s+(?:--sdk\s+\S+\s+)?)?swiftc\b", re.MULTILINE)
RAW_MKTEMP_PATTERN = re.compile(r"\bmktemp\b")
UNSAFE_RM_PATTERN = re.compile(r"trap\s+['\"][^'\"]*\brm\s+-r\s")
RG_FILES_PATTERN = re.compile(r"\brg\s+--files\b")


SHARED_SOURCE_DEFS = {"Shared/tests/mac-native-sources.sh", "Shared/tests/hdr-native-sources.sh"}


def lint_apple_test_script(rel_path: str, text: str) -> list[str]:
    errors = []
    if HARDCODED_SDK_PATTERN.search(text):
        errors.append(f"{rel_path}: hardcoded MacOSX26.5 or CLT SDK path outside scripts/ci/apple-sdk-env.sh")
    if HARDCODED_TARGET_PATTERN.search(text):
        errors.append(f"{rel_path}: hardcoded macOS deployment target (use rawlab_mac_target / helper)")
    if RG_FILES_PATTERN.search(text):
        errors.append(f"{rel_path}: uses rg --files (use POSIX find in helper)")
    if RAW_MKTEMP_PATTERN.search(text):
        errors.append(f"{rel_path}: raw mktemp outside helper library (use rawlab_*_make_temp_dir)")
    if UNSAFE_RM_PATTERN.search(text):
        errors.append(f"{rel_path}: trap uses rm -r without -f")

    if rel_path.startswith("RawLabMac/tests/") or rel_path.startswith("Shared/tests/"):
        if BARE_SWIFTC_PATTERN.search(text):
            errors.append(f"{rel_path}: bare swiftc invocation (use rawlab_mac_swiftc / rawlab_mac_compile_native)")
        if rel_path not in SHARED_SOURCE_DEFS and (
            "find \"$ROOT/RawLabMac/Sources\" -name '*.swift'" in text
            or '"$ROOT"/Shared/*.swift' in text
            or '"$ROOT"/Shared/Native/*.swift' in text
        ):
            errors.append(f"{rel_path}: duplicated RawLabMac/Shared source glob outside lib/compile.sh")
        if all(marker in text for marker in ("Engine.swift", "RenderError.swift", "AdjustmentsNative.swift")):
            errors.append(f"{rel_path}: duplicated render-engine source stack outside lib/compile.sh")
        if "clang++" in text and "RawLabMac/tests/lib/compile.sh" not in text:
            errors.append(f"{rel_path}: bare clang++ without compile.sh helper")
    elif rel_path.startswith("RawLab/tests/"):
        if BARE_SWIFTC_PATTERN.search(text):
            errors.append(f"{rel_path}: bare swiftc invocation (use rawlab_ios_sim_swiftc / rawlab_ios_host_swiftc)")
        if "clang++" in text and "RawMetadataBridge.mm" in text:
            errors.append(f"{rel_path}: duplicated RawMetadataBridge.mm clang++ compile outside lib/ios-harness.sh")
        if "Sony2FujiProcessor.swift" in text and "HDR_SWIFT_SOURCES" in text:
            errors.append(f"{rel_path}: duplicated processor-export source list outside lib/ios-harness.sh")
        if "CameraProtocol.swift" in text and "IOSCameraWorkspace.swift" in text:
            errors.append(f"{rel_path}: duplicated camera source list outside lib/ios-harness.sh")

    return errors


class AppleShellHygieneTests(unittest.TestCase):
    def test_all_apple_test_scripts_pass_hygiene_lint(self):
        violations = []
        for directory in (MAC_TESTS, IOS_TESTS, SHARED_TESTS):
            for script in sorted(directory.glob("*.sh")):
                rel = str(script.relative_to(ROOT))
                violations.extend(lint_apple_test_script(rel, script.read_text(encoding="utf-8")))
        self.assertEqual(violations, [], "\n".join(violations))

    def test_only_build_env_contains_clt_sdk_fallback_literal(self):
        hits = []
        for directory in (ROOT / "RawLabMac", ROOT / "RawLab", ROOT / "Shared", ROOT / "scripts/ci"):
            for script in sorted(directory.rglob("*.sh")):
                rel = str(script.relative_to(ROOT))
                if rel == "scripts/ci/apple-sdk-env.sh":
                    continue
                if HARDCODED_SDK_PATTERN.search(script.read_text(encoding="utf-8")):
                    hits.append(rel)
        self.assertEqual(hits, [], f"Unauthorized CLT/MacOSX26.5 SDK literals found in: {hits}")

    def test_helper_libraries_themselves_do_not_hardcode_sdk_or_targets(self):
        for lib in (COMPILE_LIB, IOS_LIB):
            text = lib.read_text(encoding="utf-8")
            rel = str(lib.relative_to(ROOT))
            self.assertFalse(HARDCODED_SDK_PATTERN.search(text), rel)
            self.assertFalse(HARDCODED_TARGET_PATTERN.search(text), rel)
            self.assertFalse(RG_FILES_PATTERN.search(text), rel)
        self.assertNotIn("RawLabMac/build-env.sh", IOS_LIB.read_text(encoding="utf-8"))

    def test_negative_lint_catches_all_forbidden_patterns(self):
        cases = (
            ("RawLabMac/tests/bad.sh", 'SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"\n'),
            ("RawLabMac/tests/bad.sh", 'swiftc -target arm64-apple-macosx26.0 foo.swift\n'),
            ("RawLabMac/tests/bad.sh", 'OUT="$(mktemp -d /tmp/rawlab-leak.XXXXXX)"\n'),
            ("RawLabMac/tests/bad.sh", 'trap \'rm -r "$OUT"\' EXIT\n'),
            ("RawLabMac/tests/bad.sh", 'Engine.swift RenderError.swift AdjustmentsNative.swift\n'),
            ("RawLab/tests/bad.sh", 'rg --files "$ROOT/RawLab/RawLab/Core"\n'),
            ("RawLab/tests/bad.sh", 'xcrun --sdk iphonesimulator swiftc foo.swift\n'),
            ("RawLab/tests/bad.sh", 'clang++ -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm"\n'),
            ("Shared/tests/bad.sh", '-target "$(uname -m)-apple-macosx15.0"\n'),
        )
        for rel, snippet in cases:
            with self.subTest(rel=rel, snippet=snippet.strip()):
                self.assertNotEqual(lint_apple_test_script(rel, snippet), [])

    def test_make_temp_dir_cleans_readonly_files_on_exit_0_and_1(self):
        for lib, fn, cleanup_fn in (
            (COMPILE_LIB, "rawlab_mac_make_temp_dir", "rawlab_mac_cleanup_temp_dirs"),
            (IOS_LIB, "rawlab_ios_make_temp_dir", "rawlab_ios_cleanup_temp_dirs"),
        ):
            for exit_code in (0, 1):
                with self.subTest(lib=lib.name, exit_code=exit_code):
                    res = subprocess.run(
                        [
                            "/bin/bash",
                            "-euo",
                            "pipefail",
                            "-c",
                            f'ROOT="{ROOT}"; source "{lib}"; '
                            f'{fn} DIR1 test-one; {fn} DIR2 test-two; '
                            'printf "x" > "$DIR1/readonly.txt"; chmod 444 "$DIR1/readonly.txt"; '
                            'printf "%s\\n%s\\n" "$DIR1" "$DIR2"; '
                            f'exit {exit_code}',
                        ],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(res.returncode, exit_code, res.stderr)
                    dirs = [Path(line) for line in res.stdout.splitlines() if line]
                    self.assertEqual(len(dirs), 2)
                    for d in dirs:
                        self.assertFalse(d.exists(), f"Temp directory leaked on exit {exit_code}: {d}")

            # Verify custom cleanup() trap composes with cleanup_fn.
            with self.subTest(lib=lib.name, custom_trap=True):
                with tempfile.TemporaryDirectory() as marker_parent:
                    marker = Path(marker_parent) / "custom-cleanup-ran"
                    res = subprocess.run(
                        [
                            "/bin/bash",
                            "-euo",
                            "pipefail",
                            "-c",
                            f'ROOT="{ROOT}"; source "{lib}"; '
                            f'{fn} DIR1 test-compose; '
                            f'cleanup() {{ touch "{marker}"; {cleanup_fn}; }}; '
                            'trap cleanup EXIT; '
                            'printf "%s\\n" "$DIR1"',
                        ],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(res.returncode, 0, res.stderr)
                    created = Path(res.stdout.strip())
                    self.assertTrue(marker.is_file(), "Custom cleanup trap did not run")
                    self.assertFalse(created.exists(), f"Temp directory leaked with custom trap: {created}")

    def test_sdk_and_target_helpers_default_and_override(self):
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory) / "bin"
            tools.mkdir()
            xcrun_log = Path(directory) / "xcrun.log"
            xcrun_tool = tools / "xcrun"
            xcrun_tool.write_text(
                f'#!/bin/bash\necho "$@" >> "{xcrun_log}"\nprintf "/fake/xcrun/MacOSX.sdk\\n"\n'
            )
            xcrun_tool.chmod(0o755)
            base_env = {
                k: v for k, v in os.environ.items()
                if k not in ("SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "RAWLAB_ARCH")
            }
            base_env["PATH"] = f"{tools}:{base_env['PATH']}"

            # Explicit SDKROOT short-circuits without invoking xcrun
            for helper_rel in ("scripts/ci/apple-sdk-env.sh", "RawLabMac/build-env.sh"):
                with self.subTest(helper=helper_rel, case="sdkroot"):
                    res_sdk = subprocess.run(
                        [
                            "/bin/bash",
                            "-euo",
                            "pipefail",
                            "-c",
                            f'ROOT="{ROOT}"; source "{ROOT}/{helper_rel}"; '
                            'printf "%s\\n%s\\n" "$(rawlab_mac_sdk_path)" "$(rawlab_mac_target)"',
                        ],
                        env={**base_env, "RAWLAB_ARCH": "arm64", "SDKROOT": "/explicit/override.sdk"},
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(res_sdk.returncode, 0, res_sdk.stderr)
                    self.assertEqual(res_sdk.stdout.splitlines(), ["/explicit/override.sdk", "arm64-apple-macosx14.0"])
                    self.assertFalse(xcrun_log.exists(), "rawlab_mac_sdk_path should short-circuit SDKROOT without xcrun")

            # MACOSX_DEPLOYMENT_TARGET override works
            res_override = subprocess.run(
                [
                    "/bin/bash",
                    "-euo",
                    "pipefail",
                    "-c",
                    f'ROOT="{ROOT}"; source "{ROOT}/scripts/ci/apple-sdk-env.sh"; rawlab_mac_target',
                ],
                env={**base_env, "RAWLAB_ARCH": "x86_64", "MACOSX_DEPLOYMENT_TARGET": "15.0"},
                capture_output=True,
                text=True,
            )
            self.assertEqual(res_override.returncode, 0, res_override.stderr)
            self.assertEqual(res_override.stdout.strip(), "x86_64-apple-macosx15.0")

            # Unset SDKROOT under Xcode xcrun must NOT force CLT MacOSX26.5.sdk
            xcode_xcrun = tools / "xcrun"
            xcode_xcrun.write_text(
                '#!/bin/bash\nprintf "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk\\n"\n'
            )
            xcode_xcrun.chmod(0o755)
            res_xcode = subprocess.run(
                [
                    "/bin/bash",
                    "-euo",
                    "pipefail",
                    "-c",
                    f'ROOT="{ROOT}"; source "{ROOT}/scripts/ci/apple-sdk-env.sh"; rawlab_mac_sdk_path',
                ],
                env=base_env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res_xcode.returncode, 0, res_xcode.stderr)
            self.assertEqual(
                res_xcode.stdout.strip(),
                "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk",
            )

    def test_mocked_compiler_verifies_migrated_mac_and_ios_host_scripts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "bin"
            tools.mkdir()
            (tools / "swiftc").write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nexit 73\n')
            (tools / "pkg-config").write_text("#!/bin/bash\nexit 0\n")
            (tools / "xcrun").write_text('#!/bin/bash\nprintf "/fake/MacOSX.sdk\\n"\n')
            (tools / "xcode-select").write_text('#!/bin/bash\nprintf "/fake/Developer\\n"\n')
            (tools / "swift").write_text(
                '#!/bin/bash\nset -euo pipefail\nscratch=""\nshow_bin=0\n'
                'while [ "$#" -gt 0 ]; do case "$1" in --scratch-path) scratch="$2"; shift 2 ;; --show-bin-path) show_bin=1; shift ;; *) shift ;; esac; done\n'
                'bin="$scratch/fake-bin"\nif [ "$show_bin" = 1 ]; then printf "%s\\n" "$bin"; exit 0; fi\n'
                'mkdir -p "$bin/Modules"\n'
                'touch "$bin/Modules/RawLabKit.swiftmodule" "$bin/libRawLabKit.a" '
                '"$bin/Modules/RawLabNativeTypes.swiftmodule" "$bin/libRawLabNativeTypes.a" '
                '"$bin/Modules/RawLabNative.swiftmodule" "$bin/libRawLabNative.a"\n'
            )
            for p in tools.iterdir():
                p.chmod(0o755)

            build_dir = root / "custom-build"
            base_env = {
                k: v for k, v in os.environ.items()
                if k not in ("RAWLAB_SWIFTPM_CACHE", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET")
            }
            base_env.update({
                "PATH": f"{tools}:{os.environ['PATH']}",
                "RAWLAB_ARCH": "arm64",
                "RAWLAB_BUILD_DIR": str(build_dir),
            })

            cases = (
                ("RawLabMac/tests/wavelet-render.sh", ["/unused/raw"], True),
                ("RawLabMac/tests/ai-denoise.sh", [], True),
                ("RawLabMac/tests/usage-privacy-presentation.sh", [], False),
                ("RawLab/tests/editor-coordinator.sh", [], False),
                ("RawLab/tests/adjustment-scale.sh", [], False),
            )
            for rel, extra_args, expects_build_dir in cases:
                with self.subTest(script=rel, target="14.0"):
                    res = subprocess.run(
                        ["bash", str(ROOT / rel), *extra_args],
                        env={**base_env, "SDKROOT": "/mock/MacOSX14.sdk"},
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(res.returncode, 73, res.stderr)
                    args = res.stdout.splitlines()
                    self.assertIn("/mock/MacOSX14.sdk", args)
                    self.assertIn("arm64-apple-macosx14.0", args)
                    if expects_build_dir:
                        self.assertIn(str(build_dir / "libsony2fuji_core.a"), args)

                with self.subTest(script=rel, target="15.0"):
                    res15 = subprocess.run(
                        ["bash", str(ROOT / rel), *extra_args],
                        env={**base_env, "SDKROOT": "/mock/MacOSX15.sdk", "MACOSX_DEPLOYMENT_TARGET": "15.0"},
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(res15.returncode, 73, res15.stderr)
                    args15 = res15.stdout.splitlines()
                    self.assertIn("/mock/MacOSX15.sdk", args15)
                    self.assertIn("arm64-apple-macosx15.0", args15)


if __name__ == "__main__":
    unittest.main()
