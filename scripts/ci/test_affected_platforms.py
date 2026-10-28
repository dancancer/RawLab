"""Platform selection and result-gate regressions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("affected_platforms", Path(__file__).with_name("affected_platforms.py"))
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)
EVERY = set(selection.PLATFORMS)


def pull(base="development", head="feature/x", draft=False):
    return {"pull_request": {"base": {"ref": base}, "head": {"ref": head}, "draft": draft}}


def unavailable(*_):
    raise AssertionError("This event must not inspect history")


class ClassificationTests(unittest.TestCase):
    def test_client_directories_select_only_their_platform(self):
        for path, expected in (("RawLab/RawLab/Views/Editor.swift", {"ios"}),
                               ("RawLabMac/Sources/Editor/Model/EditorModel.swift", {"macos"}),
                               ("RawLabMac/build.sh", {"macos"}),
                               ("RawLabWindows/README.md", {"windows"}),
                               ("RawLabAndroid/app/build.gradle.kts", {"android"})):
            with self.subTest(path=path):
                self.assertEqual(selection.platforms_for(path), expected)

    def test_files_other_clients_consume_select_them_too(self):
        for path in ("RawLabMac/Resources/FilmIcons/acros.png", "RawLabMac/Resources/Licenses/stb-MIT-LICENSE.txt",
                     "docs/reference/licensing.md", "LICENSE", "LICENSE-ALIYUN-RUM-EXCEPTION"):
            with self.subTest(path=path):
                self.assertEqual(selection.platforms_for(path), EVERY)
        self.assertEqual(selection.platforms_for("RawLabMac/tests/DCPTestFixtures.swift"), {"macos", "ios"})

    def test_shared_code_tooling_and_unknown_files_select_every_platform(self):
        for path in ("lutools/src/core/raw_processor.cpp", "lutools/README.md", "Shared/LookLibrary.swift",
                     "scripts/ci/native_cache.py", ".github/workflows/ci.yml", "tests/test_localization.py",
                     "experiments/hamada-neural/runs/a.cube", "release-artifacts/windows/x/manifest.json",
                     "raw_decode_check.swift", "new-top-level/file"):
            with self.subTest(path=path):
                self.assertEqual(selection.platforms_for(path), EVERY)

    def test_documentation_selects_no_platform(self):
        for path in ("docs/process/ci.md", "README.md", "CHANGELOG.md", "AGENTS.md", "RawLab/AGENTS.md",
                     "lutools/AGENTS.md", "reviews/pr-82.md", ".impeccable/design.json", ".gitignore"):
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

    def test_drafts_defer_platform_checks(self):
        platforms, _, draft, _ = selection.select("pull_request", pull(draft=True), "s", unavailable, unavailable)
        self.assertEqual((platforms, draft), (set(), True))

    def test_release_and_hotfix_pull_requests_run_everything_cold(self):
        for base, head in (("main", "release/0.9.0"), ("main", "hotfix/crash"),
                           ("development", "release/0.9.0"), ("release/0.9.0", "fix/x")):
            with self.subTest(base=base, head=head):
                result = selection.select("pull_request", pull(base, head), "s", unavailable, unavailable)
                self.assertEqual(result[:3], (EVERY, True, False))

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

    def test_mac_matrix_runs_models_once_and_builds_once_per_architecture(self):
        self.assertEqual([(r["arch"], r["suite"]) for r in selection.macos_matrix("models")], [("arm64", "all")])
        self.assertEqual([(r["arch"], r["suite"]) for r in selection.macos_matrix("build")], [("arm64", "all"), ("x86_64", "build")])
        for checks in ("native", "full"):
            self.assertEqual([(r["arch"], r["suite"]) for r in selection.macos_matrix(checks)],
                [("arm64", "all"), ("x86_64", "core"), ("x86_64", "agent"), ("x86_64", "render")])


class WindowsSchedulingTests(unittest.TestCase):
    def test_windows_models_and_warm_prs_use_hosted_windows(self):
        dedicated = ["self-hosted", "windows", "x64", "rawlab-windows"]
        for event, cold, want in (
            ("pull_request", False, "windows-2022"),
            ("pull_request", True, dedicated),
            ("push", False, dedicated),
            ("workflow_dispatch", False, dedicated),
            ("workflow_dispatch", True, dedicated),
        ):
            with self.subTest(event=event, cold=cold):
                self.assertEqual(selection.windows_runner(event, cold), want)
                self.assertEqual(selection.windows_runner(event, cold, "models"), "windows-2022")

    def test_selection_cli_emits_a_json_runner_for_the_workflow(self):
        for event_name, event, want in (
            ("pull_request", pull(), "windows-2022"),
            ("pull_request", pull("main", "release/0.9.0"),
             ["self-hosted", "windows", "x64", "rawlab-windows"]),
            ("workflow_dispatch", {}, "windows-2022"),
            ("workflow_dispatch", {"inputs": {"platform": "windows", "checks": "full"}},
             ["self-hosted", "windows", "x64", "rawlab-windows"]),
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


class VerifyTests(unittest.TestCase):
    def needs(self, selected, results, changes="success", contracts="success"):
        outputs = {platform: "true" if platform in selected else "false" for platform in selection.PLATFORMS}
        outputs.update(mode="automatic", scope="affected", checks="models", contracts="true", models="true", build="false", native="false", cold="false")
        return {"changes": {"result": changes, "outputs": outputs}, "contracts": {"result": contracts},
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

    def test_manual_verification_requires_exact_selected_results(self):
        results = dict.fromkeys(selection.PLATFORMS, "skipped") | {"windows": "success"}
        needs = self.needs({"windows"}, results, contracts="skipped")
        needs["changes"]["outputs"].update(mode="manual", scope="windows", checks="full", contracts="false", build="true", native="true", cold="true")
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
