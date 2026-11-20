"""Unit tests and CI policy checks for ctest --show-only=json-v1 inventory reconciliation."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_ctest_inventory as cci


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"


def _make_entry(name: str, labels: list[str], executable: str | None = None) -> dict:
    entry: dict = {
        "name": name,
        "properties": [{"name": "LABELS", "value": labels}],
    }
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


if __name__ == "__main__":
    unittest.main()
