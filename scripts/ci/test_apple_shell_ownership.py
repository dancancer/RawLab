"""Ownership and zero-hand-copied-list contract tests for Apple SPM and shell harnesses."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHELL_TEST_DIRS = ("Shared/tests", "RawLab/tests", "RawLabMac/tests")
OWNER_DOCS_AND_RUNNERS = (
    ".github/workflows/ci.yml",
    "scripts/ci/apple-models.sh",
    "RawLabMac/build.sh",
    "docs/process/ci.md",
    "docs/process/desktop-release.md",
    "RawLab/AGENTS.md",
    "RawLabMac/README.md",
    "lutools/docs/x3f-rendering.md",
    "lutools/tools/dualdn/README.md",
    "scripts/ci/test_ax_gate.py",
    "scripts/ci/test_mac_native_sources.py",
)


class AppleShellOwnershipTests(unittest.TestCase):
    def test_every_apple_shell_script_has_explicit_owner(self):
        owner_corpus = "\n".join((ROOT / rel).read_text(encoding="utf-8") for rel in OWNER_DOCS_AND_RUNNERS)
        unowned = []
        for directory in SHELL_TEST_DIRS:
            for script in sorted((ROOT / directory).glob("*.sh")):
                rel = str(script.relative_to(ROOT))
                pattern = re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(rel) + r"(?![A-Za-z0-9_.-])")
                if not pattern.search(owner_corpus):
                    unowned.append(rel)
        self.assertEqual(unowned, [], f"Unowned Apple shell scripts: {unowned}")

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
