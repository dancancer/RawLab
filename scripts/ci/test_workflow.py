"""Semantic invariant guards for the hosted CI workflows."""
from pathlib import Path
import re
import sys
import unittest

import yaml

if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from affected_platforms import PLATFORMS, macos_matrix, windows_runner


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
CLEANUP = ROOT / ".github/workflows/pr-cache-cleanup.yml"
ACTIONLINT = ROOT / ".github/actionlint.yaml"
APPLE_MODELS = ROOT / "scripts/ci/apple-models.sh"
WINDOWS_MODELS = ROOT / "scripts/ci/windows-models.ps1"
STANDARD_HOSTED_PREFIXES = ("ubuntu-", "windows-", "macos-")
ALLOWED_ARTIFACT_EXTENSIONS = (".log", ".json", ".jsonl", ".xml")
NATIVE_BUILD_MARKERS = (
    "native_cache.py",
    "build-framework.sh",
    "RawLabMac/build.sh",
    "RawLabWindows/build.ps1",
    "assembleDebug",
    "run-v08.ps1",
)
UI_TEST_MARKERS = (
    "test-without-building",
    "connectedDebugAndroidTest",
    "hdr-rendition-ui.sh",
    "update-ui.sh",
    "offline.ps1",
    "horizontal-picker-native.sh",
    "mac-straighten-preview.sh",
    "parameter-value.sh",
    "mac-canvas-input.sh",
)


def _norm(value):
    return " ".join(str(value).split())


def _strip_expr(value):
    text = _norm(value)
    if text.startswith("${{") and text.endswith("}}"):
        return text[3:-2].strip()
    return text


def _needs_set(job):
    needs = job.get("needs", [])
    if isinstance(needs, str):
        return {needs}
    return set(needs)


def _non_comment_text(script):
    return "\n".join(line for line in script.splitlines() if not line.lstrip().startswith("#"))


def _ctest_invocations(run_script):
    joined = re.sub(r"\\\r?\n\s*", " ", run_script)
    invocations = []
    for raw_line in joined.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if re.search(r"(?:^|[;&|\s])ctest(?:\.exe)?\s+(?:--?[A-Za-z]|@\()", line):
            invocations.append(line)
    return invocations


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(WORKFLOW.is_file(), "Hosted CI workflow is missing")
        self.text = WORKFLOW.read_text(encoding="utf-8")
        # BaseLoader keeps GitHub's YAML 1.2 `on` key intact.
        self.workflow = yaml.load(self.text, Loader=yaml.BaseLoader)

    def test_events_do_not_publish(self):
        events = self.workflow["on"]
        self.assertEqual(set(events), {"pull_request", "push", "workflow_dispatch"})
        self.assertNotIn("tags", events["push"])
        self.assertNotIn("schedule", events)
        inputs = events["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["platform"]["options"], ["all", *PLATFORMS])
        self.assertEqual(inputs["checks"]["options"], ["contracts", "models", "build", "native", "full"])

        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertNotIn("secrets.", self.text)
        self.assertNotIn("environment", self.workflow)
        self.assertNotRegex(self.text, r"(?m)^\s*environment:")

        group = self.workflow["concurrency"]["group"]
        self.assertIn("github.event_name", group)
        self.assertIn("github.event.pull_request.number", group)
        self.assertIn("github.ref", group)

        for job in self.workflow["jobs"].values():
            self.assertNotIn("environment", job)
            self.assertNotIn("continue-on-error", job)
            for step in job["steps"]:
                if "continue-on-error" in step:
                    # Only cache restore steps may soft-fail and fall back to source download.
                    self.assertTrue(step.get("uses", "").startswith("actions/cache/restore@"))

    def test_pr_cache_cleanup_only_deletes_its_own_merge_ref(self):
        cleanup = yaml.load(CLEANUP.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        self.assertEqual(cleanup["on"], {"pull_request": {"types": ["closed"]}})
        self.assertEqual(cleanup["permissions"], {"actions": "write"})
        job = cleanup["jobs"]["cleanup"]
        self.assertEqual(_norm(job["if"]), "github.event.pull_request.head.repo.full_name == github.repository")
        self.assertEqual([step for step in job["steps"] if "uses" in step], [], "Do not run repository code")
        run_steps = [step for step in job["steps"] if "run" in step]
        self.assertEqual(len(run_steps), 1)
        step = run_steps[0]
        self.assertEqual(step["env"]["CACHE_REF"], "refs/pull/${{ github.event.pull_request.number }}/merge")
        self.assertIn("actions/caches?ref=$CACHE_REF", step["run"])
        self.assertEqual(step["run"].count("--method DELETE"), 1)

    def test_all_platforms_are_selected_bounded_and_gated(self):
        jobs = self.workflow["jobs"]
        self.assertEqual(set(jobs), {"changes", "contracts", *PLATFORMS, "windows-batch-selection", "result"})
        for name, job in jobs.items():
            with self.subTest(job=name):
                timeout = int(job["timeout-minutes"])
                self.assertGreater(timeout, 0)
                self.assertLessEqual(timeout, 180)
                if name == "changes":
                    self.assertEqual(job["permissions"], {"contents": "read", "actions": "read"})
                else:
                    self.assertNotIn("permissions", job)
                self.assertNotIn("self-hosted", str(job["runs-on"]))
                if name in PLATFORMS or name == "contracts":
                    self.assertIn("changes", _needs_set(job))
                    self.assertEqual(_strip_expr(job["if"]), f"needs.changes.outputs.{name} == 'true'")

        selection = jobs["changes"]
        self.assertTrue(
            {*PLATFORMS, "cold", "draft", "windows_runner", "mode", "scope",
             "checks", "contracts", "models", "build", "native", "macos_matrix"}.issubset(set(selection["outputs"]))
        )
        self.assertIn("affected_platforms.py select",
                      "\n".join(step.get("run", "") for step in selection["steps"]))

        for row in macos_matrix("full"):
            self.assertNotIn("self-hosted", str(row["runner"]))
        self.assertNotIn("self-hosted", windows_runner("pull_request", False, "full"))

        result = jobs["result"]
        self.assertEqual(_needs_set(result), set(jobs) - {"result"})
        result_if = _strip_expr(result["if"])
        self.assertIn("!cancelled()", result_if)
        self.assertIn("needs.changes.outputs.draft != 'true'", result_if)
        verify_steps = [step for step in result["steps"] if "affected_platforms.py verify" in step.get("run", "")]
        self.assertEqual(len(verify_steps), 1)
        self.assertEqual(verify_steps[0]["env"]["NEEDS"], "${{ toJSON(needs) }}")

    def test_actions_and_artifact_paths_are_constrained(self):
        for name, job in self.workflow["jobs"].items():
            uploads = []
            for step in job["steps"]:
                uses = step.get("uses")
                if not uses:
                    continue
                self.assertRegex(uses, r"^[^@]+@[0-9a-f]{40}$")
                if uses.startswith("actions/checkout@"):
                    self.assertEqual(step["with"]["persist-credentials"], "false")
                if uses.startswith("actions/upload-artifact@"):
                    uploads.append(step)
                    self.assertEqual(_strip_expr(step["if"]), "always()")
                    retention = int(step["with"]["retention-days"])
                    self.assertGreaterEqual(retention, 1)
                    self.assertLessEqual(retention, 30)
                    paths = [line.strip() for line in step["with"]["path"].splitlines() if line.strip()]
                    self.assertTrue(paths)
                    for path in paths:
                        self.assertTrue(path.startswith("build/ci/"), f"{name}: unsafe artifact path {path}")
                        self.assertNotIn("..", path.split("/"))
                        self.assertTrue(path.endswith(ALLOWED_ARTIFACT_EXTENSIONS),
                                        f"{name}: non-log/report artifact path {path}")
            if name in ("changes", "result"):
                self.assertEqual(uploads, [], name)
            else:
                self.assertGreaterEqual(len(uploads), 1, name)

    def test_actionlint_declares_custom_hosted_labels_without_legacy_self_hosted(self):
        self.assertTrue(ACTIONLINT.is_file(), "Declare custom labels for actionlint")
        policy = yaml.load(ACTIONLINT.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        labels = policy["self-hosted-runner"]["labels"]
        self.assertTrue(labels)
        for label in labels:
            self.assertFalse(label.startswith("rawlab-"), f"Legacy self-hosted label left in actionlint.yaml: {label}")
            self.assertNotEqual(label, "self-hosted")

        custom_runs_on = set()
        cleanup = yaml.load(CLEANUP.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        for workflow in (self.workflow, cleanup):
            for job in workflow["jobs"].values():
                runs_on = job["runs-on"]
                items = runs_on if isinstance(runs_on, list) else [runs_on]
                for item in items:
                    if not str(item).startswith("${{") and not str(item).startswith(STANDARD_HOSTED_PREFIXES):
                        custom_runs_on.add(str(item))
        for row in macos_matrix("full"):
            if not row["runner"].startswith(STANDARD_HOSTED_PREFIXES):
                custom_runs_on.add(row["runner"])
        win_runner = windows_runner("pull_request", False, "full")
        if not win_runner.startswith(STANDARD_HOSTED_PREFIXES):
            custom_runs_on.add(win_runner)
        self.assertTrue(custom_runs_on.issubset(set(labels)),
                        f"Missing custom runner labels in actionlint.yaml: {custom_runs_on - set(labels)}")

    def test_exact_native_caches_are_reused_except_by_cold_builds(self):
        for name in PLATFORMS:
            with self.subTest(job=name):
                steps = self.workflow["jobs"][name]["steps"]
                restores = [s for s in steps if s.get("uses", "").startswith("actions/cache/restore@")]
                saves = [s for s in steps if s.get("uses", "").startswith("actions/cache/save@")]

                native_restores = [s for s in restores if s.get("id") == "native-cache"]
                self.assertEqual(len(native_restores), 1)
                restore = native_restores[0]
                native_saves = [s for s in saves if s["with"].get("key") == restore["with"].get("key")]
                self.assertEqual(len(native_saves), 1)
                save = native_saves[0]

                self.assertEqual(_strip_expr(restore["if"]), "needs.changes.outputs.build == 'true'")
                self.assertEqual(restore.get("continue-on-error"), "true")
                self.assertEqual(_norm(restore["with"].get("lookup-only")),
                                 "${{ needs.changes.outputs.cold == 'true' }}")
                self.assertNotIn("restore-keys", restore["with"])
                self.assertEqual(save["with"], {k: restore["with"][k] for k in ("key", "path")})
                save_if = _strip_expr(save["if"])
                self.assertIn("success()", save_if)
                self.assertIn("steps.native-cache.outcome == 'success'", save_if)
                self.assertIn("steps.native-cache.outputs.cache-hit != 'true'", save_if)

                builds = [s for s in steps if "run" in s and _strip_expr(s.get("if", "")) == "needs.changes.outputs.build == 'true'"
                          and "RAWLAB_CI_CACHE_HIT" in s.get("env", {})]
                self.assertEqual(len(builds), 1)
                build = builds[0]
                cache_hit_expr = _norm(build["env"]["RAWLAB_CI_CACHE_HIT"])
                self.assertIn("needs.changes.outputs.cold != 'true'", cache_hit_expr)
                self.assertIn("steps.native-cache.outputs.cache-hit == 'true'", cache_hit_expr)
                self.assertLess(steps.index(restore), steps.index(build))
                self.assertLess(steps.index(build), steps.index(save))

                extra_restores = [s for s in restores if s is not restore]
                for extra in extra_restores:
                    self.assertEqual(extra.get("continue-on-error"), "true")
                    extra_id = extra["id"]
                    matching_saves = [s for s in saves if s["with"].get("key") == extra["with"].get("key")]
                    self.assertEqual(len(matching_saves), 1)
                    extra_save = matching_saves[0]
                    extra_save_if = _strip_expr(extra_save["if"])
                    self.assertIn("success()", extra_save_if)
                    self.assertIn(f"steps.{extra_id}.outcome == 'success'", extra_save_if)
                    self.assertIn(f"steps.{extra_id}.outputs.cache-hit != 'true'", extra_save_if)
                    self.assertLess(steps.index(extra), steps.index(build))
                    self.assertLess(steps.index(build), steps.index(extra_save))

    def test_fast_models_are_separate_from_native_builds_on_every_platform(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                steps = self.workflow["jobs"][platform]["steps"]
                model_steps = [s for s in steps if "needs.changes.outputs.models" in s.get("if", "")]
                self.assertEqual(len(model_steps), 1)
                model_run = model_steps[0]["run"]
                for marker in NATIVE_BUILD_MARKERS:
                    self.assertNotIn(marker, model_run)
                if platform in ("macos", "ios"):
                    self.assertIn("apple-models.sh", model_run)
                for step in steps:
                    if step.get("id") in ("native-key", "native-cache") or "RAWLAB_CI_CACHE_HIT" in step.get("env", {}):
                        self.assertEqual(_strip_expr(step.get("if", "")), "needs.changes.outputs.build == 'true'")

    def test_builds_are_not_feature_reduced_and_ui_stays_local(self):
        self.assertNotRegex(self.text, r"SONY2FUJI_ENABLE_\w+=OFF")
        self.assertNotRegex(self.text, r"RAWLAB_RUM_LOCAL[=: ]+['\"]?1")
        self.assertNotIn("-Test -SelfContained", self.text)

        sources = [
            *(_non_comment_text(step.get("run", ""))
              for job in self.workflow["jobs"].values()
              for step in job["steps"]),
            _non_comment_text(APPLE_MODELS.read_text(encoding="utf-8")),
            _non_comment_text(WINDOWS_MODELS.read_text(encoding="utf-8")),
        ]
        for source in sources:
            for ui_marker in UI_TEST_MARKERS:
                self.assertNotIn(ui_marker, source)

        for job in self.workflow["jobs"].values():
            for step in job["steps"]:
                for line in _non_comment_text(step.get("run", "")).splitlines():
                    if "presentation.sh" in line:
                        self.assertIn("--models-only", line)

    def test_ctest_never_silently_skips_and_hosted_ci_needs_no_private_dcp(self):
        invocations = []
        for job_name, job in self.workflow["jobs"].items():
            for step in job["steps"]:
                for invocation in _ctest_invocations(step.get("run", "")):
                    invocations.append((job_name, invocation))
                    self.assertIn("--no-tests=error", invocation, f"{job_name}: ctest missing --no-tests=error")
                    if job_name.startswith("windows"):
                        self.assertNotRegex(invocation, r"(?i)-C\s+['\"]?Debug['\"]?")
        self.assertGreaterEqual(len(invocations), 2)
        self.assertNotRegex(self.text, r"\bRAWLAB_TEST_(?:CANON_)?DCP\b",
                            "Hosted CI must not require private DCP profiles")

    def test_warp_regressions_require_an_explicit_windows_request(self):
        warp_steps = [
            step for step in self.workflow["jobs"]["windows"]["steps"]
            if "d3d11" in step.get("run", "") and "check-mutations.ps1" in step.get("run", "")
        ]
        self.assertEqual(len(warp_steps), 1)
        step = warp_steps[0]
        self.assertEqual(_strip_expr(step["if"]),
                         "github.event_name == 'workflow_dispatch' && inputs.platform == 'windows' && inputs.checks == 'models'")
        self.assertNotIn("continue-on-error", step)
        self.assertIn("--no-tests=error", step["run"])
        self.assertIn("$LASTEXITCODE", step["run"])

    def test_gpu_ai_inputs_are_gated_to_arm64_full_checks(self):
        mac_steps = [step for step in self.workflow["jobs"]["macos"]["steps"]
                     if "ai-inputs.py" in step.get("run", "")]
        self.assertEqual(len(mac_steps), 1)
        self.assertEqual(_strip_expr(mac_steps[0]["if"]), "needs.changes.outputs.checks == 'full' && matrix.arch == 'arm64'")
        full_matrix = macos_matrix("full")
        self.assertTrue(any(row["arch"] == "arm64" for row in full_matrix))
        self.assertTrue(any(row["arch"] == "x86_64" for row in full_matrix))

        win_steps = [step for step in self.workflow["jobs"]["windows"]["steps"]
                     if "ai-inputs.py" in step.get("run", "")]
        for step in win_steps:
            self.assertEqual(_strip_expr(step["if"]), "needs.changes.outputs.checks == 'full'")

    def test_batch_selection_is_an_isolated_automatic_hosted_job(self):
        job = self.workflow["jobs"]["windows-batch-selection"]
        self.assertIn("changes", _needs_set(job))
        self.assertNotIn("self-hosted", str(job["runs-on"]))
        self.assertEqual(_strip_expr(job["if"]),
                         "needs.changes.outputs.windows == 'true' && "
                         "needs.changes.outputs.mode == 'automatic' && "
                         "needs.changes.outputs.checks == 'models'")
        suite_steps = [step for step in job["steps"] if "run-v08.ps1" in step.get("run", "")]
        self.assertEqual(len(suite_steps), 1)
        suite = suite_steps[0]
        self.assertNotIn("if", suite)
        self.assertNotIn("continue-on-error", suite)
        self.assertRegex(suite["run"], r"-Only\s+['\"]batch-selection['\"]")


if __name__ == "__main__":
    unittest.main()
