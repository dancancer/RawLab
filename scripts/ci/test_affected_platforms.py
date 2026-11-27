"""Platform selection and result-gate regressions."""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.parse


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("affected_platforms", Path(__file__).with_name("affected_platforms.py"))
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)
EVERY = set(selection.PLATFORMS)


def pull(base="development", head="feature/x", draft=False, external=False, action=None, changes=None):
    event = {"pull_request": {"base": {"ref": base}, "head": {"ref": head}, "draft": draft}}
    if action is not None:
        event["action"] = action
    if changes is not None:
        event["changes"] = changes
    if external:
        event["pull_request"]["base"]["repo"] = {"full_name": "dancancer/RawLab"}
        event["pull_request"]["head"]["repo"] = {"full_name": "contributor/RawLab"}
    return event


def unavailable(*_):
    raise AssertionError("This event must not inspect history")


class ClassificationTests(unittest.TestCase):
    def test_client_directories_select_only_their_platform(self):
        for path, expected in (("RawLab/RawLab/Views/Editor.swift", {"ios"}),
                               ("RawLabMac/Sources/Editor/Model/EditorModel.swift", {"macos"}),
                               ("RawLabMac/build.sh", {"macos"}),
                               ("RawLabWindows/README.md", {"windows"}),
                               ("RawLabWindows/Directory.Build.props", {"windows"}),
                               ("RawLabWindows/.editorconfig", {"windows"}),
                               ("RawLabWindows/RawLabWindows.sln", {"windows"}),
                               ("global.json", {"windows"}),
                               ("RawLabAndroid/app/build.gradle.kts", {"android"})):
            with self.subTest(path=path):
                self.assertEqual(selection.platforms_for(path), expected)

    def test_files_other_clients_consume_select_them_too(self):
        for path in ("RawLabMac/Resources/FilmIcons/acros.png", "RawLabMac/Resources/Licenses/stb-MIT-LICENSE.txt",
                     "docs/reference/licensing.md", "lutools/docs/edit-json-v1.schema.json",
                     "lutools/docs/edit-json-v15.schema.json", "lutools/third_party/nikon_he/README.md",
                     "lutools/x3f-bridge/licenses/zune-core-0.4.12-LICENSE.md",
                     ".gitattributes", "LICENSE", "LICENSE-ALIYUN-RUM-EXCEPTION"):
            with self.subTest(path=path):
                self.assertEqual(selection.platforms_for(path), EVERY)
        self.assertEqual(selection.platforms_for("lutools/platform/ios/ThirdPartyNotices.md"), {"ios"})
        self.assertEqual(selection.platforms_for("RawLabMac/tests/DCPTestFixtures.swift"), {"macos", "ios"})
        self.assertEqual(selection.platforms_for("RawLabMac/tests/ax-gate.sh"), {"macos", "ios"})

    def test_shared_code_tooling_and_ci_workflows_select_every_platform(self):
        for path in ("lutools/src/core/raw_processor.cpp", "Shared/LookLibrary.swift",
                     "Shared/version.json", "scripts/version/generate.py",
                     "scripts/ci/native_cache.py", ".github/workflows/ci.yml",
                     ".github/workflows/pr-cache-cleanup.yml", ".github/actionlint.yaml",
                     "tests/test_localization.py"):
            with self.subTest(path=path):
                self.assertEqual(selection.platforms_for(path), EVERY)

    def test_documentation_bookkeeping_and_unclassified_select_no_platform(self):
        for path in ("docs/process/ci.md", "docs/luts/source-audit-2026-10-16.json",
                     "README.md", "CHANGELOG.md", "DESIGN.md", "PRODUCT.md", ".gitignore",
                     ".dsh-kanban.json", "AGENTS.md", "RawLab/AGENTS.md", "lutools/AGENTS.md", "CLAUDE.md",
                     ".impeccable/design.json",
                     "experiments/hamada-neural/runs/a.cube",
                     "tools/camera-transfer/cmd/rawlab-camera/main.go",
                     "tools/mcp/README.md", "tools/mcp/src/rawlab_mcp/server.py",
                     ".github/PULL_REQUEST_TEMPLATE.md",
                     ".github/CODEOWNERS", ".github/ISSUE_TEMPLATE/bug.yml",
                     "lutools/README.md", "lutools/PROJECT_SUMMARY.md", "lutools/docs/color-contract.md",
                     "lutools/platform/ios/README.md",
                     "lutools/tools/dualdn/README.md", "lutools/x3f-bridge/README.md",
                     "lutools/x3f-bridge/vendor/x3f-sys/RAWLAB.md",
                     "lutools/x3f-bridge/vendor/x3f-sys/README.md",
                     "lutools/tests/fixtures/README.md", "lutools/tests/fixtures/hdr/README.md",
                     "lutools/tests/hdr_codec/README.md", "pyproject.toml",
                     "new-top-level/file", "notes.txt"):
            with self.subTest(path=path):
                self.assertEqual(selection.platforms_for(path), set())

    def test_other_clients_only_consume_classified_mac_files(self):
        """Fail when another client starts reading a Mac file that only selects the Mac check."""
        consumers = {"RawLabMac/": ("RawLab/", "RawLabWindows/", "RawLabAndroid/", "lutools/platform/ios/")}
        listed = subprocess.check_output(["git", "grep", "-lE", r"RawLabMac/[A-Za-z]",
                                          "--", *consumers["RawLabMac/"]], cwd=ROOT, text=True).split()
        references = subprocess.check_output(["git", "grep", "-hoE", r"RawLabMac/[A-Za-z][A-Za-z0-9_./-]*",
                                              "--", *listed], cwd=ROOT, text=True).split()
        for reference in sorted(set(references)):
            with self.subTest(reference=reference):
                # A reference may name the shared directory itself, without a trailing slash.
                self.assertTrue(f"{reference.rstrip('/')}/".startswith(selection.SHARED_MAC_PREFIXES)
                                or reference in selection.MAC_AND_IOS_FILES, reference)


class SelectionTests(unittest.TestCase):
    def test_manual_platform_and_group_are_explicit(self):
        for platform in ("all", *selection.PLATFORMS):
            for checks in selection.CHECK_GROUPS:
                event = {"inputs": {"platform": platform, "checks": checks}}
                result = selection.select("workflow_dispatch", event, "s", unavailable, unavailable)
                chosen = set() if checks == "contracts" else EVERY if platform == "all" else {platform}
                self.assertEqual(result[:3], (chosen, checks == "full", False))
                config = selection.configuration("workflow_dispatch", event)
                self.assertEqual(config["mode"], "manual")
                self.assertEqual(config["contracts"], checks == "contracts" or (platform == "all" and checks == "full"))
        for inputs in ({"platform": "typo"}, {"checks": "ui"}, {"checks": ""}):
            with self.assertRaises(ValueError):
                selection.configuration("workflow_dispatch", {"inputs": inputs})

    def test_ordinary_events_are_models_and_release_prs_are_full(self):
        for event_name, event in (("pull_request", pull()), ("push", {})):
            self.assertEqual(selection.configuration(event_name, event)["checks"], "models")
        for base, head in (("main", "release/1.0"), ("development", "hotfix/crash"), ("release/1.0", "fix/x")):
            self.assertEqual(selection.configuration("pull_request", pull(base, head))["checks"], "full")

    def test_pull_requests_select_changed_platforms_and_reuse_caches(self):
        files = {"HEAD^1": ["RawLab/RawLab/App.swift", "docs/process/ci.md"]}
        platforms, cold, draft, _ = selection.select("pull_request", pull(), "s", files.__getitem__, unavailable)
        self.assertEqual((platforms, cold, draft), ({"ios"}, False, False))

    def test_apple_spm_files_select_macos_and_ios(self):
        for path in ("Package.swift", "tests/RawLabKitTests/HDRTransferTests.swift"):
            with self.subTest(path=path):
                self.assertEqual(selection.affected([path]), {"macos", "ios"})

    def test_docs_and_bookkeeping_pull_request_runs_only_contracts(self):
        files = {"HEAD^1": [
            ".dsh-kanban.json",
            "docs/process/ci.md",
            "lutools/README.md",
            "experiments/hamada-neural/runs/a.cube",
            "tools/mcp/README.md",
            "pyproject.toml",
            "new-top-level/notes.txt",
        ]}
        platforms, cold, draft, _ = selection.select("pull_request", pull(), "s", files.__getitem__, unavailable)
        config = selection.configuration("pull_request", pull())
        self.assertEqual((platforms, cold, draft), (set(), False, False))
        self.assertTrue(config["contracts"])
        needs = VerifyTests().needs(platforms, dict.fromkeys(selection.PLATFORMS, "skipped"))
        self.assertEqual(selection.verify(needs), [])

    def test_drafts_defer_platform_checks(self):
        platforms, _, draft, _ = selection.select("pull_request", pull(draft=True), "s", unavailable, unavailable)
        self.assertEqual((platforms, draft), (set(), True))

    def test_edited_pull_request_reselects_only_when_base_changed(self):
        # Title/body edits never reach select(); main() routes them (EditSelectionOutputTests).
        self.assertTrue(selection.is_description_edit("pull_request", pull(action="edited", changes={"title": {"from": "old"}})))

        to_main = pull(base="main", action="edited", changes={"base": {"ref": {"from": "development"}}})
        self.assertEqual(
            selection.select("pull_request", to_main, "s", unavailable, unavailable)[:3],
            (EVERY, True, False),
        )
        self.assertEqual(selection.configuration("pull_request", to_main)["checks"], "full")

        files = {"HEAD^1": ["RawLab/RawLab/App.swift"]}
        to_dev = pull(base="development", action="edited", changes={"base": {"ref": {"from": "release/0.10.0"}}})
        self.assertEqual(
            selection.select("pull_request", to_dev, "s", files.__getitem__, unavailable)[:3],
            ({"ios"}, False, False),
        )
        self.assertEqual(selection.configuration("pull_request", to_dev)["checks"], "models")

        ext_to_main = pull(base="main", external=True, action="edited", changes={"base": {"ref": {"from": "development"}}})
        self.assertEqual(selection.configuration("pull_request", ext_to_main)["checks"], "models")

    def test_release_and_hotfix_pull_requests_run_everything_cold(self):
        for base, head in (("main", "release/0.9.0"), ("main", "hotfix/crash"),
                           ("development", "release/0.9.0"), ("release/0.9.0", "fix/x")):
            with self.subTest(base=base, head=head):
                result = selection.select("pull_request", pull(base, head), "s", unavailable, unavailable)
                self.assertEqual(result[:3], (EVERY, True, False))

    def test_external_branch_names_never_trigger_a_cold_full_build(self):
        # 一个 fork 里叫 hotfix/* 的分支不能因为名字就要求全量冷构建。
        for base, head in (("main", "hotfix/crash"), ("development", "release/0.9.0")):
            with self.subTest(base=base, head=head):
                external = selection.configuration("pull_request", pull(base, head, external=True))
                internal = selection.configuration("pull_request", pull(base, head))
                self.assertEqual(external["checks"], "models")
                self.assertEqual(internal["checks"], "full")

    def test_fork_pull_requests_select_the_same_hosted_platforms(self):
        for path in ("Shared/RawLabKit/AdjustmentTransfer.swift", "RawLab/RawLab/App.swift", "RawLabMac/build.sh"):
            with self.subTest(path=path):
                files = {"HEAD^1": [path]}
                internal, _, _, _ = selection.select("pull_request", pull(), "s", files.__getitem__, unavailable)
                external, cold, _, _ = selection.select("pull_request", pull(external=True), "s", files.__getitem__, unavailable)
                self.assertEqual(external, internal)
                self.assertEqual(external, selection.affected([path]))
                self.assertFalse(cold)

    def test_fork_pull_request_leaves_a_consistent_verify_result(self):
        files = {"HEAD^1": ["Shared/RawLabKit/AdjustmentTransfer.swift"]}
        platforms, _, _, _ = selection.select("pull_request", pull(external=True), "s", files.__getitem__, unavailable)
        self.assertEqual(platforms, EVERY)
        results = {platform: "success" for platform in selection.PLATFORMS}
        needs = VerifyTests().needs(platforms, results)
        self.assertEqual(selection.verify(needs), [])
        for platform in ("macos", "ios"):
            needs[platform]["result"] = "skipped"
            self.assertTrue(selection.verify(needs), "a selected hosted Apple check must not silently skip")
            needs[platform]["result"] = "success"

    def test_pushes_compare_with_the_last_successful_push_run(self):
        seen = []
        def files(base):
            seen.append(base)
            return ["RawLabAndroid/app/src/main/A.kt"]
        result = selection.select("push", {}, "new", files, {"push": "verified"}.get)
        self.assertEqual(result[:3], ({"android"}, False, False))
        self.assertEqual(seen, ["verified"])

    def test_missing_history_runs_every_platform(self):
        def broken(_):
            raise subprocess.CalledProcessError(128, "git fetch")
        for files, last in ((broken, {"push": "old"}.get), (unavailable, {}.get)):
            with self.subTest(files=files):
                self.assertEqual(selection.select("push", {}, "s", files, last)[0], EVERY)
        self.assertEqual(selection.select("pull_request", pull(), "s", broken, unavailable)[0], EVERY)

    def test_no_scheduled_full_run_and_manual_defaults_to_models(self):
        with self.assertRaises(ValueError):
            selection.select("schedule", {}, "s", unavailable, unavailable)
        self.assertEqual(selection.select("workflow_dispatch", {}, "s", unavailable, unavailable)[:2], (EVERY, False))

    def test_mac_matrix_preserves_native_architectures_on_hosted_runners(self):
        for checks in selection.CHECK_GROUPS:
            rows = selection.macos_matrix(checks)
            self.assertEqual(rows[0], {"runner": "macos-26", "arch": "arm64", "jobs": "2", "suite": "all"})
            for row in rows[1:]:
                self.assertEqual(row["runner"], "macos-26-intel")
                self.assertEqual(row["arch"], "x86_64")
                self.assertEqual(row["jobs"], "4")

    def test_mac_matrix_runs_models_once_and_builds_once_per_architecture(self):
        self.assertEqual([(r["arch"], r["suite"]) for r in selection.macos_matrix("models")], [("arm64", "all")])
        self.assertEqual([(r["arch"], r["suite"]) for r in selection.macos_matrix("build")], [("arm64", "all"), ("x86_64", "build")])
        self.assertEqual([(r["arch"], r["suite"]) for r in selection.macos_matrix("native")],
            [("arm64", "all"), ("x86_64", "core"), ("x86_64", "agent"), ("x86_64", "render")])
        # The cold full gate builds x86_64 once; one job runs every Intel suite.
        self.assertEqual([(r["arch"], r["suite"]) for r in selection.macos_matrix("full")],
            [("arm64", "all"), ("x86_64", "intel")])


class WindowsSchedulingTests(unittest.TestCase):
    def test_every_windows_group_uses_hosted_windows(self):
        for event in ("pull_request", "push", "workflow_dispatch"):
            for cold in (False, True):
                for checks in selection.CHECK_GROUPS:
                    with self.subTest(event=event, cold=cold, checks=checks):
                        self.assertEqual(selection.windows_runner(event, cold, checks), "windows-2022")

    def test_selection_cli_emits_a_json_runner_for_the_workflow(self):
        for event_name, event, want in (
            ("pull_request", pull(), "windows-2022"),
            ("pull_request", pull("main", "release/0.9.0"),
             "windows-2022"),
            ("workflow_dispatch", {}, "windows-2022"),
            ("workflow_dispatch", {"inputs": {"platform": "windows", "checks": "full"}},
             "windows-2022"),
        ):
            with self.subTest(event=event_name, payload=event), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                payload, output = root / "event.json", root / "output"
                payload.write_text(json.dumps(event))
                result = subprocess.run(
                    [os.sys.executable, str(ROOT / "scripts/ci/affected_platforms.py"), "select"],
                    cwd=ROOT, env={**os.environ, "GITHUB_EVENT_NAME": event_name,
                                   "GITHUB_EVENT_PATH": str(payload), "GITHUB_OUTPUT": str(output),
                                   "GITHUB_SHA": "current", "GITHUB_STEP_SUMMARY": ""},
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                values = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertIn("windows_runner", values)
                self.assertEqual(json.loads(values["windows_runner"]), want)
                self.assertEqual(values["mode"], "manual" if event_name == "workflow_dispatch" else "automatic")
                config = selection.configuration(event_name, event)
                self.assertEqual(values["checks"], config["checks"])
                self.assertEqual(values["build"], "false" if config["checks"] == "models" else "true")
                self.assertEqual(values["models"], "true")


class DescriptionEditTests(unittest.TestCase):
    """A title/body edit run is the newest run on the head, so it must restate the head's real verdict."""

    @staticmethod
    def workflow_run(run_id, status, *jobs, conclusion=None):
        return ({"id": run_id, "status": status, "conclusion": conclusion},
                [{"name": name, "status": job_status, "conclusion": job_conclusion}
                 for name, job_status, job_conclusion in jobs])

    def reference(self, *runs, own_id=100):
        jobs = {run["id"]: run_jobs for run, run_jobs in runs}
        return selection.edit_reference([run for run, _ in runs], lambda run: jobs[run["id"]], own_id)

    SELECTED = (selection.SELECT_JOB, "completed", "success")
    EDIT = (selection.EDIT_JOB, "completed", "success")

    def test_only_title_and_body_edits_reuse_the_head_result(self):
        self.assertTrue(selection.is_description_edit("pull_request", pull(action="edited", changes={"body": {"from": ""}})))
        self.assertFalse(selection.is_description_edit(
            "pull_request", pull(action="edited", changes={"base": {"ref": {"from": "development"}}})))
        self.assertFalse(selection.is_description_edit("pull_request", pull(action="synchronize")))
        self.assertFalse(selection.is_description_edit("push", {}))

    def test_edit_after_a_passing_run_reports_that_result(self):
        for conclusion in ("success", "failure", "cancelled"):
            with self.subTest(conclusion=conclusion):
                automatic = self.workflow_run(10, "completed", self.SELECTED, (selection.RESULT_JOB, "completed", conclusion))
                earlier_edit = self.workflow_run(11, "completed", self.EDIT, (selection.RESULT_JOB, "completed", "success"))
                pre_change_edit = self.workflow_run(12, "completed", (selection.SELECT_JOB, "completed", "skipped"))
                self.assertEqual(self.reference(automatic, earlier_edit, pre_change_edit), conclusion)

    def test_edit_waits_while_the_automatic_run_is_unfinished(self):
        not_started = self.workflow_run(10, "queued")
        running = self.workflow_run(10, "in_progress", self.SELECTED, ("Android models", "in_progress", None))
        for automatic in (not_started, running):
            with self.subTest(jobs=len(automatic[1])):
                self.assertIsNone(self.reference(automatic))

    def test_newest_automatic_run_decides_even_after_an_older_pass(self):
        older_pass = self.workflow_run(10, "completed", self.SELECTED, (selection.RESULT_JOB, "completed", "success"))
        base_change = self.workflow_run(20, "in_progress", self.SELECTED)
        self.assertIsNone(self.reference(older_pass, base_change))
        failed = self.workflow_run(20, "completed", self.SELECTED, (selection.RESULT_JOB, "completed", "failure"))
        self.assertEqual(self.reference(older_pass, failed), "failure")

    def test_missing_or_never_reported_results_are_not_a_pass(self):
        draft_run = self.workflow_run(10, "completed", self.SELECTED)
        self.assertEqual(self.reference(draft_run), "missing")
        self.assertEqual(self.reference(), "missing")
        cancelled_before_start = self.workflow_run(11, "completed", conclusion="cancelled")
        self.assertEqual(self.reference(cancelled_before_start), "missing")
        later_run = self.workflow_run(150, "completed", self.SELECTED, (selection.RESULT_JOB, "completed", "success"))
        self.assertEqual(self.reference(later_run), "missing")

    # The selection job's name is an expression; a run cancelled before it was named lists it unexpanded.
    UNNAMED = ("${{ github.event_name == 'pull_request' && 'x' || 'y' }}", "completed", "cancelled")

    def test_superseded_runs_cancelled_before_start_are_passed_over(self):
        older_pass = self.workflow_run(10, "completed", self.SELECTED, (selection.RESULT_JOB, "completed", "success"))
        for jobs in ((), (self.UNNAMED,)):
            with self.subTest(jobs=len(jobs)):
                cancelled = self.workflow_run(20, "completed", *jobs, conclusion="cancelled")
                self.assertEqual(self.reference(older_pass, cancelled), "success")

    def test_runs_that_never_started_otherwise_fail_closed(self):
        # A fork PR retargeted to main waits for approval (action_required, no jobs); an
        # approved edit run must not restate the older pass on the previous base.
        older_pass = self.workflow_run(10, "completed", self.SELECTED, (selection.RESULT_JOB, "completed", "success"))
        for conclusion, expected in (("action_required", "not started (action_required)"),
                                     ("startup_failure", "not started (startup_failure)"),
                                     ("stale", "not started (stale)"), (None, "not started (None)"),
                                     ("success", "not started (success)")):
            for jobs in ((), (self.UNNAMED[:2] + (conclusion,),)):
                with self.subTest(conclusion=conclusion, jobs=len(jobs)):
                    never_ran = self.workflow_run(20, "completed", *jobs, conclusion=conclusion)
                    self.assertEqual(self.reference(older_pass, never_ran), expected)
        unnamed_running = self.workflow_run(20, "in_progress", (self.UNNAMED[0], "queued", None))
        self.assertIsNone(self.reference(older_pass, unnamed_running))

    def needs(self, reference, **results):
        outputs = {platform: "false" for platform in selection.PLATFORMS}
        outputs.update(mode="edit", contracts="false", reference=reference)
        jobs = {"changes": "success", "contracts": "skipped", "windows-batch-selection": "skipped",
                **{platform: "skipped" for platform in selection.PLATFORMS}, **results}
        return {job: {"result": result, **({"outputs": outputs} if job == "changes" else {})}
                for job, result in jobs.items()}

    def test_edit_gate_passes_only_on_the_reused_success(self):
        self.assertEqual(selection.verify(self.needs("success")), [])
        for reference in ("failure", "cancelled", "missing", "still pending", ""):
            with self.subTest(reference=reference):
                self.assertTrue(selection.verify(self.needs(reference)))
        self.assertTrue(selection.verify(self.needs("success", android="success")))
        self.assertTrue(selection.verify(self.needs("success", changes="failure")))


class EditPollingTests(unittest.TestCase):
    """github_edit_reference against a scripted API and clock; no network."""

    PULL = {"number": 42, "head": {"sha": "abc", "ref": "feature/x"}}

    def api(self, runs, jobs, error=None):
        calls = []
        def get(path):
            calls.append(path)
            if error:
                raise error
            if "/jobs" in path:
                run_id = int(path.split("actions/runs/")[1].split("/")[0])
                return {"jobs": jobs(run_id) if callable(jobs) else jobs[run_id]}
            return {"workflow_runs": runs() if callable(runs) else runs}
        return get, calls

    def clock(self):
        now = [0.0]
        return (lambda: now[0]), (lambda seconds: now.__setitem__(0, now[0] + seconds))

    def poll(self, get, limit_minutes=10):
        clock, sleep = self.clock()
        with contextlib.redirect_stdout(io.StringIO()):
            return selection.github_edit_reference(self.PULL, 100, "ci.yml", get=get, clock=clock, sleep=sleep,
                                                   limit_minutes=limit_minutes)

    @staticmethod
    def workflow_run(run_id, status="completed", conclusion="success", pulls=(42,), branch="feature/x", attempt=1):
        return {"id": run_id, "status": status, "conclusion": conclusion, "run_attempt": attempt,
                "pull_requests": [{"number": number} for number in pulls], "head_branch": branch}

    @staticmethod
    def jobs(result):
        return [{"name": selection.SELECT_JOB, "status": "completed", "conclusion": "success"},
                {"name": selection.RESULT_JOB, "status": "completed", "conclusion": result}]

    def test_only_runs_of_this_pull_request_count(self):
        runs = [self.workflow_run(10), self.workflow_run(20, pulls=(7,)), self.workflow_run(30, pulls=(), branch="contributor:other")]
        jobs = {10: self.jobs("failure"), 20: self.jobs("success"), 30: self.jobs("success")}
        self.assertEqual(self.poll(self.api(runs, jobs)[0]), "failure")
        fork_run = [self.workflow_run(10), self.workflow_run(30, pulls=())]
        self.assertEqual(self.poll(self.api(fork_run, {10: self.jobs("failure"), 30: self.jobs("success")})[0]), "success")

    def test_lookup_errors_and_timeouts_never_pass(self):
        import urllib.error
        failing, calls = self.api([], {}, error=urllib.error.URLError("unreachable"))
        self.assertEqual(self.poll(failing), "still pending")
        self.assertGreater(len(calls), 1)
        running = [self.workflow_run(10, status="in_progress", conclusion=None)]
        pending, _ = self.api(running, {10: [{"name": selection.SELECT_JOB, "status": "completed", "conclusion": "success"}]})
        self.assertEqual(self.poll(pending), "still pending")

    def test_a_transient_error_is_retried(self):
        outcomes = [urllib_error(), None]
        def get(path):
            if outcomes and outcomes.pop(0):
                raise urllib_error()
            if "/jobs" in path:
                return {"jobs": self.jobs("success")}
            return {"workflow_runs": [self.workflow_run(10)]}
        self.assertEqual(self.poll(get), "success")

    def test_a_rerun_attempt_is_fetched_again(self):
        # Run 11 is first cancelled before start (skipped, its empty job list cached); a rerun
        # makes attempt 2 the newest automatic result, which must be fetched rather than reused.
        rounds = []
        def runs():
            rounds.append(None)
            rerun = len(rounds) > 2
            return [self.workflow_run(10, status="in_progress", conclusion=None),
                    self.workflow_run(11, conclusion="success" if rerun else "cancelled", attempt=2 if rerun else 1)]
        def jobs(run_id):
            if run_id == 10:
                return self.jobs("failure")[:1]
            return self.jobs("success") if len(rounds) > 2 else []
        get, calls = self.api(runs, jobs)
        self.assertEqual(self.poll(get), "success")
        self.assertEqual(len([path for path in calls if "runs/11/jobs" in path]), 2)

    def test_requests_do_not_grow_with_earlier_edits(self):
        edits = 7
        rounds = []
        def runs():
            rounds.append(None)
            done = len(rounds) > 20
            automatic = self.workflow_run(10, status="completed" if done else "in_progress", conclusion="success" if done else None)
            return [automatic] + [self.workflow_run(11 + index, conclusion="cancelled") for index in range(edits)]
        def jobs(run_id):
            if run_id != 10:
                return [{"name": selection.EDIT_JOB, "status": "completed", "conclusion": "cancelled"}]
            return self.jobs("success") if len(rounds) > 20 else self.jobs("success")[:1]
        get, calls = self.api(runs, jobs)
        self.assertEqual(self.poll(get, limit_minutes=60), "success")
        job_calls = [path for path in calls if "/jobs" in path]
        # Each earlier edit run's jobs are fetched once; afterwards a round costs one runs and one jobs request.
        self.assertEqual(len(job_calls), edits + len(rounds))
        self.assertEqual(len(calls), edits + 2 * len(rounds))


def urllib_error():
    import urllib.error
    return urllib.error.URLError("transient")


class EditPollingDefaultTransportTests(unittest.TestCase):
    """github_edit_reference with its production GitHub client; only urlopen is stubbed, no network."""

    PULL = EditPollingTests.PULL
    TOKEN = "fake-token-for-tests"
    ENV = {"GITHUB_API_URL": "https://ghe.example.test/api/v3", "GITHUB_REPOSITORY": "o/r", "GITHUB_TOKEN": TOKEN}

    def poll(self, urlopen, env=None):
        now = [0.0]
        stdout = io.StringIO()
        # clear=True: the client may only see what this test puts in the environment.
        with mock.patch.dict(os.environ, env or self.ENV, clear=True), \
                mock.patch.object(selection.urllib.request, "urlopen", urlopen), \
                contextlib.redirect_stdout(stdout):
            result = selection.github_edit_reference(
                self.PULL, 100, "ci.yml", clock=lambda: now[0],
                sleep=lambda seconds: now.__setitem__(0, now[0] + seconds), limit_minutes=10)
        self.assertNotIn(self.TOKEN, stdout.getvalue())
        return result

    def api(self, jobs_result="failure"):
        requests = []
        def urlopen(request, timeout=None):
            requests.append((request, timeout))
            path = urllib.parse.urlsplit(request.full_url).path
            if path.endswith("/jobs"):
                payload = {"jobs": EditPollingTests.jobs(jobs_result)}
            else:
                payload = {"workflow_runs": [EditPollingTests.workflow_run(10)]}
            return io.BytesIO(json.dumps(payload).encode())
        return urlopen, requests

    def test_default_client_calls_the_repository_actions_api_with_the_environment_token(self):
        urlopen, requests = self.api("failure")
        # The verdict comes only from the decoded JSON bodies, so "failure" proves they were parsed.
        self.assertEqual(self.poll(urlopen), "failure")
        self.assertEqual(len(requests), 2)
        for request, timeout in requests:
            self.assertEqual(request.get_method(), "GET")
            self.assertEqual(request.get_header("Authorization"), f"Bearer {self.TOKEN}")
            self.assertEqual(request.get_header("Accept"), "application/vnd.github+json")
            self.assertTrue(timeout and timeout > 0, "a GitHub request must not wait forever")
        runs, jobs = (urllib.parse.urlsplit(request.full_url) for request, _ in requests)
        self.assertEqual((runs.scheme, runs.netloc, runs.path),
                         ("https", "ghe.example.test", "/api/v3/repos/o/r/actions/workflows/ci.yml/runs"))
        self.assertEqual(urllib.parse.parse_qs(runs.query),
                         {"head_sha": ["abc"], "event": ["pull_request"], "per_page": ["100"]})
        self.assertEqual((jobs.netloc, jobs.path), ("ghe.example.test", "/api/v3/repos/o/r/actions/runs/10/jobs"))
        self.assertEqual(urllib.parse.parse_qs(jobs.query), {"per_page": ["100"]})

    def test_default_client_uses_the_public_api_without_an_override(self):
        urlopen, requests = self.api("success")
        env = {key: value for key, value in self.ENV.items() if key != "GITHUB_API_URL"}
        self.assertEqual(self.poll(urlopen, env), "success")
        self.assertEqual({urllib.parse.urlsplit(request.full_url)[:2] for request, _ in requests},
                         {("https", "api.github.com")})
        self.assertTrue(all(urllib.parse.urlsplit(request.full_url).path.startswith("/repos/o/r/actions/")
                            for request, _ in requests))

    def test_http_transport_and_decoding_errors_fail_closed(self):
        import urllib.error
        url = "https://ghe.example.test/api/v3/repos/o/r/actions/workflows/ci.yml/runs"
        failures = {
            "http 401": urllib.error.HTTPError(url, 401, "Bad credentials", {}, None),
            "http 503": urllib.error.HTTPError(url, 503, "Service Unavailable", {}, None),
            "transport": urllib.error.URLError("connection refused"),
            "timeout": TimeoutError("timed out"),
        }
        for label, error in failures.items():
            with self.subTest(label):
                calls = []
                def urlopen(request, timeout=None, error=error):
                    calls.append(request)
                    raise error
                self.assertEqual(self.poll(urlopen), "still pending")
                self.assertGreater(len(calls), 1, "a failed lookup is retried until the deadline")
        with self.subTest("not json"):
            self.assertEqual(self.poll(lambda request, timeout=None: io.BytesIO(b"<html>rate limited</html>")),
                             "still pending")


class EditSelectionOutputTests(unittest.TestCase):
    """The edit path of `select` mode: no checks are selected; only the reused result is reported."""

    def outputs(self, event, reference="success"):
        with tempfile.TemporaryDirectory() as directory:
            event_path, output_path = Path(directory, "event.json"), Path(directory, "output")
            event_path.write_text(json.dumps(event))
            env = {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_EVENT_PATH": str(event_path),
                   "GITHUB_OUTPUT": str(output_path), "GITHUB_RUN_ID": "100", "GITHUB_SHA": "m",
                   "GITHUB_WORKFLOW_REF": "o/r/.github/workflows/ci.yml@refs/pull/1/merge"}
            calls = []
            def lookup(pull, own_id, workflow):
                calls.append((own_id, workflow))
                return reference
            original, argv, saved = selection.github_edit_reference, sys.argv, {k: os.environ.get(k) for k in env}
            selection.github_edit_reference, sys.argv = lookup, ["affected_platforms.py", "select"]
            os.environ.update(env)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(selection.main(), 0)
            finally:
                selection.github_edit_reference, sys.argv = original, argv
                for key, value in saved.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value
            values = dict(line.split("=", 1) for line in output_path.read_text().splitlines())
            return values, calls

    def test_title_or_body_edit_selects_no_checks(self):
        values, calls = self.outputs(pull(action="edited", changes={"title": {"from": "old"}}))
        self.assertEqual(calls, [(100, "ci.yml")])
        self.assertEqual({key: values[key] for key in (*selection.PLATFORMS, "contracts", "draft", "mode", "reference")},
                         {**{platform: "false" for platform in selection.PLATFORMS}, "contracts": "false",
                          "draft": "false", "mode": "edit", "reference": "success"})

    def test_draft_edit_stays_skipped_without_a_lookup(self):
        values, calls = self.outputs(pull(draft=True, action="edited", changes={"body": {"from": ""}}))
        self.assertEqual(calls, [])
        self.assertEqual((values["draft"], values["reference"], values["mode"]), ("true", "draft", "edit"))


class CoreCtestSelectionTests(unittest.TestCase):
    """Core-touching automatic models runs add one arm64 core CTest row; nothing else does."""

    CORE = ("lutools/src/core/pipeline.cpp", "lutools/include/sony2fuji_c_api.h", "lutools/tests/viewport_roi_tests.cpp",
            "lutools/CMakeLists.txt", "lutools/cmake/lens-dependencies.json", "lutools/examples/DJI_20250602164503_0444_D.DNG",
            "lutools/docs/edit-json-v3.schema.json", "lutools/x3f-bridge/Cargo.lock", "lutools/lutprep/dcp.py",
            "lutools/requirements-lutprep.txt", "lutools/third_party/lensfun/README.md",
            "Shared/BundledLooks/HDR/HDR Silver.cube", "Shared/assets-manifest.json", "scripts/assets/prepare.py",
            "scripts/ci/test_abi_layout.py", "scripts/ci/check_ctest_inventory.py", "scripts/ci/requirements.txt",
            "scripts/ci/apple-sdk-env.sh", "scripts/ci/prepare-rust.sh", "scripts/ci/native_cache.py",
            "RawLabMac/build.sh", "RawLabMac/build-env.sh", "RawLabMac/release-config.sh",
            "RawLabMac/build-dependencies.sh", "RawLabMac/build-lens-dependency.sh")
    NOT_CORE = ("lutools/README.md", "lutools/PROJECT_SUMMARY.md", "lutools/AGENTS.md", "lutools/docs/color-contract.md",
                "lutools/tests/README.md", "lutools/x3f-bridge/NOTES.md", "lutools/platform/ios/build-framework.sh",
                "lutools/platform/ios/ThirdPartyNotices.md", "RawLabMac/Sources/Editor/Model/EditorModel.swift",
                "RawLabMac/build-icon.sh", "RawLabMac/sign-bundle.sh", "RawLabMac/tests/edit-model.sh",
                "RawLab/RawLab/App.swift", "RawLabWindows/README.md", "RawLabAndroid/app/build.gradle.kts",
                "Shared/specs/adjustments.json", "Shared/RawLabKit/Edit.swift", "scripts/ci/affected_platforms.py",
                ".github/workflows/ci.yml", "docs/process/ci.md", "README.md", "tools/mcp/server.py",
                # RAWLAB_CORE_ONLY skips Sparkle and usage-SDK preparation, so the row never runs these.
                "RawLabMac/prepare-sparkle.sh", "scripts/rum/prepare-macos.sh", "scripts/rum/shared-cache.sh")

    def test_core_inputs_are_exactly_what_feeds_the_core_ctest_build(self):
        for path in self.CORE:
            with self.subTest(path=path):
                self.assertTrue(selection.is_core_path(path))
                # A core change always selects macOS, so the row can never be dropped with its platform.
                self.assertIn("macos", selection.platforms_for(path))
        for path in self.NOT_CORE:
            with self.subTest(path=path):
                self.assertFalse(selection.is_core_path(path))

    def outputs(self, event_name, event, changed=None, diff_error=None):
        with tempfile.TemporaryDirectory() as directory:
            event_path, output_path = Path(directory, "event.json"), Path(directory, "output")
            event_path.write_text(json.dumps(event))
            env = {"GITHUB_EVENT_NAME": event_name, "GITHUB_EVENT_PATH": str(event_path),
                   "GITHUB_OUTPUT": str(output_path), "GITHUB_SHA": "m"}
            def changed_files(base):
                if diff_error:
                    raise diff_error
                return list(changed)
            saved = {name: getattr(selection, name) for name in ("git_changed_files", "github_last_success")}
            saved_env, argv = {k: os.environ.get(k) for k in env}, sys.argv
            selection.git_changed_files, selection.github_last_success = changed_files, lambda event: "base"
            sys.argv = ["affected_platforms.py", "select"]
            os.environ.update(env)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(selection.main(), 0)
            finally:
                for name, value in saved.items():
                    setattr(selection, name, value)
                sys.argv = argv
                for key, value in saved_env.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value
            values = dict(line.split("=", 1) for line in output_path.read_text().splitlines())
            values["macos_matrix"] = json.loads(values["macos_matrix"])
            return values

    ARM = {"runner": "macos-26", "arch": "arm64", "jobs": "2", "suite": "all"}
    CTEST = {**ARM, "suite": "ctest"}

    def test_core_changes_add_the_ctest_row_to_automatic_models_runs(self):
        for event_name, event in (("pull_request", pull(action="synchronize")), ("push", {})):
            for path in ("lutools/src/core/pipeline.cpp", "Shared/BundledLooks/RawLab_look_2383_sRGB_v1.cube",
                         "RawLabMac/build.sh"):
                with self.subTest(event=event_name, path=path):
                    values = self.outputs(event_name, event, changed=["docs/process/ci.md", path])
                    self.assertEqual((values["core_ctest"], values["checks"], values["macos"]), ("true", "models", "true"))
                    self.assertEqual(values["macos_matrix"], [self.ARM, self.CTEST])

    def test_other_changes_add_no_row(self):
        for changed in (["lutools/README.md", "lutools/docs/color-contract.md"], ["lutools/platform/ios/build-framework.sh"],
                        ["RawLab/RawLab/App.swift"], ["RawLabMac/Sources/Editor/Model/EditorModel.swift"],
                        ["Shared/RawLabKit/Edit.swift"], [".github/workflows/ci.yml"], ["docs/process/ci.md"]):
            with self.subTest(changed=changed):
                values = self.outputs("pull_request", pull(action="synchronize"), changed=changed)
                self.assertEqual(values["core_ctest"], "false")
                self.assertNotIn(self.CTEST, values["macos_matrix"])

    def test_an_unavailable_diff_runs_the_row(self):
        values = self.outputs("pull_request", pull(action="synchronize"), diff_error=subprocess.CalledProcessError(1, "git"))
        self.assertEqual((values["core_ctest"], values["macos"]), ("true", "true"))
        self.assertEqual(values["macos_matrix"], [self.ARM, self.CTEST])

    def test_drafts_release_gates_and_manual_runs_keep_their_coverage(self):
        core = ["lutools/src/core/pipeline.cpp"]
        draft = self.outputs("pull_request", pull(draft=True, action="opened"), changed=core)
        self.assertEqual((draft["core_ctest"], draft["macos_matrix"]), ("false", [self.ARM]))
        release = self.outputs("pull_request", pull(base="main", head="release/1.0.0", action="synchronize"), changed=core)
        self.assertEqual((release["core_ctest"], release["checks"]), ("false", "full"))
        self.assertEqual(release["macos_matrix"], selection.macos_matrix("full"))
        for checks in ("models", "native", "full"):
            manual = self.outputs("workflow_dispatch", {"inputs": {"platform": "macos", "checks": checks}})
            with self.subTest(checks=checks):
                self.assertEqual(manual["core_ctest"], "false")
                self.assertEqual(manual["macos_matrix"], selection.macos_matrix(checks))

    def test_the_row_only_exists_in_the_models_matrix(self):
        self.assertEqual(selection.macos_matrix("models", core_ctest=True), [self.ARM, self.CTEST])
        for checks in ("contracts", "models", "build", "native", "full"):
            self.assertNotIn("ctest", [row["suite"] for row in selection.macos_matrix(checks)])
        for checks in ("build", "native", "full"):
            with self.assertRaises(ValueError):
                selection.macos_matrix(checks, core_ctest=True)

    def needs(self, macos_result="success", core_ctest="true", rows=None, checks="models", mode="automatic"):
        outputs = {platform: "true" for platform in selection.PLATFORMS}
        outputs.update(mode=mode, scope="affected", checks=checks, contracts="true", models="true", build="false",
                       native="false", cold="false", core_ctest=core_ctest,
                       macos_matrix=json.dumps(rows if rows is not None else [self.ARM, self.CTEST]))
        return {"changes": {"result": "success", "outputs": outputs}, "contracts": {"result": "success"},
                "windows-batch-selection": {"result": "success"},
                **{platform: {"result": "success"} for platform in selection.PLATFORMS}, "macos": {"result": macos_result}}

    def test_ci_result_requires_the_row_to_succeed_after_a_core_change(self):
        self.assertEqual(selection.verify(self.needs()), [])
        for result in ("failure", "cancelled", "skipped", None):
            with self.subTest(result=result):
                errors = selection.verify(self.needs(macos_result=result))
                self.assertTrue(any("core CTest job finished as" in error for error in errors), errors)
        missing = selection.verify(self.needs(rows=[self.ARM]))
        self.assertTrue(any("no core CTest row" in error for error in missing), missing)
        unplanned = selection.verify(self.needs(core_ctest="false"))
        self.assertTrue(any("without a core change" in error for error in unplanned), unplanned)
        self.assertTrue(selection.verify(self.needs(core_ctest="maybe")))


class VerifyTests(unittest.TestCase):
    def needs(self, selected, results, changes="success", contracts="success"):
        outputs = {platform: "true" if platform in selected else "false" for platform in selection.PLATFORMS}
        outputs.update(mode="automatic", scope="affected", checks="models", contracts="true", models="true", build="false", native="false", cold="false")
        return {"changes": {"result": changes, "outputs": outputs}, "contracts": {"result": contracts},
                "windows-batch-selection": {"result": "success" if "windows" in selected else "skipped"},
                **{platform: {"result": result} for platform, result in results.items()}}

    def test_selected_checks_pass_and_unselected_checks_stay_skipped(self):
        results = {"macos": "skipped", "windows": "skipped", "android": "success", "ios": "skipped"}
        self.assertEqual(selection.verify(self.needs({"android"}, results)), [])

    def test_failed_cancelled_or_unexpected_checks_fail_the_gate(self):
        for platform, result in (("android", "failure"), ("android", "cancelled"), ("android", "skipped"),
                                 ("ios", "success"), ("ios", "failure")):
            with self.subTest(platform=platform, result=result):
                results = {"macos": "skipped", "windows": "skipped", "android": "success", "ios": "skipped",
                           platform: result}
                self.assertTrue(selection.verify(self.needs({"android"}, results)))

    def test_selection_or_contract_failures_fail_the_gate(self):
        skipped = dict.fromkeys(selection.PLATFORMS, "skipped")
        self.assertTrue(selection.verify(self.needs(set(), skipped, changes="failure")))
        self.assertTrue(selection.verify(self.needs(set(), skipped, contracts="failure")))
        self.assertTrue(selection.verify({}))

    def test_automatic_windows_requires_the_batch_selection_job_to_succeed(self):
        results = dict.fromkeys(selection.PLATFORMS, "skipped") | {"windows": "success"}
        needs = self.needs({"windows"}, results)
        self.assertEqual(selection.verify(needs), [])
        for result in ("failure", "cancelled", "skipped", None):
            with self.subTest(result=result):
                needs["windows-batch-selection"]["result"] = result
                self.assertTrue(selection.verify(needs))

    def test_unselected_batch_selection_cannot_report_success(self):
        needs = self.needs(set(), dict.fromkeys(selection.PLATFORMS, "skipped"))
        needs["windows-batch-selection"]["result"] = "success"
        self.assertTrue(selection.verify(needs))

    def test_manual_verification_requires_exact_selected_results(self):
        results = dict.fromkeys(selection.PLATFORMS, "skipped") | {"windows": "success"}
        needs = self.needs({"windows"}, results, contracts="skipped")
        needs["changes"]["outputs"].update(mode="manual", scope="windows", checks="full", contracts="false", build="true", native="true", cold="true")
        needs["windows-batch-selection"]["result"] = "skipped"
        self.assertEqual(selection.verify(needs), [])
        for field, value in (("windows", "false"), ("ios", "true"), ("mode", "automatic"), ("mode", "unknown"), ("checks", "ui"), ("build", "false"), ("native", "false")):
            changed = json.loads(json.dumps(needs))
            changed["changes"]["outputs"][field] = value
            self.assertTrue(selection.verify(changed))
        for result in ("failure", "cancelled", "skipped"):
            needs["windows"]["result"] = result
            self.assertTrue(selection.verify(needs))

    def test_manual_all_full_requires_contracts_cold_and_every_platform(self):
        needs = self.needs(EVERY, dict.fromkeys(selection.PLATFORMS, "success"))
        needs["changes"]["outputs"].update(mode="manual", scope="all", checks="full", build="true", native="true", cold="true")
        needs["windows-batch-selection"]["result"] = "skipped"
        self.assertEqual(selection.verify(needs), [])
        for field, value in (("contracts", "false"), ("cold", "false"), ("windows", "false")):
            changed = json.loads(json.dumps(needs))
            changed["changes"]["outputs"][field] = value
            if field in ("contracts", "windows"):
                changed[field]["result"] = "skipped"
            self.assertTrue(selection.verify(changed))

    def test_contracts_only_cannot_select_a_platform(self):
        needs = self.needs(set(), dict.fromkeys(selection.PLATFORMS, "skipped"))
        needs["changes"]["outputs"].update(mode="manual", scope="all", checks="contracts", models="false")
        self.assertEqual(selection.verify(needs), [])
        needs["changes"]["outputs"]["windows"] = "true"
        needs["windows"]["result"] = "success"
        self.assertTrue(selection.verify(needs))


if __name__ == "__main__":
    unittest.main()
