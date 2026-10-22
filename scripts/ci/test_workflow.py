"""Regression guards for the hosted verification boundary, not a YAML linter."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
CLEANUP = ROOT / ".github/workflows/pr-cache-cleanup.yml"
PLATFORM_JOBS = ("macos", "windows", "android", "ios")


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(WORKFLOW.is_file(), "Hosted CI workflow is missing")
        self.text = WORKFLOW.read_text()
        # BaseLoader keeps GitHub's YAML 1.2 `on` key intact.
        self.workflow = yaml.load(self.text, Loader=yaml.BaseLoader)

    def test_events_do_not_publish(self):
        events = self.workflow["on"]
        self.assertEqual(set(events), {"pull_request", "push", "schedule", "workflow_dispatch"})
        self.assertEqual(events["pull_request"]["branches"], ["development", "release/**", "main"])
        self.assertEqual(events["pull_request"]["types"],
                         ["opened", "synchronize", "reopened", "ready_for_review"])
        # main only receives release/hotfix PRs, which already run the full cold build.
        self.assertEqual(events["push"]["branches"], ["development"])
        self.assertNotIn("tags", events["push"])
        self.assertEqual(events["schedule"], [{"cron": "0 18 * * *"}])
        self.assertEqual(events["workflow_dispatch"], "")
        self.assertEqual(self.workflow["concurrency"]["group"],
                         "ci-${{ github.workflow }}-${{ github.event_name }}-"
                         "${{ github.event.pull_request.number || github.ref }}")
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertNotIn("secrets.", self.text)
        self.assertNotRegex(self.text, r"(?m)^\s*environment:")
        for job in self.workflow["jobs"].values():
            self.assertNotIn("continue-on-error", job)
            for step in job["steps"]:
                if "continue-on-error" in step:
                    self.assertEqual(step.get("id"), "native-cache")
                    self.assertTrue(step.get("uses", "").startswith("actions/cache/restore@"))

    def test_all_platforms_are_selected_bounded_and_gated(self):
        jobs = self.workflow["jobs"]
        self.assertEqual(set(jobs), {"changes", "contracts", *PLATFORM_JOBS, "result"})
        for name, job in jobs.items():
            with self.subTest(job=name):
                self.assertLessEqual(int(job["timeout-minutes"]), 180)
                if name == "changes":
                    self.assertEqual(job["permissions"], {"contents": "read", "actions": "read"})
                else:
                    self.assertNotIn("permissions", job)
                if name in PLATFORM_JOBS:
                    self.assertEqual(job["needs"], "changes")
                    self.assertEqual(job["if"], f"needs.changes.outputs.{name} == 'true'")
                else:
                    self.assertNotIn("self-hosted", job["runs-on"])
        self.assertNotIn("if", jobs["contracts"])
        self.assertNotIn("needs", jobs["contracts"])
        selection = jobs["changes"]
        self.assertEqual(set(selection["outputs"]), {*PLATFORM_JOBS, "cold", "draft"})
        self.assertIn("python3 scripts/ci/affected_platforms.py select",
                      "\n".join(step.get("run", "") for step in selection["steps"]))
        result = jobs["result"]
        self.assertEqual(result["name"], "CI result")
        self.assertEqual(result["needs"], ["changes", "contracts", *PLATFORM_JOBS])
        self.assertEqual(result["if"], "${{ !cancelled() && needs.changes.outputs.draft != 'true' }}")
        gate = next(step for step in result["steps"] if "run" in step)
        self.assertEqual(gate["env"]["NEEDS"], "${{ toJSON(needs) }}")
        self.assertEqual(gate["run"], "python3 scripts/ci/affected_platforms.py verify")
        mac = jobs["macos"]
        self.assertEqual(mac["runs-on"], "${{ matrix.runner }}")
        self.assertEqual(mac["env"]["MACOSX_DEPLOYMENT_TARGET"], "14.0")
        self.assertEqual(mac["env"]["RAWLAB_MAC_SUITE"], "${{ matrix.suite }}")
        self.assertEqual(mac["strategy"]["fail-fast"], "false")
        self.assertEqual(mac["strategy"]["matrix"]["include"], [
            {"runner": ["self-hosted", "macOS", "ARM64", "rawlab-apple"], "arch": "arm64", "jobs": "6", "suite": "all"},
            {"runner": "macos-26-intel", "arch": "x86_64", "jobs": "4", "suite": "core"},
            {"runner": "macos-26-intel", "arch": "x86_64", "jobs": "4", "suite": "render"},
        ])
        self.assertEqual(jobs["ios"]["runs-on"], ["self-hosted", "macOS", "ARM64", "rawlab-apple"])

    def test_actions_and_artifact_paths_are_constrained(self):
        for name, job in self.workflow["jobs"].items():
            if name in ("changes", "result"):
                self.assertFalse([step for step in job["steps"]
                                  if step.get("uses", "").startswith("actions/upload-artifact@")])
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
                    allowed_paths = {"build/ci/*.log", "build/ci/*.json", "build/ci/*.xml"}
                    if name == "windows":
                        allowed_paths.add("build/windows-v08-results/**/*.png")
                    for path in step["with"]["path"].splitlines():
                        self.assertIn(path, allowed_paths)
            self.assertEqual(len(uploads), 0 if name in ("changes", "result") else 1, name)

    def test_android_uses_a_dedicated_linux_runner_with_bounded_parallelism(self):
        android = self.workflow["jobs"]["android"]
        self.assertEqual(android["runs-on"], ["self-hosted", "linux", "x64", "rawlab-android"])
        self.assertEqual(android["env"]["JOBS"], "8")
        self.assertEqual(android["env"]["CMAKE_BUILD_PARALLEL_LEVEL"], "8")
        self.assertEqual(android["env"]["ANDROID_HOME"], "/opt/android-sdk")
        self.assertEqual(android["env"]["RAWLAB_LENS_SOURCE_CACHE"], "/var/cache/rawlab-ci/lens-sources")
        commands = "\n".join(step.get("run", "") for step in android["steps"])
        self.assertIn("--max-workers=8", commands)
        self.assertIn("RAWLAB_TEST_ANDROID_CACHE=1", commands)

    def test_actionlint_recognizes_only_the_declared_local_runner_label(self):
        configuration = ROOT / ".github/actionlint.yaml"
        self.assertTrue(configuration.is_file(), "Declare custom labels for actionlint")
        policy = yaml.load(configuration.read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(policy["self-hosted-runner"]["labels"],
                         ["rawlab-android", "rawlab-windows", "rawlab-apple"])

    def test_local_apple_jobs_use_prepared_tools_and_preserve_selected_xcode(self):
        jobs = self.workflow['jobs']
        self.assertEqual(jobs['macos']['env']['JOBS'], '${{ matrix.jobs }}')
        self.assertEqual(jobs['ios']['env']['JOBS'], '6')
        for name in ('macos', 'ios'):
            steps = jobs[name]['steps']
            python_setup = [step for step in steps if step.get('uses', '').startswith('actions/setup-python@')]
            if name == 'macos':
                self.assertEqual(python_setup[0]['if'], "matrix.arch == 'x86_64'")
            else:
                self.assertEqual(python_setup, [])
            key_step = next(step for step in steps if step.get('id') == 'native-key')
            self.assertIn('pip install -r scripts/ci/requirements.txt', key_step['run'])
            commands = '\n'.join(step.get('run', '') for step in steps)
            self.assertIn('DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"', commands)

    def test_macos_uses_available_intel_cpus_and_bounded_test_parallelism(self):
        macos = self.workflow['jobs']['macos']
        intel = next(row for row in macos['strategy']['matrix']['include']
                     if row['arch'] == 'x86_64')
        self.assertEqual(intel['jobs'], '4')
        self.assertEqual(macos['env']['CMAKE_BUILD_PARALLEL_LEVEL'], '${{ matrix.jobs }}')
        run = '\n'.join(step.get('run', '') for step in macos['steps'])
        self.assertIn('ctest --test-dir lutools/build-macos --parallel 2', run)
        self.assertIn("-E '^(native_dcp_metal|gpu_photo|metal_denoise)$'", run)

    def test_macos_timing_records_success_without_masking_command_failure(self):
        build = next(step for step in self.workflow['jobs']['macos']['steps']
                     if 'bash RawLabMac/build.sh' in step.get('run', ''))
        run = build['run']
        self.assertIn('ci_timed() {', run)
        function = 'ci_timed() {' + run.split('ci_timed() {', 1)[1].split('\n}', 1)[0] + '\n}'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'build/ci').mkdir(parents=True)
            probe = ("\nPROBE_ENV=expected ci_timed passed bash -c 'test \"$PROBE_ENV\" = expected'"
                     "\nci_timed failed bash -c 'exit 7'\ntouch should-not-exist")
            result = subprocess.run(['bash', '-euc', function + probe], cwd=root,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
            self.assertFalse((root / 'should-not-exist').exists())
            self.assertRegex((root / 'build/ci/macos-timings.log').read_text(),
                             r'^passed\t\d+\t0\nfailed\t\d+\t7\n$')

    def test_windows_uses_a_dedicated_runner_and_data_volume(self):
        windows = self.workflow["jobs"]["windows"]
        self.assertEqual(windows["runs-on"], ["self-hosted", "windows", "x64", "rawlab-windows"])
        self.assertEqual(windows["env"]["DOTNET_INSTALL_DIR"], "E:\\RawLabCI\\dotnet")
        self.assertEqual(windows["env"]["RAWLAB_LENS_SOURCE_CACHE"], "E:\\RawLabCI\\cache\\lens-sources")
        self.assertEqual(windows["env"]["JOBS"], "16")
        self.assertEqual(windows["env"]["CMAKE_BUILD_PARALLEL_LEVEL"], "16")
        # File-level MSVC parallelism stays bounded by one cross-project process count.
        self.assertEqual({name: windows["env"][name] for name in
                          ("UseMultiToolTask", "EnforceProcessCountAcrossBuilds", "CL_MPCount")},
                         {"UseMultiToolTask": "true", "EnforceProcessCountAcrossBuilds": "true", "CL_MPCount": "24"})

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

    def test_windows_draft_transactions_run_on_the_native_host(self):
        commands = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["windows"]["steps"])
        invocation = next(line for line in commands.splitlines()
                          if "./RawLabWindows/tests/run-v08.ps1" in line)
        selected = invocation.split("-Only '", 1)[1].split("'", 1)[0].split(",")
        self.assertIn("transform-ui", selected, "Draft save failure and retry require the real WPF harness")
        self.assertIn("editing", selected)
        self.assertIn("-RawPath $raw -NativeArtifacts $package", invocation)

    def test_parameter_input_models_run_on_their_native_platform_jobs(self):
        commands = {
            name: "\n".join(step.get("run", "") for step in job["steps"])
            for name, job in self.workflow["jobs"].items()
        }
        self.assertIn("RawLabMac/tests/parameter-value.sh", commands["macos"])
        self.assertIn("RawLab/tests/adjustment-scale.sh", commands["ios"])
        self.assertNotIn("parameter-value.sh", commands["contracts"])
        self.assertNotIn("adjustment-scale.sh", commands["contracts"])

    def test_windows_workspace_navigation_has_runtime_and_visual_evidence(self):
        steps = self.workflow["jobs"]["windows"]["steps"]
        commands = "\n".join(step.get("run", "") for step in steps)
        invocation = next(line for line in commands.splitlines()
                          if "./RawLabWindows/tests/run-v08.ps1" in line)
        selected = invocation.split("-Only '", 1)[1].split("'", 1)[0].split(",")
        for suite in ("tool-groups", "ui-details", "editor-shell", "editor-review",
                      "localization-ui", "transform-ui"):
            self.assertIn(suite, selected, "Workspace navigation requires its real WPF suite")
        upload = next(step for step in steps if step.get("with", {}).get("name") == "windows-results")
        self.assertIn("build/windows-v08-results/**/*.png", upload["with"]["path"])

    def test_lut_contracts_include_the_adapter_dependencies(self):
        contracts = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["contracts"]["steps"])
        self.assertIn("pip install -r lutools/requirements-lutprep.txt", contracts)
        for suite in ("test_bundled_looks.py", "test_lut_source_audit.py", "test_prepare_bundled_looks.py"):
            self.assertIn("Shared/tests/" + suite, contracts)

    def test_ios_editing_models_run_in_the_gated_platform_job(self):
        steps = self.workflow["jobs"]["ios"]["steps"]
        build = next(step for step in steps if "build-for-testing" in step.get("run", ""))
        self.assertNotIn("if", build)
        for command in ("bash RawLab/tests/presentation.sh", "bash RawLab/tests/edit-memory.sh"):
            self.assertIn(command, build["run"])
            self.assertLess(build["run"].index("build-for-testing"), build["run"].index(command))

    def test_mcp_protocol_and_built_cli_parity_are_gated(self):
        contracts = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["contracts"]["steps"])
        self.assertIn("uv run --project tools/mcp --frozen python -m unittest discover -s tools/mcp/tests -v", contracts)
        mac = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["macos"]["steps"])
        parity = "RAWLAB_MCP_CLI=\"$cli\" uv run --project tools/mcp --frozen python -m unittest discover -s tools/mcp/tests -p test_real_cli.py -v"
        self.assertIn(parity, mac)
        self.assertLess(mac.index("ci_timed app-build"), mac.index(parity))
        self.assertLess(mac.index('cli="$PWD/lutools/build-macos/sony2fuji"'), mac.index(parity))

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

    def test_exact_native_caches_are_reused_except_by_cold_builds(self):
        for name in PLATFORM_JOBS:
            with self.subTest(job=name):
                steps = self.workflow["jobs"][name]["steps"]
                restores = [step for step in steps if step.get("uses", "").startswith("actions/cache/restore@")]
                saves = [step for step in steps if step.get("uses", "").startswith("actions/cache/save@")]
                self.assertEqual(len(restores), 1)
                self.assertEqual(len(saves), 1)
                restore, save = restores[0], saves[0]
                self.assertNotIn("if", restore)
                self.assertEqual(restore["continue-on-error"], "true")
                self.assertEqual(restore["with"]["lookup-only"], "${{ needs.changes.outputs.cold == 'true' }}")
                self.assertNotIn("restore-keys", restore["with"])
                self.assertEqual(restore["with"]["key"], "${{ steps.native-key.outputs.key }}")
                self.assertEqual(save["with"], {key: restore["with"][key] for key in ("key", "path")})
                shard = "matrix.suite != 'render' && " if name == "macos" else ""
                self.assertEqual(save["if"], f"success() && {shard}steps.native-cache.outcome == 'success' && "
                                             "steps.native-cache.outputs.cache-hit != 'true'")
                self.assertLess(steps.index(restore), steps.index(save))
                builds = [step for step in steps if "run" in step and
                          any(command in step["run"] for command in
                              ("bash RawLabMac/build.sh", "./RawLabWindows/build.ps1", "./gradlew", "bash lutools/platform/ios/build-framework.sh"))]
                self.assertEqual(len(builds), 1)
                self.assertNotIn("if", builds[0], "Cache hits must still build and test the product")
                self.assertEqual(builds[0]["env"]["RAWLAB_CI_CACHE_HIT"],
                                 "${{ needs.changes.outputs.cold != 'true' && steps.native-cache.outputs.cache-hit == 'true' }}")
                self.assertLess(steps.index(restore), steps.index(builds[0]))
                self.assertLess(steps.index(builds[0]), steps.index(save))

    def test_intel_shards_cover_every_native_suite_and_model_suites_run_on_arm64(self):
        build = next(step for step in self.workflow["jobs"]["macos"]["steps"]
                     if "bash RawLabMac/build.sh" in step.get("run", ""))
        groups, current = {None: []}, None
        for line in build["run"].splitlines():
            line = line.strip()
            if line.startswith("if in_suite "):
                self.assertIsNone(current, "Suite groups must not nest")
                current = line.split()[2].rstrip(";")
                groups.setdefault(current, [])
            elif line == "fi" and current:
                current = None
            else:
                groups[current].append(line)
        self.assertEqual(set(groups), {None, "core", "render", "model"})
        always = "\n".join(groups[None])
        for command in ("ci_timed app-build bash RawLabMac/build.sh", "native_cache.py inventory"):
            self.assertIn(command, always, "Every shard builds the app and records its cache inventory")
        expected = {
            "core": ("test_photo_copy.py", "horizontal-picker-native.sh", "dcp-compiler.sh",
                     "look-library.sh", "look-import-model.sh", "ctest --test-dir lutools/build-macos"),
            "render": ("mac-straighten-preview.sh", "agent-recipe-render.sh", "raster-render.sh"),
            "model": ("batch-export.sh", "edit-model.sh", "presentation.sh", "control-groups.sh",
                      "usage-analytics.sh", "usage-transport.sh", "usage-model.sh", "usage-termination.sh",
                      "rum-configuration.sh", "localization.sh"),
        }
        for group, commands in expected.items():
            text = "\n".join(groups[group])
            for command in commands:
                with self.subTest(group=group, command=command):
                    self.assertIn(command, text)
        self.assertIn('in_suite() { [[ "$RAWLAB_MAC_SUITE" == all || "$RAWLAB_MAC_SUITE" == "$1" ]]; }', always)
        suites = {row["arch"]: [] for row in self.workflow["jobs"]["macos"]["strategy"]["matrix"]["include"]}
        for row in self.workflow["jobs"]["macos"]["strategy"]["matrix"]["include"]:
            suites[row["arch"]].append(row["suite"])
        self.assertEqual(suites, {"arm64": ["all"], "x86_64": ["core", "render"]})

    def test_pr_cache_cleanup_only_deletes_its_own_merge_ref(self):
        cleanup = yaml.load(CLEANUP.read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(cleanup["on"], {"pull_request": {"types": ["closed"]}})
        self.assertEqual(cleanup["permissions"], {"actions": "write"})
        job = cleanup["jobs"]["cleanup"]
        self.assertEqual(job["if"], "github.event.pull_request.head.repo.full_name == github.repository")
        self.assertEqual([step for step in job["steps"] if "uses" in step], [], "Do not run repository code")
        step = job["steps"][0]
        self.assertEqual(step["env"]["CACHE_REF"], "refs/pull/${{ github.event.pull_request.number }}/merge")
        self.assertIn('actions/caches?ref=$CACHE_REF', step["run"])
        self.assertEqual(step["run"].count("--method DELETE"), 1)

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
