"""Contract tests verifying every active Markdown relative link resolves in the repository."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
EXCLUDED_PREFIXES = (
    "docs/archive/",
    ".impeccable/",
    "lutools/x3f-bridge/vendor/",
)
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
INLINE_CODE_RE = re.compile(r"(`+)(?:(?!\1).)*?\1")
INLINE_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)\n]+)\)")
REF_LINK_RE = re.compile(r"^\s*\[[^\]]+\]:\s*(\S+)")
FENCE_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")


def _is_excluded(rel_posix: str) -> bool:
    return any(rel_posix.startswith(prefix) for prefix in EXCLUDED_PREFIXES)


def active_markdown_files(root: Path = ROOT) -> list[Path]:
    """List active tracked `.md` files (falling back to walk in non-git sandboxes)."""
    resolved_root = root.resolve()
    try:
        top = subprocess.check_output(
            ["git", "-C", str(resolved_root), "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if Path(top).resolve() == resolved_root:
            raw = subprocess.check_output(
                ["git", "-C", str(resolved_root), "ls-files", "-z", "*.md"],
            )
            paths: list[Path] = []
            for entry in raw.split(b"\0"):
                if not entry:
                    continue
                rel = entry.decode("utf-8", errors="surrogateescape")
                if not _is_excluded(rel):
                    candidate = resolved_root / rel
                    if candidate.is_file():
                        paths.append(candidate)
            return sorted(paths)
    except (OSError, subprocess.CalledProcessError):
        pass

    skip_dirs = {".git", ".cache", "build", ".build", "node_modules"}
    paths = []
    for candidate in resolved_root.rglob("*.md"):
        rel = candidate.relative_to(resolved_root).as_posix()
        if _is_excluded(rel) or any(part in skip_dirs for part in candidate.relative_to(resolved_root).parts):
            continue
        if candidate.is_file():
            paths.append(candidate)
    return sorted(paths)


def iter_non_fenced_lines(text: str) -> list[tuple[int, str]]:
    """Return 1-based `(lineno, line)` pairs outside fenced code blocks."""
    kept: list[tuple[int, str]] = []
    in_fence = False
    fence_char = ""
    fence_len = 0
    for lineno, line in enumerate(text.splitlines(), start=1):
        match = FENCE_RE.match(line)
        if match:
            marker, rest = match.group(1), match.group(2)
            ch = marker[0]
            if not in_fence:
                if not (ch == "`" and "`" in rest):
                    in_fence = True
                    fence_char = ch
                    fence_len = len(marker)
                    continue
            elif ch == fence_char and len(marker) >= fence_len and not rest.strip():
                in_fence = False
                continue
        if not in_fence:
            kept.append((lineno, line))
    return kept


def _extract_target_path(raw_target: str) -> str | None:
    target = raw_target.strip()
    if not target:
        return None
    if target.startswith("<"):
        end = target.find(">")
        if end != -1:
            target = target[1:end].strip()
    else:
        parts = target.split(None, 1)
        if len(parts) == 2 and parts[1].startswith(('"', "'", "(")):
            target = parts[0]
    if not target or target.startswith(("#", "?")) or SCHEME_RE.match(target):
        return None
    target = target.split("#", 1)[0].split("?", 1)[0].strip()
    return target or None


def find_dead_links(root: Path = ROOT) -> list[str]:
    """Return formatted `file:lineno: target` errors for missing relative Markdown links."""
    resolved_root = root.resolve()
    errors: list[str] = []
    for md_path in active_markdown_files(resolved_root):
        rel = md_path.relative_to(resolved_root).as_posix()
        text = md_path.read_text(encoding="utf-8")
        for lineno, line in iter_non_fenced_lines(text):
            cleaned = INLINE_CODE_RE.sub("", line)
            candidates = [m.group(1) for m in INLINE_LINK_RE.finditer(cleaned)]
            ref_match = REF_LINK_RE.match(cleaned)
            if ref_match:
                candidates.append(ref_match.group(1))
            for raw_target in candidates:
                target = _extract_target_path(raw_target)
                if target is None:
                    continue
                resolved_target = (md_path.parent / target).resolve()
                inside_repo = (
                    resolved_target == resolved_root or resolved_root in resolved_target.parents
                )
                if not inside_repo or not resolved_target.exists():
                    errors.append(f"{rel}:{lineno}: {raw_target.strip()}")
    return errors


class DocLinksTests(unittest.TestCase):
    def test_active_markdown_files_have_no_dead_relative_links(self) -> None:
        errors = find_dead_links(ROOT)
        self.assertEqual(
            errors,
            [],
            "Broken relative links found in active Markdown files:\n" + "\n".join(errors),
        )

    def test_dead_link_detector_handles_fences_queries_anchors_and_failures(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rawlab-doc-links-") as tmp:
            root = Path(tmp)
            (root / "docs/archive").mkdir(parents=True)
            (root / "docs/design").mkdir(parents=True)
            (root / "docs/design/index.html").write_text("<html></html>\n", encoding="utf-8")
            (root / "README.md").write_text("# Root\n", encoding="utf-8")
            (root / "docs/archive/legacy.md").write_text("[dead](missing.md)\n", encoding="utf-8")
            (root / "docs/design/guide.md").write_text(
                "\n".join(
                    [
                        "# Guide",
                        "[Root](../../README.md#top)",
                        "[Prototype](index.html?platform=ios&scene=copy-scope#main)",
                        "[External](https://example.com/path)",
                        "[Mail](mailto:test@example.com)",
                        "[SameDoc](#section)",
                        "Inline code `[ignored](missing-inline.md)` should pass.",
                        "```markdown",
                        "[ignored-in-fence](missing-fence.md)",
                        "```",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            self.assertEqual(find_dead_links(root), [])

            # Inject a dead relative link and confirm detection.
            guide = root / "docs/design/guide.md"
            guide.write_text(guide.read_text(encoding="utf-8") + "[Broken](no-such-file.md)\n", encoding="utf-8")
            self.assertEqual(find_dead_links(root), ["docs/design/guide.md:11: no-such-file.md"])

            # Inject a repo-escaping relative link and confirm detection.
            guide.write_text("[Escape](../../../outside.md)\n", encoding="utf-8")
            self.assertEqual(find_dead_links(root), ["docs/design/guide.md:1: ../../../outside.md"])


if __name__ == "__main__":
    unittest.main()
