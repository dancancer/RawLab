"""Enforce CLI layering: lutools/src/cli/ may only depend on public sony2fuji/ headers."""

from __future__ import annotations

from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CLI_DIR = ROOT / "lutools/src/cli"

CLI_SOURCE_SUFFIXES = {".h", ".hpp", ".c", ".cpp", ".cc", ".mm"}
CLI_HEADER_SUFFIXES = {".h", ".hpp"}
FORBIDDEN_PRIVATE_PREFIXES = ("core/", "platform/", "gpu/", "ffi/")
ALLOWED_QUOTED_PREFIXES = ("sony2fuji/", "nlohmann/")

INCLUDE_RE = re.compile(r'^\s*#\s*include\s*([<"])([^>"]+)[>"]')


def _normalize_include_target(target: str) -> str:
    normalized = target.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def _has_parent_traversal(target: str) -> bool:
    return ".." in PurePosixPath(target).parts


def lint_cli_source(
    rel_path: str,
    text: str,
    allowed_local_headers: set[str] | None = None,
) -> list[str]:
    local_headers = allowed_local_headers if allowed_local_headers is not None else set()
    violations: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        match = INCLUDE_RE.match(line)
        if not match:
            continue
        delimiter, raw_target = match.groups()
        end_delim = ">" if delimiter == "<" else '"'
        target = _normalize_include_target(raw_target)
        lowered = target.lower()

        if _has_parent_traversal(target):
            violations.append(
                f"{rel_path}:{lineno}: relative parent include {delimiter}{raw_target}{end_delim} is forbidden in CLI"
            )
            continue

        if lowered.startswith(FORBIDDEN_PRIVATE_PREFIXES):
            violations.append(
                f"{rel_path}:{lineno}: private header include {delimiter}{raw_target}{end_delim} is forbidden in CLI"
            )
            continue

        if delimiter == '"':
            if target.startswith(ALLOWED_QUOTED_PREFIXES) or target in local_headers:
                continue
            violations.append(
                f'{rel_path}:{lineno}: quoted include "{raw_target}" is outside CLI allow-list '
                f'(must be a local CLI header or start with {ALLOWED_QUOTED_PREFIXES})'
            )

    return violations


def find_cli_private_include_violations(cli_dir: Path) -> list[str]:
    if not cli_dir.is_dir():
        return [f"Missing CLI source directory: {cli_dir}"]

    source_files = sorted(
        p for p in cli_dir.rglob("*")
        if p.is_file() and p.suffix in CLI_SOURCE_SUFFIXES
    )
    if not source_files:
        return [f"No CLI source files found under: {cli_dir}"]

    allowed_local_headers = {
        p.relative_to(cli_dir).as_posix()
        for p in cli_dir.rglob("*")
        if p.is_file() and p.suffix in CLI_HEADER_SUFFIXES
    }

    violations: list[str] = []
    for path in source_files:
        rel = path.relative_to(cli_dir).as_posix()
        text = path.read_text(encoding="utf-8")
        violations.extend(lint_cli_source(rel, text, allowed_local_headers))
    return violations


class CliLayeringTests(unittest.TestCase):
    def test_cli_directory_has_no_private_includes(self) -> None:
        source_files = [
            p for p in CLI_DIR.rglob("*")
            if p.is_file() and p.suffix in CLI_SOURCE_SUFFIXES
        ]
        self.assertGreaterEqual(len(source_files), 6, "Expected >= 6 CLI source/header files")
        violations = find_cli_private_include_violations(CLI_DIR)
        self.assertEqual(violations, [], "\n".join(violations))

    def test_positive_allowed_includes_pass(self) -> None:
        local = {"agent_commands.h", "bsh_cli_report.h", "raw_info.h"}
        snippet = "\n".join(
            [
                '#include "agent_commands.h"',
                '#include "bsh_cli_report.h"',
                '#include "raw_info.h"',
                '#include "sony2fuji/edit_recipe.h"',
                '#include "sony2fuji/ffi/sony2fuji_c.h"',
                '#include "sony2fuji/ffi/sony2fuji_hdr.h"',
                '#include "nlohmann/json.hpp"',
                '#include <libraw/libraw.h>',
                '#include <filesystem>',
                '#include <windows.h>',
            ]
        )
        self.assertEqual(lint_cli_source("cli_ok.cpp", snippet, local), [])

    def test_negative_lint_catches_synthetic_private_includes(self) -> None:
        local = {"agent_commands.h", "bsh_cli_report.h", "raw_info.h"}
        cases = (
            '#include "core/pipeline.h"',
            '#include "core/bsh_diagnostics.h"',
            '#include "core/edit_recipe_params.h"',
            '#include "core/x3f_processor.h"',
            '#include "core/file_path.h"',
            '#include "platform/display_image.h"',
            '#include "gpu/lut_gpu.h"',
            '#include "ffi/session_internal.h"',
            '#include <core/pipeline.h>',
            '#include <platform/display_image.h>',
            '#include <gpu/lut_gpu.h>',
            '#include <ffi/hdr_session.h>',
            '#  include "../core/bsh_diagnostics.h"',
            '#include <../platform/display_image.h>',
            '#include "unknown_private/helper.h"',
        )
        for snippet in cases:
            with self.subTest(snippet=snippet):
                violations = lint_cli_source("bad_cli.cpp", snippet + "\n", local)
                self.assertNotEqual(violations, [], f"Expected violation for: {snippet}")

    def test_negative_sandbox_directory_fails_on_injected_violation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rawlab-cli-layering-") as tmp:
            sandbox_cli = Path(tmp) / "cli"
            shutil.copytree(CLI_DIR, sandbox_cli)
            self.assertEqual(find_cli_private_include_violations(sandbox_cli), [])

            target = sandbox_cli / "agent_commands.cpp"
            target.write_text(
                '#include "core/pipeline.h"\n' + target.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            violations = find_cli_private_include_violations(sandbox_cli)
            self.assertEqual(len(violations), 1)
            self.assertIn("agent_commands.cpp:1:", violations[0])
            self.assertIn("core/pipeline.h", violations[0])


if __name__ == "__main__":
    unittest.main()
