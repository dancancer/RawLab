#!/usr/bin/env python3
"""Contract and .app bundle hygiene tests for iOS Shared/BundledLooks packaging (#541)."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PBXPROJ = ROOT / "RawLab/RawLab.xcodeproj/project.pbxproj"
BUNDLED_LOOKS_DIR = ROOT / "Shared/BundledLooks"
NON_RUNTIME_PREFIXES = ("generated-",)
NON_RUNTIME_NAMES = {"REDISTRIBUTION_BLOCKED.md", "NOTICE.md", "adaptation-report.json"}


def expected_bundled_looks_runtime_files(root: Path = ROOT) -> set[tuple[str, str]]:
    """Return the exact {(bundle_relpath, repo_relpath)} set required at iOS runtime."""
    looks_dir = root / "Shared/BundledLooks"
    catalog = json.loads((looks_dir / "catalog.json").read_text(encoding="utf-8"))
    expected: set[tuple[str, str]] = {
        ("BundledLooks/catalog.json", "Shared/BundledLooks/catalog.json"),
    }
    artwork_dir = looks_dir / "Artwork"
    disk_pngs = {p.name for p in artwork_dir.glob("*.png")}
    catalog_pngs: set[str] = set()
    for entry in catalog:
        cube_name = entry["fileName"]
        expected.add((f"BundledLooks/{cube_name}", f"Shared/BundledLooks/{cube_name}"))
        png_name = f"{entry['artworkName']}.png"
        if png_name in disk_pngs:
            catalog_pngs.add(png_name)
            expected.add((f"BundledLooks/Artwork/{png_name}", f"Shared/BundledLooks/Artwork/{png_name}"))

    if catalog_pngs != disk_pngs:
        missing = sorted(disk_pngs - catalog_pngs)
        raise AssertionError(f"Unreferenced PNGs in Shared/BundledLooks/Artwork: {missing}")

    hdr_dir = looks_dir / "HDR"
    for hdr_file in sorted(hdr_dir.iterdir()):
        if hdr_file.is_file() and not hdr_file.name.startswith("."):
            expected.add((f"BundledLooks/HDR/{hdr_file.name}", f"Shared/BundledLooks/HDR/{hdr_file.name}"))

    return expected


def non_runtime_bundled_looks_files(root: Path = ROOT) -> set[str]:
    """Return tracked non-runtime repo-relative paths under Shared/BundledLooks."""
    runtime_repo_paths = {repo_rel for _, repo_rel in expected_bundled_looks_runtime_files(root)}
    tracked = subprocess.check_output(
        ["git", "ls-files", "-z", "Shared/BundledLooks"],
        cwd=root,
    )
    non_runtime: set[str] = set()
    for raw in tracked.split(b"\0"):
        if not raw:
            continue
        rel = raw.decode("utf-8", errors="surrogateescape")
        if rel not in runtime_repo_paths:
            non_runtime.add(rel)
    return non_runtime


class _PbxprojParser:
    """Minimal OpenStep plist parser for Xcode project.pbxproj files."""

    def __init__(self, text: str) -> None:
        self.tokens = self._tokenize(text)
        self.pos = 0

    @staticmethod
    def _tokenize(text: str) -> list[tuple[str, str]]:
        tokens: list[tuple[str, str]] = []
        i = 0
        n = len(text)
        while i < n:
            ch = text[i]
            if ch.isspace():
                i += 1
                continue
            if text.startswith("//", i):
                nl = text.find("\n", i)
                i = n if nl == -1 else nl + 1
                continue
            if text.startswith("/*", i):
                end = text.find("*/", i + 2)
                if end == -1:
                    raise ValueError("Unterminated /* comment in pbxproj")
                i = end + 2
                continue
            if ch in "{}=();,":
                tokens.append((ch, ch))
                i += 1
                continue
            if ch == '"':
                j = i + 1
                buf: list[str] = []
                while j < n:
                    c = text[j]
                    if c == "\\":
                        if j + 1 >= n:
                            raise ValueError("Trailing backslash in quoted string")
                        nxt = text[j + 1]
                        buf.append({"n": "\n", "r": "\r", "t": "\t"}.get(nxt, nxt))
                        j += 2
                        continue
                    if c == '"':
                        break
                    buf.append(c)
                    j += 1
                else:
                    raise ValueError("Unterminated quoted string in pbxproj")
                tokens.append(("STR", "".join(buf)))
                i = j + 1
                continue
            j = i
            while j < n and not text[j].isspace() and text[j] not in "{}=();,\"":
                if text.startswith("/*", j) or text.startswith("//", j):
                    break
                j += 1
            tokens.append(("ATOM", text[i:j]))
            i = j
        return tokens

    def _peek(self) -> tuple[str, str]:
        return self.tokens[self.pos] if self.pos < len(self.tokens) else ("EOF", "")

    def _next(self, expected: str | None = None) -> tuple[str, str]:
        tok = self._peek()
        if expected is not None and tok[0] != expected:
            raise ValueError(f"Expected {expected}, got {tok} at token {self.pos}")
        self.pos += 1
        return tok

    def parse_value(self):
        kind, val = self._peek()
        if kind == "{":
            return self.parse_dict()
        if kind == "(":
            return self.parse_array()
        if kind in ("STR", "ATOM"):
            self._next()
            return val
        raise ValueError(f"Unexpected token {kind, val} at {self.pos}")

    def parse_dict(self) -> dict:
        self._next("{")
        result: dict = {}
        while self._peek()[0] != "}":
            key_kind, key_val = self._next()
            if key_kind not in ("STR", "ATOM"):
                raise ValueError(f"Expected dict key, got {key_kind, key_val}")
            self._next("=")
            result[key_val] = self.parse_value()
            self._next(";")
        self._next("}")
        return result

    def parse_array(self) -> list:
        self._next("(")
        items: list = []
        while self._peek()[0] != ")":
            items.append(self.parse_value())
            if self._peek()[0] == ",":
                self._next(",")
        self._next(")")
        return items


def parse_pbxproj(pbxproj_path: Path = PBXPROJ) -> dict:
    return _PbxprojParser(pbxproj_path.read_text(encoding="utf-8")).parse_value()


def _resolve_pbx_path(file_ref: dict, objects: dict, parent_map: dict[str, str]) -> str:
    source_tree = file_ref.get("sourceTree", "<group>")
    raw_path = file_ref.get("path", "")
    if source_tree == "SOURCE_ROOT":
        return posixpath.normpath(posixpath.join("RawLab", raw_path))
    if source_tree == "<group>":
        parts = [raw_path] if raw_path else []
        cur = None
        for ref_id, obj in objects.items():
            if obj is file_ref:
                cur = ref_id
                break
        while cur and cur in parent_map:
            parent_id = parent_map[cur]
            parent_obj = objects.get(parent_id, {})
            if parent_obj.get("isa") == "PBXGroup" and parent_obj.get("path"):
                parts.append(parent_obj["path"])
            cur = parent_id
        parts.reverse()
        return posixpath.normpath(posixpath.join("RawLab", *parts))
    return raw_path


def inspect_ios_bundled_looks_packaging(
    pbxproj_path: Path = PBXPROJ,
) -> tuple[set[tuple[str, str]], list[str]]:
    """Return (packaged_pairs, violations) for target RawLab's BundledLooks packaging."""
    data = parse_pbxproj(pbxproj_path)
    objects: dict = data["objects"]

    parent_map: dict[str, str] = {}
    for obj_id, obj in objects.items():
        if isinstance(obj, dict) and obj.get("isa") == "PBXGroup":
            for child in obj.get("children", []):
                parent_map[child] = obj_id

    rawlab_target = None
    for obj in objects.values():
        if isinstance(obj, dict) and obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "RawLab":
            rawlab_target = obj
            break
    if rawlab_target is None:
        raise AssertionError("PBXNativeTarget 'RawLab' not found in project.pbxproj")

    packaged: set[tuple[str, str]] = set()
    violations: list[str] = []

    for phase_id in rawlab_target.get("buildPhases", []):
        phase = objects.get(phase_id, {})
        isa = phase.get("isa")
        if isa not in ("PBXResourcesBuildPhase", "PBXCopyFilesBuildPhase"):
            continue
        if isa == "PBXCopyFilesBuildPhase":
            if phase.get("dstSubfolderSpec") != "7":
                continue
            dst_prefix = phase.get("dstPath", "").strip("/")
        else:
            dst_prefix = ""

        for build_file_id in phase.get("files", []):
            build_file = objects.get(build_file_id, {})
            ref_id = build_file.get("fileRef")
            file_ref = objects.get(ref_id, {})
            repo_rel = _resolve_pbx_path(file_ref, objects, parent_map)
            if repo_rel == "Shared/BundledLooks" or repo_rel.startswith("Shared/BundledLooks/"):
                if file_ref.get("lastKnownFileType") == "folder":
                    violations.append(
                        f"Unfiltered folder reference packaged in {phase.get('name', isa)}: {repo_rel}"
                    )
                name = posixpath.basename(repo_rel)
                bundle_rel = f"{dst_prefix}/{name}" if dst_prefix else name
                packaged.add((bundle_rel, repo_rel))

    # Also ensure no stray unfiltered BundledLooks folder reference exists in PBXFileReference.
    for ref_id, obj in objects.items():
        if isinstance(obj, dict) and obj.get("isa") == "PBXFileReference":
            repo_rel = _resolve_pbx_path(obj, objects, parent_map)
            if repo_rel == "Shared/BundledLooks" and obj.get("lastKnownFileType") == "folder":
                violations.append(f"Stale BundledLooks folder PBXFileReference present: {ref_id}")

    return packaged, violations


def verify_app_bundle(app_path: Path, root: Path = ROOT) -> list[str]:
    """Verify a built RawLab.app contains the exact 60 runtime BundledLooks files and no leaks."""
    errors: list[str] = []
    bundled_dir = app_path / "BundledLooks"
    if not app_path.is_dir():
        return [f"App bundle not found: {app_path}"]
    if not bundled_dir.is_dir():
        return [f"BundledLooks directory missing inside app bundle: {bundled_dir}"]

    expected_bundle_paths = {bundle_rel for bundle_rel, _ in expected_bundled_looks_runtime_files(root)}
    actual_bundle_paths = {
        path.relative_to(app_path).as_posix()
        for path in bundled_dir.rglob("*")
        if path.is_file()
    }

    missing = sorted(expected_bundle_paths - actual_bundle_paths)
    extra = sorted(actual_bundle_paths - expected_bundle_paths)
    if missing:
        errors.append(f"Missing runtime BundledLooks file(s) in {app_path}: {missing}")
    if extra:
        errors.append(f"Unexpected non-runtime BundledLooks file(s) in {app_path}: {extra}")

    for blocked in NON_RUNTIME_NAMES:
        if (app_path / blocked).exists():
            errors.append(f"Forbidden non-runtime file in app root: {blocked}")
    return errors


class IOSBundleHygieneTests(unittest.TestCase):
    def test_pbxproj_packages_exact_runtime_bundled_looks_and_excludes_metadata(self) -> None:
        expected = expected_bundled_looks_runtime_files(ROOT)
        self.assertEqual(len(expected), 60)

        packaged, violations = inspect_ios_bundled_looks_packaging(PBXPROJ)
        self.assertEqual(violations, [], "\n".join(violations))
        self.assertEqual(
            packaged,
            expected,
            f"Missing from pbxproj: {sorted(expected - packaged)}\n"
            f"Unexpected in pbxproj: {sorted(packaged - expected)}",
        )

        packaged_repo_paths = {repo_rel for _, repo_rel in packaged}
        leaked = sorted(non_runtime_bundled_looks_files(ROOT) & packaged_repo_paths)
        self.assertEqual(leaked, [], f"Non-runtime BundledLooks files packaged in pbxproj: {leaked}")

    def test_pbxproj_passes_plutil_lint_when_available(self) -> None:
        plutil = shutil.which("plutil")
        if plutil is None:
            self.skipTest("plutil is only available on macOS")
        result = subprocess.run(
            [plutil, "-lint", str(PBXPROJ)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_app_bundle_verifier_accepts_clean_bundle_and_rejects_leaks_or_omissions(self) -> None:
        expected = expected_bundled_looks_runtime_files(ROOT)
        with tempfile.TemporaryDirectory() as tmpdir:
            app = Path(tmpdir) / "RawLab.app"
            for bundle_rel, _ in expected:
                target = app / bundle_rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("stub", encoding="utf-8")
            self.assertEqual(verify_app_bundle(app, ROOT), [])

            leaked = app / "BundledLooks/Artwork/generated-camera-looks.json"
            leaked.write_text("{}", encoding="utf-8")
            errors = verify_app_bundle(app, ROOT)
            self.assertTrue(any("generated-camera-looks.json" in err for err in errors), errors)
            leaked.unlink()

            leaked_md = app / "BundledLooks/REDISTRIBUTION_BLOCKED.md"
            leaked_md.write_text("blocked", encoding="utf-8")
            errors = verify_app_bundle(app, ROOT)
            self.assertTrue(any("REDISTRIBUTION_BLOCKED.md" in err for err in errors), errors)
            leaked_md.unlink()

            missing_target = app / "BundledLooks/catalog.json"
            missing_target.unlink()
            errors = verify_app_bundle(app, ROOT)
            self.assertTrue(any("catalog.json" in err for err in errors), errors)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Verify a built RawLab.app bundle")
    args, remaining = parser.parse_known_args(argv)
    if args.app is not None:
        errors = verify_app_bundle(args.app, ROOT)
        if errors:
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
            return 1
        print(f"OK: {args.app} packages exact 60 runtime BundledLooks files with zero non-runtime leaks")
        return 0
    unittest.main(argv=[sys.argv[0], *remaining])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
