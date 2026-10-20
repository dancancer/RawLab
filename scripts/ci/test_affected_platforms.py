"""Platform selection and result-gate regressions."""
import importlib.util
from pathlib import Path
import subprocess
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

    def test_nightly_runs_cold_once_per_commit(self):
        self.assertEqual(selection.select("schedule", {}, "s", unavailable, {"schedule": "old"}.get)[:2], (EVERY, True))
        self.assertEqual(selection.select("schedule", {}, "s", unavailable, {"schedule": "s"}.get)[:2], (set(), True))
        def offline(_):
            raise OSError("API unavailable")
        self.assertEqual(selection.select("schedule", {}, "s", unavailable, offline)[:2], (EVERY, True))
        self.assertEqual(selection.select("workflow_dispatch", {}, "s", unavailable, unavailable)[:2], (EVERY, True))


class VerifyTests(unittest.TestCase):
    def needs(self, selected, results, changes="success", contracts="success"):
        outputs = {platform: "true" if platform in selected else "false" for platform in selection.PLATFORMS}
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


if __name__ == "__main__":
    unittest.main()
