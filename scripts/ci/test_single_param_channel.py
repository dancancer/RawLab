"""Production code passes edit state only through the canonical recipe JSON channel.

The C ABI still exports the per-feature sticky setters (`sony2fuji_session_set_hsl`,
`..._set_tone_curves_v2`, `..._set_lens_correction_v2`, ...) and the nested
`sony2fuji_hdr_request_v1..v9` structs with the HDR functions that take them, but they are frozen
compatibility ABI
(lutools/AGENTS.md, "Interface & Layering Discipline"). Clients and the CLI send edit state through
`sony2fuji_apply_params`, `sony2fuji_session_render` with JSON and the `*_json` HDR entry points.
Setters that configure runtime handles or input metadata are not edit state and stay allowed.

Declarations count as references: Windows keeps ABI completeness by listing intentionally unbound
functions in RawLabWindows/tests/editing/AbiLayoutChecks.cs (UnboundAbiFunctions), not by binding
them in Core/Native.cs, so production sources need no declaration-only exception.
"""

from __future__ import annotations

from pathlib import Path
import re
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]

# (directory, top-level subdirectories that are not production code)
SCOPES = (
    ("RawLab/RawLab", ()),
    ("RawLabMac/Sources", ()),
    ("RawLabAndroid/app/src/main", ()),
    ("RawLabWindows", ("tests",)),
    # Shared/fixtures holds test inputs, including abi-layout-v1.json, which names every ABI symbol.
    ("Shared", ("tests", "fixtures")),
    ("lutools/src/cli", ()),
)
SOURCE_SUFFIXES = {".swift", ".kt", ".kts", ".java", ".cs", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm"}
# Local build output that may sit inside a scope in a developer checkout.
BUILD_DIR_NAMES = {"bin", "obj", "build", ".build", ".gradle", ".cxx"}

ALLOWED_SESSION_SETTERS = frozenset({
    "sony2fuji_session_set_gpu_config",
    "sony2fuji_session_set_cancellation_callback",
    "sony2fuji_session_set_hdr_progress_callback",
    "sony2fuji_session_set_lens_database",
    "sony2fuji_session_set_display_lens_metadata",
    "sony2fuji_session_set_ai_denoise",
    "sony2fuji_session_set_ai_device",
    "sony2fuji_session_set_interactive_preview",
    "sony2fuji_session_set_viewport_preview",
    "sony2fuji_session_set_viewport_roi",
})

# (path, symbol) pairs that may keep a frozen-channel reference. Each entry needs a reason, and
# test_known_exceptions_are_still_needed fails once the reference is gone so the entry is removed.
KNOWN_EXCEPTIONS = frozenset({
    # iOS paste-adjustments lens check inspects lenses on the long-lived preview session
    # (withRawSession(reuse: true)). sony2fuji_apply_params would also reset that session's other
    # edit state and caches (for example the dehaze analysis). iOS re-applies full params before each
    # render, so the cost would be cache invalidation rather than lost edits, but the swap is not
    # state-neutral.
    ("RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Lens.swift", "sony2fuji_session_set_lens_correction_v2"),
})

# HDR entry points that take a sony2fuji_hdr_request_v* pointer; each has a `_json` sibling. Matching
# the function names also catches bindings that declare the request struct under another name (C#).
FROZEN_HDR_FUNCTIONS = frozenset({
    "sony2fuji_hdr_render",
    "sony2fuji_hdr_render_roi",
    "sony2fuji_hdr_render_camera_raw_roi",
    "sony2fuji_hdr_render_file_roi",
    "sony2fuji_hdr_roi_source_bounds",
    "sony2fuji_hdr_geometry_size",
    "sony2fuji_hdr_create_hsl_probe",
    "sony2fuji_hdr_export_stream",
    "sony2fuji_hdr_export_tiled",
    "sony2fuji_hdr_export_proraw",
})

SETTER_RE = re.compile(r"\bsony2fuji_session_set_[A-Za-z0-9_]+")
HDR_REQUEST_RE = re.compile(r"\bsony2fuji_hdr_request_v[0-9]+\b")
HDR_FUNCTION_RE = re.compile(r"\bsony2fuji_hdr_[A-Za-z0-9_]+")
# EditRecipe (sony2fuji/edit_recipe.h) helpers that build the nested request structs.
RECIPE_REQUEST_RE = re.compile(r"\btoHDR(?:Render)?Request(?:V9)?\b")


def frozen_references(text: str) -> list[tuple[int, str]]:
    found = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for match in SETTER_RE.finditer(line):
            if match.group(0) not in ALLOWED_SESSION_SETTERS:
                found.append((lineno, match.group(0)))
        for match in HDR_FUNCTION_RE.finditer(line):
            if match.group(0) in FROZEN_HDR_FUNCTIONS:
                found.append((lineno, match.group(0)))
        for regex in (HDR_REQUEST_RE, RECIPE_REQUEST_RE):
            for match in regex.finditer(line):
                found.append((lineno, match.group(0)))
    return found


def production_sources(root: Path) -> dict[str, list[Path]]:
    files: dict[str, list[Path]] = {}
    for rel_dir, excluded in SCOPES:
        base = root / rel_dir
        files[rel_dir] = []
        for path in sorted(base.rglob("*")):
            if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
                continue
            parts = path.relative_to(base).parts
            if parts[0] in excluded or BUILD_DIR_NAMES.intersection(parts[:-1]):
                continue
            files[rel_dir].append(path)
    return files


def scan(root: Path) -> tuple[list[str], set[tuple[str, str]]]:
    """Return (violations, exceptions that matched a reference)."""
    violations: list[str] = []
    used: set[tuple[str, str]] = set()
    for rel_dir, paths in production_sources(root).items():
        if not paths:
            violations.append(f"{rel_dir}: no production sources found; update SCOPES if the tree moved")
        for path in paths:
            rel = path.relative_to(root).as_posix()
            for lineno, symbol in frozen_references(path.read_text(encoding="utf-8", errors="replace")):
                if (rel, symbol) in KNOWN_EXCEPTIONS:
                    used.add((rel, symbol))
                else:
                    violations.append(f"{rel}:{lineno}: frozen edit channel {symbol}; use canonical recipe JSON")
    return violations, used


class SingleParamChannelTests(unittest.TestCase):
    def test_production_sources_use_only_the_canonical_channel(self) -> None:
        violations, _ = scan(ROOT)
        self.assertEqual(violations, [], "\n".join(violations))

    def test_known_exceptions_are_still_needed(self) -> None:
        _, used = scan(ROOT)
        stale = sorted(KNOWN_EXCEPTIONS - used)
        self.assertEqual(stale, [], f"Remove stale KNOWN_EXCEPTIONS entries: {stale}")

    def test_detector_separates_runtime_setters_from_frozen_channel(self) -> None:
        allowed = "\n".join([
            "sony2fuji_session_set_gpu_config(session, &config)",
            "Native.sony2fuji_session_set_viewport_roi(handle, ref roi);",
            "sony2fuji_session_set_cancellation_callback(session, nil, nil)",
            "sony2fuji_apply_params(session, json)",
            "sony2fuji_hdr_render_json(session, &source, &options, json, &result, &diagnostic);",
            "sony2fuji_hdr_render_roi_json(session, &source, &options, json, &roi, &result, &out, &diag);",
            "Native.sony2fuji_hdr_export_proraw_json(session, path, ref options, json, ref config, 1, tmp, out, ref r, ref d);",
            "sony2fuji_hdr_decode_camera_raw(session, path, &options, &result, &diagnostic)",
            "sony2fuji_hdr_release_pair(&pair)",
            "sony2fuji_session_get_lens_report_v2(session, &report)",
            "// sony2fuji_hdr_request_v* stays frozen",
        ])
        self.assertEqual(frozen_references(allowed), [])
        frozen = (
            "sony2fuji_session_set_hsl(session, &config)",
            "return sony2fuji_session_set_tone_curves_v2(session, &config)",
            "internal static extern int sony2fuji_session_set_lens_correction_v2(",
            "sony2fuji_session_set_viewport_roi_v2(session, &roi)",
            "sony2fuji_hdr_request_v9 request{};",
            "sizeof(sony2fuji_hdr_request_v1)",
            "sony2fuji_hdr_render(session, &source, request, &result, &diagnostic);",
            "internal static extern int sony2fuji_hdr_export_proraw(IntPtr session, string path, ref HdrRequest request,",
            "status = sony2fuji_hdr_render_file_roi(session, file, request, &roi, &result, &out, &diag)",
            "sony2fuji_hdr_geometry_size(w, h, &request, &ow, &oh, &diag)",
            "const auto request = recipe.toHDRRenderRequestV9();",
        )
        for snippet in frozen:
            with self.subTest(snippet=snippet):
                self.assertEqual(len(frozen_references(snippet)), 1)

    def test_sandbox_turns_red_on_injected_frozen_setter(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rawlab-param-channel-") as tmp:
            sandbox = Path(tmp)
            for rel_dir, _ in SCOPES:
                shutil.copytree(ROOT / rel_dir, sandbox / rel_dir,
                                ignore=lambda _dir, names: [n for n in names if Path(n).suffix
                                                            and Path(n).suffix not in SOURCE_SUFFIXES])
            self.assertEqual(scan(sandbox)[0], [])
            target = sandbox / "lutools/src/cli/agent_commands.cpp"
            target.write_text(target.read_text(encoding="utf-8") +
                              "\nvoid legacy(sony2fuji_session* s) { sony2fuji_session_set_hsl(s, nullptr); }\n",
                              encoding="utf-8")
            violations = scan(sandbox)[0]
            self.assertEqual(len(violations), 1, violations)
            self.assertIn("lutools/src/cli/agent_commands.cpp:", violations[0])
            self.assertIn("sony2fuji_session_set_hsl", violations[0])


if __name__ == "__main__":
    unittest.main()
