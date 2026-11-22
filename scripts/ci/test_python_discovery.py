"""Enforce unified Python test discovery and zero orphan Python test files."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]
PYPROJECT = ROOT / "pyproject.toml"
CI_WORKFLOW = ROOT / ".github/workflows/ci.yml"
LUTOOLS_CMAKE = ROOT / "lutools/CMakeLists.txt"


def _is_test_filename(name: str) -> bool:
    return name.endswith(".py") and (name.startswith("test_") or name.endswith("_test.py"))


def _is_hyphenated_test_filename(name: str) -> bool:
    return name.endswith(".py") and (name.startswith("test-") or name.endswith("-test.py"))


def _tracked_python_files() -> list[str]:
    tracked = subprocess.check_output(
        ["git", "ls-files", "*.py"],
        cwd=ROOT,
        text=True,
    ).splitlines()
    # Include untracked non-ignored local files so new orphans fail before commit.
    untracked = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "*.py"],
        cwd=ROOT,
        text=True,
    ).splitlines()
    return sorted(set(tracked + untracked))


def _tracked_python_tests() -> set[str]:
    return {line for line in _tracked_python_files() if _is_test_filename(Path(line).name)}


class PythonTestDiscoveryContracts(unittest.TestCase):
    def test_pyproject_unifies_testpaths_with_zero_orphans(self) -> None:
        self.assertTrue(PYPROJECT.is_file(), "Root pyproject.toml is missing")
        config = tomllib.loads(PYPROJECT.read_text(encoding="utf-8"))
        pytest_cfg = config["tool"]["pytest"]["ini_options"]
        testpaths = pytest_cfg["testpaths"]
        self.assertTrue(testpaths, "testpaths must not be empty")
        self.assertIn("test_*.py", pytest_cfg["python_files"])
        self.assertIn("*_test.py", pytest_cfg["python_files"])

        ci_text = CI_WORKFLOW.read_text(encoding="utf-8")
        cmake_text = LUTOOLS_CMAKE.read_text(encoding="utf-8")
        self.assertIn("python -m pytest -v", ci_text)

        # Verify every configured testpath exists.
        testpath_dirs = []
        for entry in testpaths:
            path = ROOT / entry
            self.assertTrue(path.is_dir(), f"Configured testpath does not exist: {entry}")
            testpath_dirs.append(Path(entry))

        # Parse explicit `--ignore=...` entries in addopts.
        ignored_files: set[str] = set()
        for opt in pytest_cfg.get("addopts", []):
            if opt.startswith("--ignore="):
                rel = opt.split("=", 1)[1]
                self.assertTrue((ROOT / rel).is_file(), f"Stale --ignore entry in pyproject.toml: {rel}")
                ignored_files.add(rel)

        # Every ignored native runner must be wired in CTest or CI directly.
        for rel in sorted(ignored_files):
            name = Path(rel).name
            wired_in_cmake = name in cmake_text
            wired_in_ci = rel in ci_text
            self.assertTrue(
                wired_in_cmake or wired_in_ci,
                f"Ignored test file {rel} is not wired in lutools/CMakeLists.txt or ci.yml",
            )

        # Verify tools/mcp/tests is wired via uv in ci.yml.
        self.assertIn("uv run --project tools/mcp --frozen python -m unittest discover -s tools/mcp/tests", ci_text)

        # Check every non-experiments Python test file in the repository.
        all_tests = _tracked_python_tests()
        orphans = []
        for rel in sorted(all_tests):
            rel_path = Path(rel)
            if rel_path.parts[0] == "experiments":
                continue
            if rel_path.is_relative_to(Path("tools/mcp/tests")):
                continue
            in_testpaths = any(rel_path.is_relative_to(tp) for tp in testpath_dirs)
            if not in_testpaths:
                orphans.append(rel)
                continue
            if rel in ignored_files:
                continue

        self.assertEqual(orphans, [], f"Orphan Python test file(s) outside pyproject.toml testpaths: {orphans}")

        # Also guard against hyphenated test filenames silently skipped by pytest.
        hyphenated = [
            rel
            for rel in _tracked_python_files()
            if _is_hyphenated_test_filename(Path(rel).name)
            and Path(rel).parts[0] != "experiments"
            and not Path(rel).is_relative_to(Path("tools/mcp/tests"))
        ]
        self.assertEqual(
            hyphenated,
            [],
            f"Hyphenated Python test file(s) silently skipped by pytest: {hyphenated}",
        )

        # Also guard that every file in RawLabMac/tests/ or lutools/tests/ matching test_*.py is accounted for.
        self.assertFalse(
            re.search(r"(?m)^\s*python\s+lutools/tests/test_", ci_text),
            "ci.yml should invoke unified pytest discovery instead of ad-hoc lutools/tests commands",
        )


if __name__ == "__main__":
    unittest.main()
