"""Regression guards for the hosted verification boundary, not a YAML linter."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

import yaml

from affected_platforms import macos_matrix


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
        self.assertEqual(set(events), {"pull_request", "push", "workflow_dispatch"})
        self.assertEqual(events["pull_request"]["branches"], ["development", "release/**", "main"])
        self.assertEqual(events["pull_request"]["types"],
                         ["opened", "synchronize", "reopened", "ready_for_review"])
        # main only receives release/hotfix PRs, which already run the full cold build.
        self.assertEqual(events["push"]["branches"], ["development"])
        self.assertNotIn("tags", events["push"])
        self.assertNotIn("schedule", events)
        inputs = events["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["platform"]["options"], ["all", *PLATFORM_JOBS])
        self.assertEqual(inputs["checks"]["options"], ["contracts", "models", "build", "native", "full"])
        self.assertEqual(inputs["checks"]["default"], "models")
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
        self.assertEqual(jobs["contracts"]["if"], "needs.changes.outputs.contracts == 'true'")
        self.assertEqual(jobs["contracts"]["needs"], "changes")
        selection = jobs["changes"]
        self.assertEqual(set(selection["outputs"]), {*PLATFORM_JOBS, "cold", "draft", "windows_runner", "mode", "scope", "checks", "contracts", "models", "build", "native", "macos_matrix"})
        self.assertIn("python3 scripts/ci/affected_platforms.py select",
                      "\n".join(step.get("run", "") for step in selection["steps"]))
        result = jobs["result"]
        self.assertEqual(result["name"], "${{ github.event_name == 'workflow_dispatch' && format('Manual verification ({0}, {1})', inputs.platform, inputs.checks) || 'CI result' }}")
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
        self.assertEqual(mac["strategy"]["matrix"]["include"], "${{ fromJSON(needs.changes.outputs.macos_matrix) }}")
        self.assertEqual(macos_matrix("full"), [
            {"runner": ["self-hosted", "macOS", "ARM64", "rawlab-apple"], "arch": "arm64", "jobs": "6", "suite": "all"},
            {"runner": "macos-26-intel", "arch": "x86_64", "jobs": "4", "suite": "core"},
            {"runner": "macos-26-intel", "arch": "x86_64", "jobs": "4", "suite": "agent"},
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
                        allowed_paths |= {"build/ci/windows-models/*.log", "build/ci/windows-models/*.json"}
                        allowed_paths |= {f"build/ci/{suite}/**/*.{extension}"
                                          for suite, extensions in (("process-checks", ("log", "json")),
                                                                    ("runner-checks", ("log", "json", "jsonl")))
                                          for extension in extensions}
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
        intel = next(row for row in macos_matrix('full')
                     if row['arch'] == 'x86_64')
        self.assertEqual(intel['jobs'], '4')
        self.assertEqual(macos['env']['CMAKE_BUILD_PARALLEL_LEVEL'], '${{ matrix.jobs }}')
        run = '\n'.join(step.get('run', '') for step in macos['steps'])
        self.assertIn('ctest --test-dir lutools/build-macos --parallel 2', run)

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

    def test_metal_workspace_runs_on_physical_apple_runner_only(self):
        run = next(step['run'] for step in self.workflow['jobs']['macos']['steps']
                   if 'bash RawLabMac/build.sh' in step.get('run', ''))
        ctest = run.split('ci_timed look-import-model bash RawLabMac/tests/look-import-model.sh\n', 1)[1]
        ctest = ctest.split('\nfi', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / 'lutools/build-macos'
            build.mkdir(parents=True)
            (root / 'build/ci').mkdir(parents=True)
            names = ('wavelet_denoise', 'metal_workspace', 'native_dcp_metal', 'gpu_photo', 'metal_denoise')
            (build / 'CTestTestfile.cmake').write_text(''.join(
                f'add_test({name} "{sys.executable}" "-c" "pass")\n' for name in names))
            for arch, expected in (('x86_64', {'wavelet_denoise'}),
                                   ('arm64', {'wavelet_denoise', 'metal_workspace'})):
                with self.subTest(arch=arch):
                    result = subprocess.run(['bash', '-euc',
                        f'RAWLAB_ARCH={arch}\nci_timed() {{ shift; "$@"; }}\n' + ctest],
                        cwd=root, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    report = ET.parse(root / 'build/ci/macos-ctest.xml')
                    self.assertEqual({case.attrib['name'] for case in report.iter('testcase')}, expected)

    def test_windows_consumes_the_selected_runner_and_prepares_its_environment_first(self):
        windows = self.workflow["jobs"]["windows"]
        self.assertEqual(windows["runs-on"], "${{ fromJSON(needs.changes.outputs.windows_runner) }}")
        self.assertEqual(self.workflow["jobs"]["changes"]["outputs"]["windows_runner"],
                         "${{ steps.select.outputs.windows_runner }}")
        steps = windows["steps"]
        configure = next(step for step in steps if step.get("id") == "windows-env")
        self.assertEqual(configure["env"]["CI_RUNNER_ENVIRONMENT"], "${{ runner.environment }}")
        self.assertNotIn("if", configure)
        for step in steps:
            if step.get("id") == "native-key" or step.get("uses", "").startswith("actions/setup-dotnet@"):
                self.assertLess(steps.index(configure), steps.index(step))
        self.assertEqual({name: windows["env"][name] for name in
                          ("UseMultiToolTask", "EnforceProcessCountAcrossBuilds")},
                         {"UseMultiToolTask": "true", "EnforceProcessCountAcrossBuilds": "true"})

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
        self.assertIn("bash scripts/ci/apple-models.sh macos", mac)
        self.assertIn("test_photo_copy.py", (ROOT / "scripts/ci/apple-models.sh").read_text())

    def test_tool_group_regressions_run_on_their_supported_hosts(self):
        commands = {
            name: "\n".join(step.get("run", "") for step in job["steps"])
            for name, job in self.workflow["jobs"].items()
        }
        self.assertIn("test_tool_group_ui.py", commands["contracts"])
        self.assertIn("RawLabMac/tests/presentation.sh", commands["macos"])
        self.assertIn("RawLabMac/tests/control-groups.sh", (ROOT / "scripts/ci/apple-models.sh").read_text())
        self.assertIn("agent-recipe,raster,looks", commands["windows"])
        self.assertIn("scripts/ci/windows-models.ps1", commands["windows"])

    def test_ci_runs_models_and_native_checks_without_ui_automation(self):
        commands = {
            name: "\n".join(step.get("run", "") for step in job["steps"])
            for name, job in self.workflow["jobs"].items()
        }
        invocation = next(line for line in commands["windows"].splitlines()
                          if "./RawLabWindows/tests/run-v08.ps1" in line)
        selected = invocation.split("-Only '", 1)[1].split("'", 1)[0].split(",")
        self.assertEqual(set(selected), {"agent-recipe", "raster", "looks"})
        self.assertIn("-RawPath $raw -NativeArtifacts $package", invocation)
        for suite in ("CheckProcessChecks.ps1", "RunnerSelectionChecks.ps1"):
            self.assertIn(suite, commands["windows"])
        upload = next(step for step in self.workflow["jobs"]["windows"]["steps"]
                      if step.get("with", {}).get("name") == "windows-results")
        for suite in ("process-checks", "runner-checks"):
            self.assertIn(f"-Output 'build/ci/{suite}'", commands["windows"])
            self.assertIn(f"build/ci/{suite}/**/*.log", upload["with"]["path"])
            self.assertIn(f"build/ci/{suite}/**/*.json", upload["with"]["path"])
        for ui in ("horizontal-picker-native.sh", "mac-straighten-preview.sh", "parameter-value.sh", "mac-canvas-input.sh"):
            self.assertNotIn(ui, commands["macos"])
        self.assertIn("RawLabMac/tests/presentation.sh --models-only", commands["macos"])
        self.assertIn("RawLab/tests/adjustment-scale.sh", (ROOT / "scripts/ci/apple-models.sh").read_text())
        self.assertNotIn("test-without-building", commands["ios"])
        self.assertNotIn("connectedDebugAndroidTest", commands["android"])

    def test_presentation_model_mode_does_not_launch_canvas_ui(self):
        # Execute the actual script dispatch with compiler/native dependencies stubbed.
        source = (ROOT / "RawLabMac/tests/presentation.sh").read_text()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "RawLabMac/tests"
            tests.mkdir(parents=True)
            (tests / "presentation.sh").write_text(source)
            (tests / "native-env.sh").write_text("")
            for name in ("mac-viewing", "mac-canvas-input"):
                (tests / (name + ".sh")).write_text(f'echo {name} >> "$PROBE_LOG"\n')
            tools = root / "bin"
            tools.mkdir()
            compiler = tools / "swiftc"
            compiler.write_text('#!/bin/bash\nwhile [[ $# -gt 0 ]]; do if [[ "$1" == -o ]]; then shift; printf "#!/bin/sh\\nexit 0\\n" > "$1"; chmod +x "$1"; fi; shift; done\n')
            compiler.chmod(0o755)
            pkg = tools / "pkg-config"
            pkg.write_text('#!/bin/sh\necho /unused\n')
            pkg.chmod(0o755)
            log = root / "calls"
            for args, expected in ((["--models-only"], ["mac-viewing"]), ([], ["mac-viewing", "mac-canvas-input"])):
                log.unlink(missing_ok=True)
                result = subprocess.run(["bash", str(tests / "presentation.sh"), *args],
                    env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "PROBE_LOG": str(log)},
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(log.read_text().splitlines(), expected)

    def test_lut_contracts_include_the_adapter_dependencies(self):
        contracts = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["contracts"]["steps"])
        self.assertIn("pip install -r lutools/requirements-lutprep.txt", contracts)
        for suite in ("test_bundled_looks.py", "test_lut_source_audit.py", "test_prepare_bundled_looks.py"):
            self.assertIn("Shared/tests/" + suite, contracts)

    def test_fast_models_are_separate_from_native_builds_on_every_platform(self):
        for platform in PLATFORM_JOBS:
            steps = self.workflow["jobs"][platform]["steps"]
            models = [step for step in steps if "needs.changes.outputs.models" in step.get("if", "")]
            self.assertEqual(len(models), 1, platform)
            for command in ("native_cache.py", "build-framework.sh", "RawLabMac/build.sh", "RawLabWindows/build.ps1", "assembleDebug", "run-v08.ps1"):
                self.assertNotIn(command, models[0]["run"], platform)
            for step in steps:
                if step.get("id") in ("native-key", "native-cache") or "RAWLAB_CI_CACHE_HIT" in step.get("env", {}):
                    self.assertEqual(step.get("if"), "needs.changes.outputs.build == 'true'", platform)
        ios = self.workflow["jobs"]["ios"]["steps"]
        model = next(step for step in ios if "needs.changes.outputs.models" in step.get("if", ""))
        self.assertIn("bash scripts/ci/apple-models.sh ios", model["run"])
        build = next(step for step in ios if "build-for-testing" in step.get("run", ""))
        self.assertIn('if [[ "$RAWLAB_CI_NATIVE" == true ]]', build["run"])

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

    def test_macos_dcp_regressions_require_synthetic_python_parity(self):
        steps = self.workflow["jobs"]["macos"]["steps"]
        build = next(step for step in steps if "bash RawLabMac/build.sh" in step.get("run", ""))
        run = build["run"]
        self.assertEqual(build["if"], "needs.changes.outputs.build == 'true'")
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
                self.assertEqual(restore["if"], "needs.changes.outputs.build == 'true'")
                self.assertEqual(restore["continue-on-error"], "true")
                self.assertEqual(restore["with"]["lookup-only"], "${{ needs.changes.outputs.cold == 'true' }}")
                self.assertNotIn("restore-keys", restore["with"])
                self.assertEqual(restore["with"]["key"], "${{ steps.native-key.outputs.key }}")
                self.assertEqual(save["with"], {key: restore["with"][key] for key in ("key", "path")})
                shard = "(matrix.suite == 'all' || matrix.suite == 'core' || matrix.suite == 'build') && " if name == "macos" else ""
                self.assertEqual(save["if"], f"success() && {shard}steps.native-cache.outcome == 'success' && "
                                             "steps.native-cache.outputs.cache-hit != 'true'")
                self.assertLess(steps.index(restore), steps.index(save))
                builds = [step for step in steps if "run" in step and step.get('if') == "needs.changes.outputs.build == 'true'" and
                          any(command in step["run"] for command in
                              ("bash RawLabMac/build.sh", "./RawLabWindows/build.ps1", "./gradlew", "bash lutools/platform/ios/build-framework.sh"))]
                self.assertEqual(len(builds), 1)
                self.assertEqual(builds[0]["if"], "needs.changes.outputs.build == 'true'", "Only the requested check group, never a cache hit, may omit product builds")
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
        self.assertEqual(set(groups), {None, "core", "agent", "render", "model"})
        always = "\n".join(groups[None])
        for command in ("ci_timed app-build bash RawLabMac/build.sh", "native_cache.py inventory"):
            self.assertIn(command, always, "Every shard builds the app and records its cache inventory")
        expected = {
            "core": ("test_native_cache_xcode.py", "dcp-compiler.sh",
                     "look-library.sh", "look-import-model.sh", "ctest --test-dir lutools/build-macos"),
            "agent": ("agent-recipe-render.sh",),
            "render": ("raster-render.sh", "test_real_cli.py"),
            "model": ("batch-export.sh", "edit-model.sh", "presentation.sh", "usage-model.sh", "usage-termination.sh"),
        }
        for group, commands in expected.items():
            text = "\n".join(groups[group])
            for command in commands:
                with self.subTest(group=group, command=command):
                    self.assertIn(command, text)
        self.assertIn('in_suite() { [[ "$RAWLAB_CI_NATIVE" == true && ( "$RAWLAB_MAC_SUITE" == all || "$RAWLAB_MAC_SUITE" == "$1" ) ]]; }', always)
        suites = {row["arch"]: [] for row in macos_matrix("full")}
        for row in macos_matrix("full"):
            suites[row["arch"]].append(row["suite"])
        self.assertEqual(suites, {"arm64": ["all"], "x86_64": ["core", "agent", "render"]})

    def test_macos_shard_dispatch_preserves_every_render_check_once(self):
        run = next(step["run"] for step in self.workflow["jobs"]["macos"]["steps"]
                   if "bash RawLabMac/build.sh" in step.get("run", ""))
        expected = {
            "core": set(),
            "build": set(),
            "agent": {"agent-recipe-render"},
            "render": {"raster-render", "mcp-cli-parity"},
            "all": {"agent-recipe-render", "raster-render", "mcp-cli-parity"},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "bin"
            tools.mkdir()
            # Replace only platform tools; execute the actual workflow's shell control flow.
            for name in ("git", "sw_vers", "xcodebuild", "sysctl", "xcode-select", "xcrun",
                         "python", "bash", "ctest", "uv"):
                tool = tools / name
                tool.write_text('#!/bin/sh\ncase "${0##*/}" in xcode-select|xcrun) echo /test/sdk;; esac\n')
                tool.chmod(0o755)
            for suite, want in expected.items():
                with self.subTest(suite=suite):
                    timings = root / "build/ci/macos-timings.log"
                    timings.unlink(missing_ok=True)
                    env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                           "RAWLAB_MAC_SUITE": suite, "RAWLAB_ARCH": "x86_64", "RUNNER_TEMP": str(root),
                           "RAWLAB_CI_NATIVE": "false" if suite == "build" else "true"}
                    result = subprocess.run(["/bin/bash", "-euc", run], cwd=root, env=env,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    labels = [line.split("\t")[0] for line in timings.read_text().splitlines()]
                    self.assertEqual(labels.count("app-build"), 1)
                    render = [label for label in labels if label in expected["all"]]
                    self.assertEqual(set(render), want)
                    self.assertEqual(len(render), len(want), "A shard must not duplicate a render check")

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
