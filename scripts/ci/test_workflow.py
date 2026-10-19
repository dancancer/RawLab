"""Regression guards for the hosted verification boundary, not a YAML linter."""
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(WORKFLOW.is_file(), "Hosted CI workflow is missing")
        self.text = WORKFLOW.read_text()
        # BaseLoader keeps GitHub's YAML 1.2 `on` key intact.
        self.workflow = yaml.load(self.text, Loader=yaml.BaseLoader)

    def test_events_do_not_publish(self):
        events = self.workflow["on"]
        self.assertEqual(set(events), {"pull_request", "push"})
        self.assertEqual(events["pull_request"]["branches"], ["development", "release/**", "main"])
        self.assertEqual(events["push"]["branches"], ["development", "main"])
        self.assertNotIn("tags", events["push"])
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertNotIn("secrets.", self.text)
        self.assertNotRegex(self.text, r"(?m)^\s*(?:environment|continue-on-error):")

    def test_all_platforms_are_required_and_bounded(self):
        jobs = self.workflow["jobs"]
        self.assertEqual(set(jobs), {"contracts", "macos", "windows", "android", "ios"})
        for name, job in jobs.items():
            with self.subTest(job=name):
                self.assertNotIn("if", job)
                self.assertLessEqual(int(job["timeout-minutes"]), 180)
                self.assertNotIn("permissions", job)
                self.assertNotIn("self-hosted", job["runs-on"])
        mac = jobs["macos"]
        self.assertEqual(mac["runs-on"], "${{ matrix.runner }}")
        self.assertEqual(mac["env"]["MACOSX_DEPLOYMENT_TARGET"], "14.0")
        self.assertEqual(mac["strategy"]["fail-fast"], "false")
        self.assertEqual(mac["strategy"]["matrix"]["include"], [
            {"runner": "macos-26", "arch": "arm64"},
            {"runner": "macos-26-intel", "arch": "x86_64"},
        ])
        self.assertEqual(jobs["ios"]["runs-on"], "macos-26")

    def test_actions_and_artifact_paths_are_constrained(self):
        for name, job in self.workflow["jobs"].items():
            uploads = []
            for step in job["steps"]:
                if "uses" not in step:
                    continue
                self.assertRegex(step["uses"], r"^actions/(?:[a-z-]+|cache/(?:restore|save))@[0-9a-f]{40}$")
                if step["uses"].startswith("actions/checkout@"):
                    self.assertEqual(step["with"]["persist-credentials"], "false")
                if step["uses"].startswith("actions/upload-artifact@"):
                    uploads.append(step)
                    self.assertEqual(step["if"], "always()")
                    self.assertEqual(step["with"]["retention-days"], "7")
                    for path in step["with"]["path"].splitlines():
                        self.assertRegex(path, r"^build/ci/\*\.(?:log|json|xml)$")
            self.assertEqual(len(uploads), 1, name)

    def test_existing_default_builds_are_not_feature_reduced(self):
        for command in ("RawLabMac/build.sh", "RawLabWindows/build.ps1", "testDebugUnitTest",
                        "assembleDebugAndroidTest", "check-native.sh", "build-framework.sh",
                        "verify-framework.sh", "build-for-testing"):
            self.assertIn(command, self.text)
        self.assertNotRegex(self.text, r"SONY2FUJI_ENABLE_\w+=OFF")
        self.assertNotRegex(self.text, r"RAWLAB_RUM_LOCAL[=: ]+['\"]?1")
        self.assertNotIn("-Test -SelfContained", self.text)

    def test_hosted_tool_discovery_preserves_failures(self):
        self.assertTrue('"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"' in self.text,
                        "Use the hosted SDK's explicit sdkmanager path")
        self.assertNotRegex(self.text, r"export \w+=\"\$\(")
        contracts = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["contracts"]["steps"])
        mac = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["macos"]["steps"])
        self.assertNotIn("test_photo_copy.py", contracts, "Photo-copy tests require macOS plutil")
        self.assertIn("test_photo_copy.py", mac)

    def test_tool_group_regressions_run_on_their_supported_hosts(self):
        commands = {
            name: "\n".join(step.get("run", "") for step in job["steps"])
            for name, job in self.workflow["jobs"].items()
        }
        self.assertIn("test_tool_group_ui.py", commands["contracts"])
        self.assertIn("RawLabMac/tests/presentation.sh", commands["macos"])
        self.assertIn("RawLabMac/tests/control-groups.sh", commands["macos"])
        self.assertIn("comparison-default,tool-groups,ui-details,looks", commands["windows"])

    def test_lut_contracts_include_the_adapter_dependencies(self):
        contracts = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["contracts"]["steps"])
        self.assertIn("pip install -r lutools/requirements-lutprep.txt", contracts)
        for suite in ("test_bundled_looks.py", "test_lut_source_audit.py", "test_prepare_bundled_looks.py"):
            self.assertIn("Shared/tests/" + suite, contracts)

    def test_mixed_batch_source_isolation_runs_on_macos(self):
        mac = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["macos"]["steps"])
        self.assertIn("RawLabMac/tests/batch-export.sh", mac)

    def test_macos_straighten_regression_runs_after_build_with_bundled_raw(self):
        steps = self.workflow["jobs"]["macos"]["steps"]
        build = next(step for step in steps if "bash RawLabMac/build.sh" in step.get("run", ""))
        run = build["run"]
        command = 'bash RawLabMac/tests/mac-straighten-preview.sh "$raw"'
        self.assertNotIn("if", build)
        self.assertIn(command, run)
        self.assertLess(run.index("bash RawLabMac/build.sh"), run.index(command))
        self.assertLess(run.index('raw="$PWD/lutools/examples/DJI_20250602164503_0444_D.DNG"'), run.index(command))
        self.assertNotIn("RAWLAB_TEST_RAW", run)

    def test_macos_dcp_regressions_require_synthetic_python_parity(self):
        steps = self.workflow["jobs"]["macos"]["steps"]
        build = next(step for step in steps if "bash RawLabMac/build.sh" in step.get("run", ""))
        run = build["run"]
        self.assertNotIn("if", build, "Both Mac architectures must execute the DCP suites")
        dependency = "python -m pip install -r lutools/requirements-lutprep.txt"
        self.assertIn(dependency, run, "Synthetic parity needs the existing NumPy/OCIO requirements")
        discovery = 'lutprep_python="$(command -v python)"'
        parity = 'RAWLAB_LUTPREP_PYTHON="$lutprep_python" bash RawLabMac/tests/dcp-compiler.sh'
        self.assertIn(discovery, run, "Resolve the setup-python interpreter without masking discovery errors")
        self.assertIn(parity, run, "The compiler script must not silently skip Python parity")
        self.assertLess(run.index(dependency), run.index(parity))
        self.assertLess(run.index(discovery), run.index(parity))
        for script in ("dcp-compiler.sh", "look-library.sh", "look-import-model.sh"):
            command = "bash RawLabMac/tests/" + script
            self.assertIn(command, run)
            self.assertLess(run.index("bash RawLabMac/build.sh"), run.index(command))
        self.assertNotIn("RAWLAB_TEST_DCP", run, "Hosted DCP coverage must not require private profiles")
        self.assertNotIn("RAWLAB_TEST_CANON_DCP", run)

    def test_only_prs_restore_exact_native_caches_and_cold_pushes_seed_them(self):
        for name in ("macos", "windows", "android", "ios"):
            with self.subTest(job=name):
                steps = self.workflow["jobs"][name]["steps"]
                restores = [step for step in steps if step.get("uses", "").startswith("actions/cache/restore@")]
                saves = [step for step in steps if step.get("uses", "").startswith("actions/cache/save@")]
                self.assertEqual(len(restores), 1)
                self.assertEqual(len(saves), 1)
                restore, save = restores[0], saves[0]
                self.assertEqual(restore["if"], "github.event_name == 'pull_request'")
                self.assertNotIn("restore-keys", restore["with"])
                self.assertEqual(restore["with"]["key"], "${{ steps.native-key.outputs.key }}")
                self.assertEqual(save["with"], restore["with"])
                self.assertEqual(save["if"], "success() && steps.native-cache.outputs.cache-hit != 'true'")
                self.assertLess(steps.index(restore), steps.index(save))
                builds = [step for step in steps if "run" in step and
                          any(command in step["run"] for command in
                              ("bash RawLabMac/build.sh", "./RawLabWindows/build.ps1", "./gradlew", "bash lutools/platform/ios/build-framework.sh"))]
                self.assertEqual(len(builds), 1)
                self.assertNotIn("if", builds[0], "Cache hits must still build and test the product")
                self.assertLess(steps.index(restore), steps.index(builds[0]))
                self.assertLess(steps.index(builds[0]), steps.index(save))

    def test_windows_shared_dcp_compiler_and_python_parity_are_required(self):
        run = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["windows"]["steps"])
        self.assertIn("dcp_compiler", run, "Windows must execute the shared compiler CTest")
        self.assertIn("lutools/requirements-lutprep.txt", run)
        self.assertIn("lutools/tests/test_dcp_compiler.py", run)
        self.assertIn("build/windows-native/bin/Release/dcp_compiler_tests.exe", run)
        self.assertIn("RAWLAB_TEST_DCP_NATIVE_LIB", run)
        self.assertIn("RAWLAB_TEST_DCP_FIXTURE_DIR", run)
        self.assertIn("'--fixtures'", run)

    def test_ios_shared_look_import_runs_after_framework_build(self):
        run = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["ios"]["steps"])
        self.assertIn("bash RawLab/tests/look-import.sh", run)
        self.assertLess(run.index("bash lutools/platform/ios/build-framework.sh"),
                        run.index("bash RawLab/tests/look-import.sh"))


if __name__ == "__main__":
    unittest.main()
