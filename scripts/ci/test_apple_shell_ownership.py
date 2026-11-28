"""Ownership and zero-hand-copied-list contract tests for Apple SPM and shell harnesses."""
import os
from pathlib import Path
import re
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
SHELL_TEST_DIRS = ("Shared/tests", "RawLab/tests", "RawLabMac/tests")
HELPER_LIBS = (
    "RawLabMac/tests/lib/compile.sh",
    "RawLab/tests/lib/ios-harness.sh",
)
OWNER_DOCS_AND_RUNNERS = (
    ".github/workflows/ci.yml",
    "scripts/ci/apple-models.sh",
    "RawLabMac/build.sh",
    "docs/process/ci.md",
    "docs/process/desktop-release.md",
    "docs/process/release-packaging-guide.md",
    "RawLab/AGENTS.md",
    "RawLabMac/README.md",
    "lutools/docs/x3f-rendering.md",
    "lutools/tools/dualdn/README.md",
    "scripts/ci/test_ax_gate.py",
    "scripts/ci/test_mac_native_sources.py",
    "scripts/ci/test_mac_shell_hygiene.py",
)

_CI_EXEC_SHELL_SCRIPT_RE = re.compile(
    r"^\s*(?:ci_timed\s+\S+\s+)?(?:env\s+(?:\S+=\S+\s+)*)?bash\s+((?:Shared|RawLab|RawLabMac)/tests/[A-Za-z0-9_.-]+\.sh)\b"
)


def _ci_executed_apple_scripts(workflow_text: str) -> str:
    """Return only Apple test shell scripts actually executed by workflow run steps (not notice/echo text)."""
    workflow = yaml.load(workflow_text, Loader=yaml.BaseLoader)
    executed: list[str] = []
    for job in (workflow.get("jobs") or {}).values():
        for step in job.get("steps") or []:
            for line in step.get("run", "").splitlines():
                stripped = line.lstrip()
                if stripped.startswith("#"):
                    continue
                match = _CI_EXEC_SHELL_SCRIPT_RE.match(line)
                if match:
                    executed.append(match.group(1))
    return "\n".join(executed)


class AppleShellOwnershipTests(unittest.TestCase):
    def test_every_apple_shell_script_has_explicit_owner(self):
        parts = []
        for rel in OWNER_DOCS_AND_RUNNERS:
            text = (ROOT / rel).read_text(encoding="utf-8")
            if rel == ".github/workflows/ci.yml":
                parts.append(_ci_executed_apple_scripts(text))
            else:
                parts.append(text)
        owner_corpus = "\n".join(parts)
        unowned = []
        for directory in SHELL_TEST_DIRS:
            for script in sorted((ROOT / directory).glob("*.sh")):
                rel = str(script.relative_to(ROOT))
                pattern = re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(rel) + r"(?![A-Za-z0-9_.-])")
                if not pattern.search(owner_corpus):
                    unowned.append(rel)
        self.assertEqual(unowned, [], f"Unowned Apple shell scripts: {unowned}")

    def test_coreml_hardware_gate_is_owned_by_release_docs_not_ci_notice(self):
        gate_script = "RawLabMac/tests/dualdn-api-package.sh"
        gate_cmd = f"bash {gate_script}"

        # Non-executing notice text in ci.yml must not count as workflow ownership.
        ci_executed = _ci_executed_apple_scripts((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
        self.assertNotIn(gate_script, ci_executed, "ci.yml notice text must not count as script ownership")

        # Both release documents must name the hardware gate command in their mandatory pre-publish sections.
        packaging_text = (ROOT / "docs/process/release-packaging-guide.md").read_text(encoding="utf-8")
        mac_accept_match = re.search(r"### 4\.1 macOS[\s\S]*?4\. \*\*验收\*\*：([\s\S]*?)(?:\n### |\Z)", packaging_text)
        self.assertIsNotNone(mac_accept_match, "release-packaging-guide.md missing macOS 4. 验收 section")
        self.assertIn(
            gate_cmd,
            mac_accept_match.group(1),
            "release-packaging-guide.md macOS acceptance section must name bash RawLabMac/tests/dualdn-api-package.sh",
        )

        desktop_text = (ROOT / "docs/process/desktop-release.md").read_text(encoding="utf-8")
        accept_match = re.search(r"## Acceptance and publication([\s\S]*?)(?:\n## |\Z)", desktop_text)
        self.assertIsNotNone(accept_match, "desktop-release.md missing Acceptance and publication section")
        self.assertIn(
            gate_cmd,
            accept_match.group(1),
            "desktop-release.md Acceptance and publication section must name bash RawLabMac/tests/dualdn-api-package.sh",
        )

    def test_helper_libraries_are_owned_and_used(self):
        lib_scripts = sorted(
            str(p.relative_to(ROOT))
            for d in SHELL_TEST_DIRS
            for p in (ROOT / d).rglob("*.sh")
            if p.parent != ROOT / d
        )
        self.assertEqual(lib_scripts, sorted(HELPER_LIBS), f"Unexpected nested Apple shell scripts: {lib_scripts}")

        corpus_by_dir = {
            d: "\n".join(p.read_text(encoding="utf-8") for p in sorted((ROOT / d).glob("*.sh")))
            for d in SHELL_TEST_DIRS
        }
        all_corpus = "\n".join(corpus_by_dir.values())
        for rel in HELPER_LIBS:
            path = ROOT / rel
            self.assertTrue(path.is_file(), f"Missing helper library: {rel}")
            res = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn(rel, all_corpus, f"Helper library {rel} is not sourced by any Apple test script")

    def test_shared_helper_source_sets_resolve_existing_files(self):
        resolvers = (
            ("RawLabMac/tests/lib/compile.sh", "rawlab_mac_full_app_sources"),
            ("RawLabMac/tests/lib/compile.sh", "rawlab_mac_editor_model_sources"),
            ("RawLabMac/tests/lib/compile.sh", "rawlab_mac_render_engine_sources"),
            ("RawLabMac/tests/lib/compile.sh", "rawlab_mac_adjustment_native_sources"),
            ("RawLab/tests/lib/ios-harness.sh", "rawlab_ios_core_shared_sources"),
            ("RawLab/tests/lib/ios-harness.sh", "rawlab_ios_processor_export_sources"),
            ("RawLab/tests/lib/ios-harness.sh", "rawlab_ios_camera_sources"),
        )
        resolved_by_name = {}
        for lib_rel, fn in resolvers:
            with self.subTest(lib=lib_rel, fn=fn):
                res = subprocess.run(
                    [
                        "bash",
                        "-euo",
                        "pipefail",
                        "-c",
                        f'ROOT="{ROOT}"; source "$ROOT/{lib_rel}"; {fn} OUT; printf "%s\\n" "${{OUT[@]}}"',
                    ],
                    env={**os.environ, "ROOT": str(ROOT)},
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(res.returncode, 0, res.stderr)
                paths = [Path(line) for line in res.stdout.splitlines() if line]
                self.assertGreater(len(paths), 0, f"{fn} returned empty source list")
                for p in paths:
                    self.assertTrue(p.is_file(), f"{fn} returned missing file: {p}")
                resolved_by_name[fn] = sorted(paths)

        expected_full_app = sorted(
            [p for p in (ROOT / "RawLabMac/Sources").rglob("*.swift") if p.name != "RawLabMacApp.swift"]
            + list((ROOT / "Shared").glob("*.swift"))
            + list((ROOT / "Shared/Native").glob("*.swift"))
        )
        self.assertEqual(resolved_by_name["rawlab_mac_full_app_sources"], expected_full_app)

    def test_no_shell_script_hand_copies_rawlabkit_swift_files(self):
        rawlabkit_files = sorted(p.name for p in (ROOT / "Shared/RawLabKit").glob("*.swift"))
        self.assertGreater(len(rawlabkit_files), 0)
        moved_pat = re.compile(
            r"(?:Shared/RawLabKit/|\$ROOT[\"']?/Shared/(?:"
            + "|".join(re.escape(name) for name in rawlabkit_files)
            + r")\b)"
        )
        violations = []
        for script in sorted(ROOT.rglob("*.sh")):
            if any(part in script.parts for part in (".git", ".build", ".cache", "build")):
                continue
            if moved_pat.search(script.read_text(encoding="utf-8")):
                violations.append(str(script.relative_to(ROOT)))
        self.assertEqual(violations, [], f"Shell scripts still reference moved RawLabKit files directly: {violations}")

    def test_package_swift_uses_auto_discovery_without_hand_copied_lists(self):
        pkg = (ROOT / "Package.swift").read_text(encoding="utf-8")
        self.assertIn('path: "Shared/RawLabKit"', pkg)
        self.assertIn('path: "tests/RawLabKitTests"', pkg)
        self.assertNotIn("sources:", pkg)
        self.assertNotIn(".swift\"", pkg)

    def test_ci_and_model_runner_do_not_reference_deleted_shell_scripts(self):
        for runner in (".github/workflows/ci.yml", "scripts/ci/apple-models.sh"):
            text = (ROOT / runner).read_text(encoding="utf-8")
            refs = sorted(set(re.findall(r"(?:Shared|RawLab|RawLabMac)/tests/[A-Za-z0-9_.-]+\.sh", text)))
            missing = [ref for ref in refs if not (ROOT / ref).is_file()]
            self.assertEqual(missing, [], f"{runner} references missing scripts: {missing}")


if __name__ == "__main__":
    unittest.main()
