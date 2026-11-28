"""Unit tests and CI policy checks for ctest --show-only=json-v1 inventory reconciliation."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_ctest_inventory as cci


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"


def _make_entry(
    name: str,
    labels: list[str],
    executable: str | None = None,
    environment: list[str] | None = None,
) -> dict:
    entry: dict = {
        "name": name,
        "properties": [{"name": "LABELS", "value": labels}],
    }
    if environment is not None:
        entry["properties"].append({"name": "ENVIRONMENT", "value": environment})
    if executable:
        entry["command"] = [f"/tmp/build/{executable}"]
    return entry


class CTestInventoryTests(unittest.TestCase):
    def test_valid_inventory_passes_for_macos_and_windows_ci_labels(self) -> None:
        mac_data = {
            "tests": [
                _make_entry("tiff_ifd", ["core", "ci_macos_arm64", "ci_macos_x86_64", "ci_windows"], "tiff_ifd_tests"),
                _make_entry("metal_workspace", ["gpu", "metal", "metal_arm64", "ci_macos_arm64"], "metal_workspace_tests"),
                _make_entry("x3f_decoder_contracts", ["x3f", "contracts", "arm64_only", "ci_macos_arm64"]),
                _make_entry("gpu_photo", ["gpu", "hw_gpu"], "gpu_photo_tests"),
                _make_entry("raw_input", ["raw", "external_raw", "ci_macos_arm64", "ci_macos_x86_64"], "raw_smoke"),
                _make_entry("gles_shader", ["gpu", "gles_shader", "ci_macos_arm64", "ci_macos_x86_64"]),
            ]
        }
        win_data = {
            "tests": [
                _make_entry("tiff_ifd", ["core", "ci_macos_arm64", "ci_macos_x86_64", "ci_windows"], "tiff_ifd_tests"),
                _make_entry("windows_display_image", ["windows", "ci_windows"], "windows_display_image_tests"),
                _make_entry("hdr_display_shader_warp", ["windows", "hdr", "d3d11", "ci_windows"], "hdr_display_tests"),
                _make_entry("gpu_photo", ["gpu", "hw_gpu"], "gpu_photo_tests"),
                _make_entry("raw_input", ["raw", "external_raw", "ci_macos_arm64", "ci_macos_x86_64"], "raw_smoke"),
                _make_entry("gles_shader", ["gpu", "gles_shader", "ci_macos_arm64", "ci_macos_x86_64"]),
                _make_entry("dualdn_directml", ["ai", "directml", "ci_windows"], "dualdn_directml_tests"),
            ]
        }
        self.assertEqual(cci.validate_ctest_inventory(mac_data, ci_label="ci_macos_arm64"), [])
        self.assertEqual(cci.validate_ctest_inventory(mac_data, ci_label="ci_macos_x86_64"), [])
        self.assertEqual(cci.validate_ctest_inventory(win_data, ci_label="ci_windows"), [])

    def test_unlabeled_test_is_rejected(self) -> None:
        data = {"tests": [_make_entry("unlabeled", [])]}
        errors = cci.validate_ctest_inventory(data, ci_label="ci_windows")
        self.assertTrue(any("Unlabeled CTest: unlabeled" in e for e in errors), errors)

    def test_unexcluded_test_missing_ci_label_is_rejected(self) -> None:
        data = {"tests": [_make_entry("new_core_test", ["core", "ci_macos_arm64", "ci_macos_x86_64"])]}
        errors = cci.validate_ctest_inventory(data, ci_label="ci_windows")
        self.assertTrue(any("missing ci_windows" in e for e in errors), errors)

    def test_forbidden_label_alongside_ci_label_is_rejected(self) -> None:
        data = {
            "tests": [
                _make_entry("bad_win_gpu", ["gpu", "hw_gpu", "ci_windows"]),
                _make_entry("bad_x86_metal", ["gpu", "metal_arm64", "ci_macos_x86_64"]),
            ]
        }
        win_errors = cci.validate_ctest_inventory(data, ci_label="ci_windows")
        x86_errors = cci.validate_ctest_inventory(data, ci_label="ci_macos_x86_64")
        self.assertTrue(any("bad_win_gpu" in e and "forbidden" in e for e in win_errors), win_errors)
        self.assertTrue(any("bad_x86_metal" in e and "forbidden" in e for e in x86_errors), x86_errors)

    def test_orphan_test_source_file_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tdir = Path(tmp)
            (tdir / "registered_tests.cpp").write_text("int main() { return 0; }\n", encoding="utf-8")
            (tdir / "orphan_tests.cpp").write_text("int main() { return 0; }\n", encoding="utf-8")
            data = {
                "tests": [
                    _make_entry("registered", ["core", "ci_windows"], "registered_tests"),
                ]
            }
            errors = cci.validate_ctest_inventory(data, ci_label="ci_windows", tests_dir=tdir)
            self.assertEqual(len(errors), 1)
            self.assertIn("orphan_tests.cpp", errors[0])

    def test_ci_workflow_uses_label_selection_and_ctest_json_inventory(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        workflow = yaml.load(text, Loader=yaml.BaseLoader)

        mac_run = re.sub(
            r"\\\r?\n\s*",
            " ",
            "\n".join(s.get("run", "") for s in workflow["jobs"]["macos"]["steps"]),
        )
        win_run = "\n".join(s.get("run", "") for s in workflow["jobs"]["windows"]["steps"])

        self.assertRegex(mac_run, r"ctest\b[^\n]*-L\s+['\"]?\^ci_macos_\$\{RAWLAB_ARCH\}\$['\"]?")
        self.assertNotIn("ctest_exclude=", mac_run)
        self.assertIn("check_ctest_inventory.py", mac_run)

        self.assertRegex(win_run, r"ctest\b[^\n]*'-L',\s*'\^ci_windows\$'")
        self.assertNotRegex(win_run, r"(?m)^\s*\$tests\s*=")
        self.assertIn("check_ctest_inventory.py", win_run)

    def test_resolve_ctest_config_for_multi_config_and_single_config_caches(self) -> None:
        multi_cache = {
            "CMAKE_GENERATOR": "Visual Studio 17 2022",
            "CMAKE_CONFIGURATION_TYPES": "Debug;Release;MinSizeRel;RelWithDebInfo",
        }
        self.assertEqual(cci.resolve_ctest_config(multi_cache), "Release")
        self.assertEqual(cci.resolve_ctest_config(multi_cache, "Debug"), "Debug")
        # Subprojects like libultrahdr force CMAKE_BUILD_TYPE=Release into CMakeCache.txt even on VS.
        polluted_multi_cache = {
            **multi_cache,
            "CMAKE_BUILD_TYPE": "Release",
        }
        self.assertEqual(cci.resolve_ctest_config(polluted_multi_cache), "Release")
        self.assertEqual(
            cci.resolve_ctest_config({"CMAKE_CONFIGURATION_TYPES": "Debug;RelWithDebInfo"}),
            "Debug",
        )
        single_cache = {
            "CMAKE_GENERATOR": "Ninja",
            "CMAKE_BUILD_TYPE": "Release",
        }
        self.assertIsNone(cci.resolve_ctest_config(single_cache))
        self.assertEqual(cci.resolve_ctest_config(single_cache, "RelWithDebInfo"), "RelWithDebInfo")

    def test_load_ctest_json_selects_release_for_multi_config_cmake_cache(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            build_dir = Path(tmp)
            (build_dir / "CMakeCache.txt").write_text(
                "CMAKE_GENERATOR:INTERNAL=Visual Studio 17 2022\n"
                "CMAKE_CONFIGURATION_TYPES:STRING=Debug;Release;MinSizeRel;RelWithDebInfo\n"
                "CMAKE_BUILD_TYPE:STRING=Release\n",
                encoding="utf-8",
            )
            payload = json.dumps({"tests": [_make_entry("tiff_ifd", ["core", "ci_windows"], "tiff_ifd_tests")]})
            with mock.patch("check_ctest_inventory.subprocess.check_output", return_value=payload) as mocked:
                loaded = cci.load_ctest_json(build_dir)
            self.assertEqual(len(loaded["tests"]), 1)
            mocked.assert_called_once_with(
                ["ctest", "--test-dir", str(build_dir), "-C", "Release", "--show-only=json-v1"],
                text=True,
                encoding="utf-8",
            )

            (build_dir / "CMakeCache.txt").write_text(
                "CMAKE_BUILD_TYPE:STRING=Release\n",
                encoding="utf-8",
            )
            with mock.patch("check_ctest_inventory.subprocess.check_output", return_value=payload) as mocked_single:
                cci.load_ctest_json(build_dir)
            mocked_single.assert_called_once_with(
                ["ctest", "--test-dir", str(build_dir), "--show-only=json-v1"],
                text=True,
                encoding="utf-8",
            )

    def test_glslang_gated_sources_require_glslang_only_when_available(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tdir = Path(tmp)
            (tdir / "tiff_ifd_tests.cpp").write_text("int main() { return 0; }\n", encoding="utf-8")
            (tdir / "gles_photo_pixel_tests.cpp").write_text("int main() { return 0; }\n", encoding="utf-8")
            (tdir / "gles_renderer_retry_tests.cpp").write_text("int main() { return 0; }\n", encoding="utf-8")
            data = {
                "tests": [
                    _make_entry("tiff_ifd", ["core", "ci_macos_arm64", "ci_windows"], "tiff_ifd_tests"),
                ]
            }
            self.assertEqual(
                cci.validate_ctest_inventory(
                    data,
                    ci_label="ci_windows",
                    platform="windows",
                    tests_dir=tdir,
                    glslang_available=False,
                ),
                [],
            )
            errors = cci.validate_ctest_inventory(
                data,
                ci_label="ci_macos_arm64",
                platform="macos",
                tests_dir=tdir,
                glslang_available=True,
            )
            self.assertEqual(len(errors), 2)
            self.assertTrue(any("gles_photo_pixel_tests.cpp" in e for e in errors), errors)
            self.assertTrue(any("gles_renderer_retry_tests.cpp" in e for e in errors), errors)

    def test_ai_package_and_model_gated_sources_match_cmake_gates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tdir = Path(tmp)
            for name in (
                "tiff_ifd_tests.cpp",
                "ai_session_memory_tests.cpp",
                "dualdn_session_tests.cpp",
                "dualdn_native_tests.cpp",
                "dualdn_api_tests.cpp",
                "dualdn_onnx_tests.cpp",
            ):
                (tdir / name).write_text("int main() { return 0; }\n", encoding="utf-8")
            data = {
                "tests": [
                    _make_entry("tiff_ifd", ["core", "ci_macos_arm64"], "tiff_ifd_tests"),
                    _make_entry("ai_session_memory", ["ai", "hw_gpu"], "ai_session_memory_tests"),
                    _make_entry("dualdn_session", ["ai", "ci_macos_arm64"], "dualdn_session_tests"),
                    _make_entry("dualdn_native", ["ai", "hw_gpu"], "dualdn_native_tests"),
                    _make_entry("dualdn_api", ["ai", "hw_gpu"], "dualdn_api_tests"),
                ]
            }
            self.assertEqual(
                cci.validate_ctest_inventory(
                    data,
                    ci_label="ci_macos_arm64",
                    platform="macos",
                    tests_dir=tdir,
                    ai_enabled=True,
                    ai_package_present=True,
                    ai_model_present=False,
                    glslang_available=False,
                ),
                [],
            )
            errors = cci.validate_ctest_inventory(
                data,
                ci_label="ci_macos_arm64",
                platform="macos",
                tests_dir=tdir,
                ai_enabled=True,
                ai_package_present=True,
                ai_model_present=True,
                glslang_available=False,
            )
            self.assertEqual(len(errors), 1)
            self.assertIn("dualdn_onnx_tests.cpp", errors[0])

    def test_optional_live_build_dir_reconciliation(self) -> None:
        build_dir = os.environ.get("RAWLAB_CTEST_BUILD_DIR")
        if not build_dir:
            self.skipTest("RAWLAB_CTEST_BUILD_DIR not set")
        data = cci.load_ctest_json(Path(build_dir))
        for label in ("ci_macos_arm64", "ci_macos_x86_64"):
            with self.subTest(label=label):
                self.assertEqual(
                    cci.validate_ctest_inventory(
                        data,
                        ci_label=label,
                        platform="macos",
                        tests_dir=cci.LUTOOLS_TESTS_DIR,
                    ),
                    [],
                )

    def test_inventory_rejects_semicolon_packed_environment_entries(self) -> None:
        packed = _make_entry(
            "abi_layout_fixture",
            ["contracts", "abi", "ci_macos_arm64"],
            environment=["CXX=/usr/bin/clang++;RAWLAB_REQUIRE_ABI_CHECK=1"],
        )
        errors = cci.validate_ctest_inventory({"tests": [packed]}, ci_label="ci_macos_arm64")
        self.assertEqual(len(errors), 1)
        self.assertIn("semicolon-packed ENVIRONMENT", errors[0])

        split = _make_entry(
            "abi_layout_fixture",
            ["contracts", "abi", "ci_macos_arm64"],
            environment=["CXX=/usr/bin/clang++", "RAWLAB_REQUIRE_ABI_CHECK=1", "LIST_VAL=alpha;beta"],
        )
        self.assertEqual(cci.validate_ctest_inventory({"tests": [split]}, ci_label="ci_macos_arm64"), [])

    @unittest.skipUnless(shutil.which("cmake") and shutil.which("ctest"), "cmake and ctest are required")
    def test_rawlab_add_test_environment_guard_and_lutools_invocations(self) -> None:
        rawlab_add_test_cmake = (ROOT / "lutools/cmake/rawlab_add_test.cmake").as_posix()
        wrapper_snippet = """
if(NOT COMMAND _rawlab_add_test)
    function(rawlab_add_test)
        set(_rawlab_fwd "")
        if(ARGC GREATER 0)
            math(EXPR _rawlab_last_arg "${ARGC} - 1")
            foreach(_rawlab_idx RANGE 0 ${_rawlab_last_arg})
                string(APPEND _rawlab_fwd " \\"\\${ARGV${_rawlab_idx}}\\"")
            endforeach()
        endif()
        cmake_language(EVAL CODE "_rawlab_add_test(${_rawlab_fwd})")
    endfunction()
endif()
"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)

            # 1. Packed ENVIRONMENT must fail CMake configure closed.
            bad_src = root / "bad"
            bad_src.mkdir()
            (bad_src / "CMakeLists.txt").write_text(
                f'cmake_minimum_required(VERSION 3.15)\nproject(BadEnv NONE)\ninclude(CTest)\n'
                f'include("{rawlab_add_test_cmake}")\n{wrapper_snippet}\n'
                'rawlab_add_test(NAME packed_env COMMAND /usr/bin/true ENVIRONMENT "RAWLAB_A=1;RAWLAB_B=2" LABELS core)\n',
                encoding="utf-8",
            )
            bad_res = subprocess.run(
                ["cmake", "-S", str(bad_src), "-B", str(bad_src / "build")],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(bad_res.returncode, 0)
            self.assertIn("pass each ENVIRONMENT entry as a separate argument", " ".join(bad_res.stderr.split()))

            # 2. Split ENVIRONMENT works end-to-end AND every ENVIRONMENT call in lutools/CMakeLists.txt is valid.
            good_src = root / "good"
            good_src.mkdir()
            (good_src / "edit_pixel_golden_tests.cpp").write_text("int main() { return 0; }\n", encoding="utf-8")
            (good_src / "metal_workspace_tests.mm").write_text("int main() { return 0; }\n", encoding="utf-8")
            (good_src / "vng_parallel_tests.cpp").write_text("int main() { return 0; }\n", encoding="utf-8")
            (good_src / "gpu_photo_tests.cpp").write_text("int main() { return 0; }\n", encoding="utf-8")
            (good_src / "raw_probe.py").write_text(
                'import os, sys\nassert os.environ["RAWLAB_A"] == "1" and os.environ["RAWLAB_B"] == "2"\n',
                encoding="utf-8",
            )

            cmakelists_text = (ROOT / "lutools/CMakeLists.txt").read_text(encoding="utf-8")
            env_calls: list[str] = []
            for match in re.finditer(r"rawlab_add_test\(", cmakelists_text):
                start = match.start()
                depth = 0
                in_quote = False
                i = match.end() - 1
                while i < len(cmakelists_text):
                    ch = cmakelists_text[i]
                    if ch == '"' and cmakelists_text[i - 1] != "\\":
                        in_quote = not in_quote
                    elif not in_quote:
                        if ch == "#":
                            nl = cmakelists_text.find("\n", i)
                            i = len(cmakelists_text) if nl == -1 else nl
                            continue
                        if ch == "(":
                            depth += 1
                        elif ch == ")":
                            depth -= 1
                            if depth == 0:
                                block = cmakelists_text[start : i + 1]
                                if re.search(r"\bENVIRONMENT\b", block):
                                    # Rewrite only target/COMMAND dependencies so every real ENVIRONMENT arg list executes here.
                                    rewritten = block
                                    rewritten = re.sub(r"\bSOURCES\s+\S+", "", rewritten)
                                    rewritten = re.sub(r"\bLIBRARIES\s+[^\n]+", "", rewritten)
                                    if not re.search(r"\bCOMMAND\b", rewritten):
                                        rewritten = re.sub(
                                            r"(NAME\s+\S+)",
                                            r'\1 COMMAND "${CMAKE_COMMAND}" -E true',
                                            rewritten,
                                            count=1,
                                        )
                                    else:
                                        rewritten = re.sub(
                                            r"\bCOMMAND\b[\s\S]*?(?=\n\s*(?:ARGS|ENVIRONMENT|LABELS|SKIP_RETURN_CODE)\b)",
                                            'COMMAND "${CMAKE_COMMAND}" -E true',
                                            rewritten,
                                        )
                                    rewritten = re.sub(
                                        r"\bARGS\b[\s\S]*?(?=\n\s*(?:ENVIRONMENT|LABELS|SKIP_RETURN_CODE)\b)",
                                        "",
                                        rewritten,
                                    )
                                    env_calls.append(rewritten)
                                break
                    i += 1

            self.assertGreaterEqual(len(env_calls), 6)
            joined_calls = "\n".join(env_calls)
            (good_src / "CMakeLists.txt").write_text(
                'cmake_minimum_required(VERSION 3.15)\nproject(GoodEnv NONE)\ninclude(CTest)\n'
                f'include("{rawlab_add_test_cmake}")\n{wrapper_snippet}\n'
                'set(RAWLAB_ABI_CLANGXX "/usr/bin/clang++")\n'
                'set(RAWLAB_SHADER_PYTHON "python3")\n'
                f'rawlab_add_test(\n    NAME env_child_check\n    COMMAND "{sys.executable}" "{good_src / "raw_probe.py"}"\n'
                '    ENVIRONMENT "RAWLAB_A=1" "RAWLAB_B=2"\n    LABELS core\n)\n'
                + joined_calls
                + "\n",
                encoding="utf-8",
            )
            good_build = good_src / "build"
            subprocess.run(["cmake", "-S", str(good_src), "-B", str(good_build)], check=True, capture_output=True, text=True)
            subprocess.run(["ctest", "--test-dir", str(good_build), "-R", "^env_child_check$", "--output-on-failure"], check=True, capture_output=True, text=True)
            ct_json = cci.load_ctest_json(good_build)
            self.assertEqual(cci.validate_ctest_inventory(ct_json), [])
            by_name = {entry["name"]: cci.test_environment(entry) for entry in ct_json["tests"]}
            self.assertEqual(by_name["abi_layout_fixture"], ["CXX=/usr/bin/clang++", "RAWLAB_REQUIRE_ABI_CHECK=1"])
            self.assertEqual(
                by_name["metal_workspace"],
                [
                    "MTL_SHADER_VALIDATION=1",
                    "MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1",
                    "MTL_SHADER_VALIDATION_ABORT_ON_FAULT=1",
                ],
            )
            self.assertEqual(by_name["metal_edit_pixel_golden"], by_name["metal_workspace"])

    def test_macos_coreml_hw_tests_are_excluded_from_hosted_macos_and_visible(self) -> None:
        hw_entries = [
            _make_entry("tiff_ifd", ["core", "ci_macos_arm64", "ci_macos_x86_64", "ci_windows"], "tiff_ifd_tests"),
            _make_entry("dualdn_session", ["ai", "ci_macos_arm64", "ci_macos_x86_64", "ci_windows"], "dualdn_session_tests"),
            _make_entry("coreml_gpu_placement", ["ai", "gpu", "ci_macos_arm64", "ci_macos_x86_64"], "coreml_gpu_placement_tests"),
            _make_entry("ai_session_memory", ["ai", "hw_gpu"], "ai_session_memory_tests"),
            _make_entry("dualdn_native", ["ai", "hw_gpu"], "dualdn_native_tests"),
            _make_entry("dualdn_api", ["ai", "hw_gpu"], "dualdn_api_tests"),
        ]
        self.assertEqual(
            cci.validate_ctest_inventory(
                {"tests": hw_entries},
                ci_label="ci_macos_arm64",
                ai_enabled=True,
                ai_package_present=True,
            ),
            [],
        )
        self.assertEqual(
            cci.validate_ctest_inventory(
                {"tests": hw_entries},
                ci_label="ci_macos_x86_64",
                ai_enabled=True,
                ai_package_present=True,
            ),
            [],
        )

        # Windows keeps ci_windows selection for all three tests unchanged.
        win_entries = [
            _make_entry("ai_session_memory", ["ai", "ci_macos_arm64", "ci_macos_x86_64", "ci_windows"], "ai_session_memory_tests"),
            _make_entry("dualdn_native", ["ai", "ci_macos_arm64", "ci_macos_x86_64", "ci_windows"], "dualdn_native_tests"),
            _make_entry("dualdn_api", ["ai", "ci_macos_arm64", "ci_macos_x86_64", "ci_windows"], "dualdn_api_tests"),
        ]
        self.assertEqual(
            cci.validate_ctest_inventory(
                {"tests": win_entries},
                ci_label="ci_windows",
                ai_enabled=True,
                ai_package_present=True,
            ),
            [],
        )

        # Re-adding ci_macos_arm64 or ci_macos_x86_64 to any of the three must fail closed.
        for name in ("ai_session_memory", "dualdn_native", "dualdn_api"):
            for label in ("ci_macos_arm64", "ci_macos_x86_64"):
                with self.subTest(name=name, label=label):
                    bad = {"tests": [_make_entry(name, ["ai", label])]}
                    errors = cci.validate_ctest_inventory(bad, ci_label=label)
                    self.assertTrue(any(name in e and label in e for e in errors), errors)

        # On macOS full (ai_enabled + ai_package_present), omitting or renaming any of the three must fail closed.
        renamed_entries = [
            _make_entry("tiff_ifd", ["core", "ci_macos_arm64"], "tiff_ifd_tests"),
            _make_entry("ai_session_memory", ["ai", "hw_gpu"], "ai_session_memory_tests"),
            _make_entry("dualdn_native_renamed", ["ai", "hw_gpu"], "dualdn_native_tests"),
            _make_entry("dualdn_api_renamed", ["ai", "hw_gpu"], "dualdn_api_tests"),
        ]
        missing_errors = cci.validate_ctest_inventory(
            {"tests": renamed_entries},
            ci_label="ci_macos_arm64",
            ai_enabled=True,
            ai_package_present=True,
        )
        self.assertTrue(any("dualdn_native" in e and "missing" in e for e in missing_errors), missing_errors)
        self.assertTrue(any("dualdn_api" in e and "missing" in e for e in missing_errors), missing_errors)

        # CLI output must distinguish "registered and excluded" from "absent" and emit log + step summary dynamically.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            json_path = root / "ctest.json"
            json_path.write_text(json.dumps({"tests": hw_entries}), encoding="utf-8")
            notice_log = root / "notice.log"
            summary_md = root / "summary.md"
            res = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/ci/check_ctest_inventory.py"),
                    "--json",
                    str(json_path),
                    "--ci-label",
                    "ci_macos_arm64",
                    "--ai-enabled",
                    "--ai-package-enabled",
                    "--notice-log",
                    str(notice_log),
                    "--write-step-summary",
                    "--skip-orphan-check",
                ],
                env={**os.environ, "GITHUB_STEP_SUMMARY": str(summary_md)},
                capture_output=True,
                text=True,
                check=True,
            )
            log_text = notice_log.read_text(encoding="utf-8")
            summary_text = summary_md.read_text(encoding="utf-8")
            for label_name, content in (("stdout", res.stdout), ("log", log_text), ("summary", summary_text)):
                self.assertRegex(content.lower(), r"not applicable on hosted", label_name)
                for name in ("ai_session_memory", "dualdn_native", "dualdn_api"):
                    self.assertIn(name, content, f"{label_name} missing {name}")
                self.assertIn("RawLabMac/tests/dualdn-api-package.sh", content, label_name)
                self.assertNotRegex(content, r"(?m)^SKIP\b", label_name)

            # Sandbox Experiment 1: AI OFF build-dir with --ai-enabled --ai-package-enabled must fail and write no notice.
            ai_off_dir = root / "ai-off-build"
            ai_off_dir.mkdir()
            (ai_off_dir / "CMakeCache.txt").write_text(
                "SONY2FUJI_ENABLE_AI_DENOISE:BOOL=OFF\n",
                encoding="utf-8",
            )
            fake_ctest = root / "fake-ctest.py"
            fake_ctest.write_text(
                "#!/usr/bin/env python3\nimport json\n"
                + f"print(json.dumps({{'tests': [{_make_entry('tiff_ifd', ['core', 'ci_macos_arm64'], 'tiff_ifd_tests')!r}]}}))\n",
                encoding="utf-8",
            )
            fake_ctest.chmod(0o755)
            ai_off_notice = root / "ai-off-notice.log"
            ai_off_res = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/ci/check_ctest_inventory.py"),
                    "--build-dir",
                    str(ai_off_dir),
                    "--ctest-bin",
                    str(fake_ctest),
                    "--ci-label",
                    "ci_macos_arm64",
                    "--ai-enabled",
                    "--ai-package-enabled",
                    "--notice-log",
                    str(ai_off_notice),
                    "--skip-orphan-check",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(ai_off_res.returncode, 0)
            self.assertIn("SONY2FUJI_ENABLE_AI_DENOISE", ai_off_res.stderr)
            self.assertFalse(ai_off_notice.exists(), "failed check must not write exclusion notice")

            # Sandbox Experiment 2: two of the three renamed with --ai-enabled --ai-package-enabled must fail.
            renamed_json = root / "renamed.json"
            renamed_json.write_text(json.dumps({"tests": renamed_entries}), encoding="utf-8")
            renamed_notice = root / "renamed-notice.log"
            renamed_res = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/ci/check_ctest_inventory.py"),
                    "--json",
                    str(renamed_json),
                    "--ci-label",
                    "ci_macos_arm64",
                    "--ai-enabled",
                    "--ai-package-enabled",
                    "--notice-log",
                    str(renamed_notice),
                    "--skip-orphan-check",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(renamed_res.returncode, 0)
            self.assertIn("dualdn_native", renamed_res.stderr)
            self.assertIn("dualdn_api", renamed_res.stderr)
            self.assertFalse(renamed_notice.exists(), "failed check must not write partial notice")

    @unittest.skipUnless(shutil.which("cmake"), "cmake is required")
    def test_ai_denoise_cmake_routes_three_coreml_tests_to_hw_gpu_on_apple_only(self) -> None:
        ai_cmake = (ROOT / "lutools/cmake/ai-denoise.cmake").as_posix()
        probe_script = f"""
macro(add_library)
endmacro()
macro(add_executable)
endmacro()
macro(target_include_directories)
endmacro()
macro(target_link_libraries)
endmacro()
macro(target_compile_definitions)
endmacro()
macro(target_sources)
endmacro()
macro(enable_language)
endmacro()
macro(set_property)
endmacro()
macro(set_source_files_properties)
endmacro()
macro(add_custom_command)
endmacro()
macro(find_package)
endmacro()
function(find_path var)
    set(${{var}} "/fake/ort/include" PARENT_SCOPE)
endfunction()
function(find_library var)
    set(${{var}} "/fake/ort/lib/libonnxruntime.dylib" PARENT_SCOPE)
endfunction()
function(rawlab_add_test)
    set(one_val NAME TARGET SKIP_RETURN_CODE)
    set(multi_val SOURCES COMMAND ARGS INCLUDES INCLUDES_BEFORE LIBRARIES DEFINES COMPILE_OPTIONS LINK_OPTIONS LABELS ENVIRONMENT)
    cmake_parse_arguments(ARG "" "${{one_val}}" "${{multi_val}}" ${{ARGN}})
    string(JOIN "," lbls ${{ARG_LABELS}})
    file(APPEND "${{OUT_FILE}}" "${{ARG_NAME}}=${{lbls}}\\n")
endfunction()
set(APPLE "${{SIM_APPLE}}")
set(WIN32 "${{SIM_WIN32}}")
set(IOS "${{SIM_IOS}}")
set(ANDROID "${{SIM_ANDROID}}")
set(CMAKE_CURRENT_SOURCE_DIR "{(ROOT / 'lutools').as_posix()}")
set(CMAKE_CURRENT_BINARY_DIR "${{OUT_DIR}}")
include("{ai_cmake}")
"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            probe = root / "probe.cmake"
            probe.write_text(probe_script, encoding="utf-8")

            def eval_cmake(defines: dict[str, str]) -> dict[str, set[str]]:
                out_file = root / f"out_{len(list(root.glob('out_*')))}.txt"
                cmd = ["cmake", f"-DOUT_FILE={out_file}", f"-DOUT_DIR={root}"]
                for k, v in defines.items():
                    cmd.append(f"-D{k}={v}")
                cmd.extend(["-P", str(probe)])
                subprocess.run(cmd, check=True, capture_output=True, text=True)
                parsed: dict[str, set[str]] = {}
                for line in out_file.read_text(encoding="utf-8").splitlines():
                    if "=" in line:
                        name, raw_labels = line.split("=", 1)
                        parsed[name] = set(filter(None, raw_labels.split(",")))
                return parsed

            # 1. macOS arm64 full (APPLE=ON, AI=ON, real package): the three carry hw_gpu and no ci_macos_*.
            mac_full = eval_cmake({
                "SIM_APPLE": "ON",
                "SIM_WIN32": "OFF",
                "SIM_IOS": "OFF",
                "SIM_ANDROID": "OFF",
                "BUILD_TESTING": "ON",
                "SONY2FUJI_ENABLE_AI_DENOISE": "ON",
                "SONY2FUJI_ENABLE_DIRECTML": "OFF",
                "RAWLAB_DUALDN_TEST_PACKAGE": "/fake/model/package",
            })
            for hw_name in ("ai_session_memory", "dualdn_native", "dualdn_api"):
                self.assertIn(hw_name, mac_full)
                self.assertIn("hw_gpu", mac_full[hw_name], hw_name)
                self.assertNotIn("ci_macos_arm64", mac_full[hw_name], hw_name)
                self.assertNotIn("ci_macos_x86_64", mac_full[hw_name], hw_name)
            for retained in (
                "dualdn_session",
                "dualdn_package",
                "dualdn_package_chinese",
                "dualdn_package_supplementary",
                "coreml_gpu_placement",
            ):
                self.assertIn(retained, mac_full)
                self.assertIn("ci_macos_arm64", mac_full[retained], retained)
            mac_entries = [_make_entry(n, sorted(lbls)) for n, lbls in mac_full.items()]
            self.assertEqual(cci.validate_ctest_inventory({"tests": mac_entries}, ci_label="ci_macos_arm64"), [])

            # 2. Windows full (WIN32=ON, APPLE=OFF, AI=ON, real package): unchanged ci_windows selection.
            win_full = eval_cmake({
                "SIM_APPLE": "OFF",
                "SIM_WIN32": "ON",
                "SIM_IOS": "OFF",
                "SIM_ANDROID": "OFF",
                "BUILD_TESTING": "ON",
                "SONY2FUJI_ENABLE_AI_DENOISE": "ON",
                "SONY2FUJI_ENABLE_DIRECTML": "OFF",
                "RAWLAB_DUALDN_TEST_PACKAGE": "/fake/model/package",
            })
            for name in ("ai_session_memory", "dualdn_native", "dualdn_api", "dualdn_session"):
                self.assertIn(name, win_full)
                self.assertIn("ci_windows", win_full[name], name)
                self.assertNotIn("hw_gpu", win_full[name], name)
            win_entries = [_make_entry(n, sorted(lbls)) for n, lbls in win_full.items()]
            self.assertEqual(cci.validate_ctest_inventory({"tests": win_entries}, ci_label="ci_windows"), [])

            # 3. macOS AI=OFF (native / models ctest row): dualdn_api_disabled stays selected on ci_macos_arm64.
            mac_no_ai = eval_cmake({
                "SIM_APPLE": "ON",
                "SIM_WIN32": "OFF",
                "SIM_IOS": "OFF",
                "SIM_ANDROID": "OFF",
                "BUILD_TESTING": "ON",
                "SONY2FUJI_ENABLE_AI_DENOISE": "OFF",
            })
            self.assertIn("dualdn_api_disabled", mac_no_ai)
            self.assertIn("ci_macos_arm64", mac_no_ai["dualdn_api_disabled"])


if __name__ == "__main__":
    unittest.main()
