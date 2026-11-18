"""Reconcile CI Windows test selections against on-disk suites and CMake CTests (P2-23 / P2-24)."""

from __future__ import annotations

from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
WINDOWS_MODELS = ROOT / "scripts/ci/windows-models.ps1"
WIN_TESTS = ROOT / "RawLabWindows/tests"

# Documented inventory partition for RawLabWindows/tests/*.csproj and *.ps1.
CI_MODEL_CSPROJS = {
    "denoise/DenoiseSettingsTests.csproj",
    "editing/EditWorkflow.Tests.csproj",
    "localization/LocalizationChecks.csproj",
    "looks/LookGrouping.Tests.csproj",
    "system-open/SystemOpen.Tests.csproj",
    "updates/UpdateChecks.csproj",
    "updates-sdk/UpdateSdkChecks.csproj",
    "usage/UsageAnalytics.Tests.csproj",
}
CI_NATIVE_BUILD_AND_SELECTIVE_CSPROJS = {
    "RawLabWindows.Tests.csproj",
}
EXCLUDED_CSPROJS = {
    # Built in CI native/build step (ci.yml) to guard WPF compilation, not launched headless.
    "localization-ui/LocalizationUiChecks.csproj": "interactive_wpf_ui_built_only",
    # UI Automation driver requiring an interactive Windows desktop session.
    "ui-automation/RawLabWindows.UiAutomation.csproj": "interactive_desktop_uia",
    # Velopack offline update packaging fixture executed only by updates-sdk/offline.ps1.
    "update-fixture/UpdateFixture.csproj": "installer_offline_fixture",
}

CI_MODEL_PS1S = {
    "BuildScriptChecks.ps1",
    "CheckProcessChecks.ps1",
    "RunnerSelectionChecks.ps1",
}
CI_NATIVE_PS1S = {
    "run-v08.ps1",
}
CI_MANUAL_WARP_PS1S = {
    "native/d3d11/check-mutations.ps1",
}
HELPER_OR_EXCLUDED_PS1S = {
    "CheckProcess.ps1": "dot_sourced_process_runner_helper",
    "run-comparison-native.ps1": "interactive_desktop_uia_harness",
    "updates-sdk/offline.ps1": "velopack_offline_installer_check",
}

# Only checks requiring sony2fuji.dll may opt out of windows-models.ps1 and run under CI native.
NATIVE_ONLY_EDIT_CHECKS = {
    "HDRAssetImportChecks": "--hdr-look-import",
}


class WindowsInventoryTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        self.windows_steps = "\n".join(
            step.get("run", "") for step in self.workflow["jobs"]["windows"]["steps"]
        )
        self.windows_models_ps1 = WINDOWS_MODELS.read_text(encoding="utf-8")

    def test_windows_projects_and_scripts_are_partitioned_without_drift(self):
        actual_csprojs = {
            p.relative_to(WIN_TESTS).as_posix() for p in WIN_TESTS.rglob("*.csproj")
        }
        accounted_csprojs = CI_MODEL_CSPROJS | CI_NATIVE_BUILD_AND_SELECTIVE_CSPROJS | set(EXCLUDED_CSPROJS)
        self.assertEqual(actual_csprojs - accounted_csprojs, set(),
                         "Uncategorized RawLabWindows/tests .csproj suites exist on disk")
        self.assertEqual(accounted_csprojs - actual_csprojs, set(),
                         "Listed RawLabWindows/tests .csproj suites do not exist on disk")

        for proj in sorted(CI_MODEL_CSPROJS):
            self.assertIn(proj, self.windows_models_ps1,
                          f"Model suite {proj} missing from scripts/ci/windows-models.ps1")
        for proj in sorted(CI_NATIVE_BUILD_AND_SELECTIVE_CSPROJS):
            self.assertIn(f"RawLabWindows/tests/{proj}", self.windows_steps,
                          f"Native suite {proj} missing from ci.yml windows steps")

        actual_ps1s = {
            p.relative_to(WIN_TESTS).as_posix() for p in WIN_TESTS.rglob("*.ps1")
        }
        accounted_ps1s = CI_MODEL_PS1S | CI_NATIVE_PS1S | CI_MANUAL_WARP_PS1S | set(HELPER_OR_EXCLUDED_PS1S)
        self.assertEqual(actual_ps1s - accounted_ps1s, set(),
                         "Uncategorized RawLabWindows/tests .ps1 scripts exist on disk")
        self.assertEqual(accounted_ps1s - actual_ps1s, set(),
                         "Listed RawLabWindows/tests .ps1 scripts do not exist on disk")

        for script in sorted(CI_MODEL_PS1S | CI_NATIVE_PS1S | CI_MANUAL_WARP_PS1S):
            self.assertIn(f"RawLabWindows/tests/{script}", self.windows_steps,
                          f"Headless Windows script RawLabWindows/tests/{script} is not invoked in ci.yml")

        # Bidirectional check: every RawLabWindows/tests/ path mentioned in ci.yml or windows-models.ps1 exists.
        refs = set(re.findall(r"RawLabWindows/tests/[A-Za-z0-9_./-]+\.(?:csproj|ps1)",
                              self.windows_steps + "\n" + self.windows_models_ps1))
        for rel_from_tests in re.findall(r"\$root/([A-Za-z0-9_./-]+\.csproj)", self.windows_models_ps1):
            refs.add(f"RawLabWindows/tests/{rel_from_tests}")
        for ref in sorted(refs):
            self.assertTrue((ROOT / ref).is_file(), f"CI references missing file: {ref}")

    def test_edit_workflow_checks_and_banners_are_admitted(self):
        editing_dir = WIN_TESTS / "editing"
        csproj = ET.parse(editing_dir / "EditWorkflow.Tests.csproj")
        prog_text = (editing_dir / "Program.cs").read_text(encoding="utf-8")

        check_files: dict[str, Path] = {
            p.stem: p for p in editing_dir.glob("*Checks.cs")
        }
        for el in csproj.iter("Compile"):
            inc = el.attrib.get("Include", "")
            if inc.endswith("Checks.cs"):
                resolved = (editing_dir / inc).resolve()
                self.assertTrue(resolved.is_file(), f"Missing linked EditWorkflow check: {inc}")
                check_files[resolved.stem] = resolved

        # Split Program.cs into early return `--*` flags section vs unconditional default execution body.
        default_start = prog_text.index('if (args.Contains("--master-recipes"))')
        # Checks run unconditionally are those called outside an `args.Contains(...)` return branch.
        unconditional_text = re.sub(
            r'if\s*\(\s*args\.Contains\([^\)]+\)\s*\)\s*\{[^}]*\}', "", prog_text
        )
        # Also include calls in default section (unconditional_text still contains lines 58..end except the return blocks).
        self.assertGreater(default_start, 0)

        for name, path in sorted(check_files.items()):
            with self.subTest(check=name):
                src = path.read_text(encoding="utf-8")
                self.assertRegex(
                    src,
                    r'Console\.WriteLine\s*\(\s*\$?"PASS\b',
                    f"{name} ({path.relative_to(ROOT)}) does not emit a PASS banner/assertion message",
                )
                if name in NATIVE_ONLY_EDIT_CHECKS:
                    flag = NATIVE_ONLY_EDIT_CHECKS[name]
                    self.assertIn(flag, prog_text, f"Flag {flag} for {name} missing in editing/Program.cs")
                    self.assertIn(f"{name}.Run", prog_text, f"{name}.Run missing in editing/Program.cs")
                    self.assertIn(flag, self.windows_steps,
                                  f"Native-only EditWorkflow check {name} ({flag}) is never invoked in ci.yml")
                    self.assertIn("RAWLAB_TEST_NATIVE_HDR_LIBRARY", self.windows_steps,
                                  f"ci.yml must bind RAWLAB_TEST_NATIVE_HDR_LIBRARY when running {flag}")
                else:
                    self.assertRegex(
                        unconditional_text,
                        rf"\b{re.escape(name)}\.Run\s*\(",
                        f"{name} is not unconditionally executed on the default EditWorkflow.Tests path",
                    )

    def test_run_v08_and_runner_selection_and_program_flags_reconcile(self):
        run_v08 = (WIN_TESTS / "run-v08.ps1").read_text(encoding="utf-8")
        runner_checks = (WIN_TESTS / "RunnerSelectionChecks.ps1").read_text(encoding="utf-8")
        prog_text = (WIN_TESTS / "Program.cs").read_text(encoding="utf-8")

        def extract_names(text: str) -> list[str]:
            match = re.search(r"\$names\s*=\s*@\(([^)]+)\)", text, re.S)
            self.assertIsNotNone(match, "Could not locate $names array")
            return re.findall(r"'([^']+)'", match.group(1))

        v08_names = extract_names(run_v08)
        sel_names = extract_names(runner_checks)
        # RunnerSelectionChecks.ps1 puts baseline non-AI suites in $names and checks 'ai-window' explicitly.
        self.assertIn("ai-window", v08_names, "'ai-window' missing from run-v08.ps1 $names")
        self.assertIn("'ai-window'", runner_checks, "'ai-window' selection checks missing from RunnerSelectionChecks.ps1")
        self.assertEqual([n for n in v08_names if n != "ai-window"], sel_names,
                         "run-v08.ps1 $names drifted from RunnerSelectionChecks.ps1")

        # Validate CI -Only selection items exist in run-v08.ps1 $names.
        match_only = re.search(r"run-v08\.ps1[^\n]*-Only '([^']+)'", self.windows_steps)
        self.assertIsNotNone(match_only)
        ci_only = [s.strip() for s in match_only.group(1).split(",")]
        for suite in ci_only:
            self.assertIn(suite, v08_names, f"ci.yml -Only suite '{suite}' does not exist in run-v08.ps1")

        # Separate build/sub-project suites from RawLabWindows.Tests `--<flag>` dispatches.
        non_flag_suites = {
            "build", "build-localization-ui", "editing", "looks", "denoise-model",
            "localization", "updates", "localization-ui",
        }
        explicit_flag_aliases = {
            "localization-admission": "--default-isolation",
        }
        prog_flags = set(re.findall(r'"(--[a-z0-9-]+)"', prog_text))
        for suite in v08_names:
            if suite in non_flag_suites:
                continue
            expected_flag = explicit_flag_aliases.get(suite, f"--{suite}")
            if f"'{suite}'" in run_v08.split("$modes", 1)[-1]:
                # Dynamic `$modes` suites invoke `--$name`.
                pass
            self.assertIn(expected_flag, prog_flags,
                          f"run-v08.ps1 suite '{suite}' expects missing Program.cs flag {expected_flag}")


if __name__ == "__main__":
    unittest.main()
