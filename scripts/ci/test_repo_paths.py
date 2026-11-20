"""Contract tests preventing workstation-specific absolute paths in tracked files."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
_UNIX_USERS = "/" + "[Uu]sers"
_UNIX_HOME = "/" + "home"
_WIN_USERS = r"[A-Za-z]:[/\\]{1,2}[Uu]" + r"sers[/\\]{1,2}"
WORKSTATION_PATH_RE = re.compile(
    rf"(?<![A-Za-z0-9._-])(?:{_UNIX_USERS}|{_UNIX_HOME})/[A-Za-z0-9._-]+"
    rf"|{_WIN_USERS}[A-Za-z0-9._-]+"
)


def find_workstation_paths(root: Path = ROOT) -> list[str]:
    raw_list = subprocess.check_output(
        ["git", "ls-files", "-z"],
        cwd=root,
    )
    violations: list[str] = []
    for entry in raw_list.split(b"\0"):
        if not entry:
            continue
        rel = entry.decode("utf-8", errors="surrogateescape")
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        if b"\x00" in data:
            continue
        text = data.decode("utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), start=1):
            match = WORKSTATION_PATH_RE.search(line)
            if match:
                violations.append(f"{rel}:{lineno}: {match.group(0)}")
    return violations


class RepoPathHygieneTests(unittest.TestCase):
    def test_no_workstation_paths_in_tracked_files(self) -> None:
        violations = find_workstation_paths(ROOT)
        self.assertEqual(
            violations,
            [],
            "Tracked files must not contain workstation user-home paths:\n" + "\n".join(violations),
        )

    def test_detector_catches_unix_and_windows_user_paths(self) -> None:
        samples = [
            f"/{'Users'}/alice/repo",
            f"/{'users'}/bob/file",
            f"/{'home'}/ci/work",
            f"path=/{'Users'}/alice/raw",
            f"(/{'Users'}/alice)",
            rf"C:\{'Users'}\alice\doc",
            rf"D:\\{'Users'}\\bob\\repo",
            f"C:/{'Users'}/alice/repo",
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertIsNotNone(WORKSTATION_PATH_RE.search(sample), sample)

    def test_detector_allows_repo_relative_and_safe_paths(self) -> None:
        safe_samples = [
            "build/native-acceptance/home/Library/Application Support/RawLab",
            "https://example.com/users/alice/profile",
            "$HOME/Library/Android/sdk",
            "<worktree>/macos-v08/rawtools",
            "Shared/BundledLooks/Artwork/look-ektar-100.png",
            "docs/design/2026-10-09-edit-memory-batch-export/images/mac-confirm.webp",
        ]
        for sample in safe_samples:
            with self.subTest(sample=sample):
                self.assertIsNone(WORKSTATION_PATH_RE.search(sample), sample)


if __name__ == "__main__":
    unittest.main()
