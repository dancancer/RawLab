"""Reconcile CI Windows test selections against on-disk suites and CMake CTests (P2-23 / P2-24)."""

from __future__ import annotations

from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
WINDOWS_MODELS = ROOT / "scripts/ci/windows-models.ps1"
WIN_TESTS = ROOT / "RawLabWindows/tests"

# Documented inventory partition for RawLabWindows/tests/*.csproj and *.ps1.
CI_MODEL_CSPROJS = {
    "denoise/DenoiseSettingsTests.csproj",
    "editing/EditWorkflow.Tests.csproj",
    "localization/LocalizationChecks.csproj",
    "looks/LookGrouping.Tests.csproj",
    "system-open/SystemOpen.Tests.csproj",
    "updates/UpdateChecks.csproj",
    "updates-sdk/UpdateSdkChecks.csproj",
    "usage/UsageAnalytics.Tests.csproj",
}
CI_NATIVE_BUILD_AND_SELECTIVE_CSPROJS = {
    "RawLabWindows.Tests.csproj",
}
EXCLUDED_CSPROJS = {
    # Built in CI native/build step (ci.yml) to guard WPF compilation, not launched headless.
    "localization-ui/LocalizationUiChecks.csproj": "interactive_wpf_ui_built_only",
    # UI Automation driver requiring an interactive Windows desktop session.
    "ui-automation/RawLabWindows.UiAutomation.csproj": "interactive_desktop_uia",
    # Velopack offline update packaging fixture executed only by updates-sdk/offline.ps1.
    "update-fixture/UpdateFixture.csproj": "installer_offline_fixture",
}

CI_MODEL_PS1S = {
    "BuildScriptChecks.ps1",
    "CheckProcessChecks.ps1",
    "RunnerSelectionChecks.ps1",
}
CI_NATIVE_PS1S = {
    "run-v08.ps1",
}
HELPER_OR_EXCLUDED_PS1S = {
    "CheckProcess.ps1": "dot_sourced_process_runner_helper",
    "run-comparison-native.ps1": "interactive_desktop_uia_harness",
    "updates-sdk/offline.ps1": "velopack_offline_installer_check",
}

# Only checks requiring sony2fuji.dll may opt out of windows-models.ps1 and run under CI native.
NATIVE_ONLY_EDIT_CHECKS = {
    "HDRAssetImportChecks": "--hdr-look-import",
}

# CTests registered in Windows CMake that MUST NOT be selected on headless github-hosted VMs.
KNOWN_INAPPLICABLE_WINDOWS_CTESTS = {
    # Requires a physical/hardware D3D11 adapter (headless windows-2022 fails or SKIPS).
    "acceleration_DJI_20250602164503_0444_D": "requires_hardware_d3d11_gpu",
    "acceleration_DSC06251": "requires_hardware_d3d11_gpu",
    "acceleration_sony_bundled_2383": "requires_hardware_d3d11_gpu",
    "acceleration_sony_windows": "requires_hardware_d3d11_gpu",
    "gpu_photo": "requires_hardware_d3d11_gpu",
    "metal_denoise": "requires_hardware_d3d11_gpu",
    "srgb_look": "requires_hardware_d3d11_gpu",
    # Requires private/external unbundled RAW photos (empty var or missing DSC06251.ARW).
    "atmosphere_raw": "external_raw_or_private_fixture",
    "color_contracts_raw": "external_raw_or_private_fixture",
    "color_grading_raw": "external_raw_or_private_fixture",
    "cpu_parallel_determinism_raw": "external_raw_or_private_fixture",
    "geometry_raw": "external_raw_or_private_fixture",
    "hsl_probe_raw": "external_raw_or_private_fixture",
    "perspective_raw": "external_raw_or_private_fixture",
    "photo_color_raw": "external_raw_or_private_fixture",
    "raw_cache_preview_raw": "external_raw_or_private_fixture",
    "raw_format_photos": "external_raw_or_private_fixture",
    "raw_input": "external_raw_or_private_fixture",
    "raw_noise": "external_raw_or_private_fixture",
    "raw_reuse": "external_raw_or_private_fixture",
    "raw_white_balance": "external_raw_or_private_fixture",
    "rendered_dng_lens_wavelet": "external_raw_or_private_fixture",
    "sony_arw6_photo": "external_raw_or_private_fixture",
    "sony_highlights": "external_raw_or_private_fixture",
    "tone_controls_raw": "external_raw_or_private_fixture",
    "tone_curve_raw": "external_raw_or_private_fixture",
    "wavelet_exposure_cache": "external_raw_or_private_fixture",
    "wavelet_fallback": "external_raw_or_private_fixture",
    "raw_demosaic_xtrans": "external_raw_or_private_fixture",
    # Android GLES / EGL stub shader suite or optional glslang host tool (excluded on desktop CI).
    "compute_denoise_reuse": "gles_or_android_shader_suite",
    "gles_shader": "gles_or_android_shader_suite",
    "gpu_d3d11_hw_photo": "gles_or_android_shader_suite",
    "gpu_gles_binding_order_denoise": "gles_or_android_shader_suite",
    "gpu_gles_binding_order_lut": "gles_or_android_shader_suite",
    "gpu_gles_binding_order_photo": "gles_or_android_shader_suite",
    "gpu_gles_hw_photo": "gles_or_android_shader_suite",
    "gpu_gles_lut_binding": "gles_or_android_shader_suite",
    "gpu_gles_lut_init_failure_binding": "gles_or_android_shader_suite",
    "gpu_gles_lut_init_retry": "gles_or_android_shader_suite",
    "gpu_gles_photo_pixel": "gles_or_android_shader_suite",
    # Excluded explicitly via `-E '^dualdn_onnx$'` in ci.yml (CI full runs DualDN package tests).
    "dualdn_onnx": "excluded_by_ci_e_flag",
}


def _strip_cmake_comments(text: str) -> list[str]:
    """Return logical CMake lines with line-continuations joined and comments stripped."""
    joined: list[str] = []
    current = ""
    for raw in text.splitlines():
        line = re.sub(r"#.*$", "", raw).rstrip()
        if not line and not current:
            continue
        if current:
            current = f"{current} {line.lstrip()}"
        else:
            current = line
        if current.count("(") == current.count(")") and current.strip():
            joined.append(current.strip())
            current = ""
    if current.strip():
        joined.append(current.strip())
    return joined


def _tokenize_cmake(expr: str) -> list[str]:
    tokens: list[str] = []
    i = 0
    while i < len(expr):
        ch = expr[i]
        if ch.isspace():
            i += 1
        elif ch in "()":
            tokens.append(ch)
            i += 1
        elif ch == '"':
            j = expr.find('"', i + 1)
            j = len(expr) if j == -1 else j
            tokens.append(expr[i + 1 : j])
            i = j + 1
        else:
            j = i
            while j < len(expr) and not expr[j].isspace() and expr[j] not in "()":
                j += 1
            tokens.append(expr[i:j])
            i = j
    return tokens


def _eval_cmake_condition(expr: str, env: dict[str, object]) -> bool:
    """Evaluate CMake `if(...)` boolean expressions over known Windows CI variables."""
    tokens = _tokenize_cmake(expr)
    pos = 0

    def resolve_operand(tok: str) -> str:
        def repl(match: re.Match[str]) -> str:
            val = env.get(match.group(1), "")
            if isinstance(val, bool):
                return "ON" if val else ""
            return str(val)

        return re.sub(r"\$\{([^}]+)\}", repl, tok)

    def as_bool(tok: str) -> bool:
        if tok in env:
            return bool(env[tok])
        resolved = resolve_operand(tok)
        return resolved.upper() not in ("", "0", "OFF", "FALSE", "NO", "N", "IGNORE", "NOTFOUND")

    def parse_or() -> bool:
        val = parse_and()
        while pos < len(tokens) and tokens[pos] == "OR":
            nonlocal_pos_inc()
            rhs = parse_and()
            val = val or rhs
        return val

    def nonlocal_pos_inc() -> None:
        nonlocal pos
        pos += 1

    def parse_and() -> bool:
        val = parse_not()
        while pos < len(tokens) and tokens[pos] == "AND":
            nonlocal_pos_inc()
            rhs = parse_not()
            val = val and rhs
        return val

    def parse_not() -> bool:
        if pos < len(tokens) and tokens[pos] == "NOT":
            nonlocal_pos_inc()
            return not parse_not()
        return parse_primary()

    def parse_primary() -> bool:
        nonlocal pos
        if pos >= len(tokens):
            return False
        if tokens[pos] == "(":
            pos += 1
            val = parse_or()
            if pos < len(tokens) and tokens[pos] == ")":
                pos += 1
            return val
        if pos + 2 < len(tokens) and tokens[pos + 1] in ("STREQUAL", "MATCHES", "EQUAL"):
            lhs_tok, op, rhs_tok = tokens[pos], tokens[pos + 1], tokens[pos + 2]
            pos += 3
            lhs = resolve_operand(lhs_tok if "${" in lhs_tok else f"${{{lhs_tok}}}")
            if "${" not in lhs_tok and lhs_tok not in env:
                lhs = lhs_tok
            rhs = resolve_operand(rhs_tok)
            if op == "STREQUAL":
                return lhs == rhs
            if op == "MATCHES":
                return re.search(rhs, lhs) is not None
            return lhs == rhs
        tok = tokens[pos]
        pos += 1
        if tok in ("TARGET", "EXISTS", "POLICY", "DEFINED"):
            if pos < len(tokens):
                pos += 1
            return True
        return as_bool(tok)

    return parse_or()


def _parse_cmake_ctests(path: Path, env: dict[str, object]) -> set[str]:
    """Parse `add_test(NAME ...)` from a CMake file under the supplied variable assignment."""
    found: set[str] = set()
    lines = _strip_cmake_comments(path.read_text(encoding="utf-8"))
    # Stack entries are ("if", active, branch_taken) or ("foreach", var, items, start_idx, iter_idx, local_env)
    env = dict(env)

    def walk(idx_start: int = 0) -> None:
        if_stack: list[list[object]] = []
        i = idx_start
        while i < len(lines):
            stmt = lines[i]
            m_if = re.match(r"^if\s*\((.*)\)$", stmt)
            if m_if:
                parent_active = all(bool(frame[1]) for frame in if_stack)
                cond = _eval_cmake_condition(m_if.group(1), env) if parent_active else False
                if_stack.append([parent_active, cond, cond])
                i += 1
                continue
            m_elif = re.match(r"^elseif\s*\((.*)\)$", stmt)
            if m_elif and if_stack:
                parent_active, _, taken = if_stack[-1]
                cond = _eval_cmake_condition(m_elif.group(1), env) if (parent_active and not taken) else False
                if_stack[-1] = [parent_active, cond, bool(taken) or cond]
                i += 1
                continue
            if re.match(r"^else\s*\(\)$", stmt) and if_stack:
                parent_active, _, taken = if_stack[-1]
                cond = bool(parent_active) and not bool(taken)
                if_stack[-1] = [parent_active, cond, True]
                i += 1
                continue
            if re.match(r"^endif\s*\(.*\)$", stmt) and if_stack:
                if_stack.pop()
                i += 1
                continue

            active = all(bool(frame[1]) for frame in if_stack)
            m_foreach = re.match(r"^foreach\s*\((.*)\)$", stmt)
            if m_foreach:
                # Find matching endforeach taking nested foreach blocks into account.
                depth = 1
                j = i + 1
                while j < len(lines) and depth > 0:
                    if re.match(r"^foreach\s*\(", lines[j]):
                        depth += 1
                    elif re.match(r"^endforeach\s*\(.*\)$", lines[j]):
                        depth -= 1
                    j += 1
                body_end = j - 1
                if active:
                    toks = _tokenize_cmake(m_foreach.group(1))
                    var = toks[0]
                    items = toks[3:] if len(toks) >= 3 and toks[1] == "IN" and toks[2] == "ITEMS" else toks[1:]
                    saved = env.get(var)
                    for item in items:
                        # Map explicit `Examples/...` fixture paths to short stem names as CMake does.
                        env[var] = item
                        _run_block(lines[i + 1 : body_end], env, found)
                    if saved is None:
                        env.pop(var, None)
                    else:
                        env[var] = saved
                i = j
                continue

            if active:
                _process_active_statement(stmt, env, found)
            i += 1

    walk(0)
    return found


def _run_block(sub_lines: list[str], env: dict[str, object], found: set[str]) -> None:
    """Execute a `foreach` body containing possible inner `if(...)` / `continue()` statements."""
    if_stack: list[list[object]] = []
    for stmt in sub_lines:
        m_if = re.match(r"^if\s*\((.*)\)$", stmt)
        if m_if:
            parent_active = all(bool(frame[1]) for frame in if_stack)
            cond = _eval_cmake_condition(m_if.group(1), env) if parent_active else False
            if_stack.append([parent_active, cond, cond])
            continue
        if re.match(r"^else\s*\(\)$", stmt) and if_stack:
            parent_active, _, taken = if_stack[-1]
            if_stack[-1] = [parent_active, bool(parent_active) and not bool(taken), True]
            continue
        if re.match(r"^endif\s*\(.*\)$", stmt) and if_stack:
            if_stack.pop()
            continue
        active = all(bool(frame[1]) for frame in if_stack)
        if not active:
            continue
        if re.match(r"^continue\s*\(\)$", stmt):
            return
        _process_active_statement(stmt, env, found)


def _process_active_statement(stmt: str, env: dict[str, object], found: set[str]) -> None:
    m_gfc = re.match(r"^get_filename_component\s*\(\s*([A-Za-z0-9_]+)\s+(.*?)\s+NAME_WE\s*\)$", stmt)
    if m_gfc:
        arg_toks = _tokenize_cmake(m_gfc.group(2))
        if arg_toks:
            raw = re.sub(r"\$\{([^}]+)\}", lambda m: str(env.get(m.group(1), "")), arg_toks[0])
            env[m_gfc.group(1)] = Path(raw).stem
        return

    m_set = re.match(r"^set\s*\(\s*([A-Za-z0-9_]+)\s+(.*)\)$", stmt)
    if m_set and m_set.group(1) not in env:
        val_toks = _tokenize_cmake(m_set.group(2))
        if val_toks and "CACHE" not in val_toks:
            val = val_toks[0]
            if not val.startswith("${"):
                env[m_set.group(1)] = val not in ("0", "OFF", "FALSE", "") if val in ("ON", "OFF", "TRUE", "FALSE") else val

    m_test = re.match(r"^add_test\s*\(\s*NAME\s+([^\s)]+)", stmt)
    if not m_test:
        return
    name = re.sub(r"\$\{([^}]+)\}", lambda m: str(env.get(m.group(1), "")), m_test.group(1))
    found.add(name)


def windows_cmake_ctests(ai_denoise: bool) -> set[str]:
    """Compute all Windows Release CTest targets registered by build.ps1's CMake configuration."""
    env: dict[str, object] = {
        "WIN32": True,
        "MSVC": True,
        "APPLE": False,
        "IOS": False,
        "ANDROID": False,
        "UNIX": False,
        "BUILD_TESTING": True,
        "BUILD_CLI": True,
        "SONY2FUJI_TEST_PORTABLE_HDR": True,
        "SONY2FUJI_ENABLE_GPU": True,
        "SONY2FUJI_ENABLE_X3F": True,
        "SONY2FUJI_ENABLE_CHROMA_DENOISE": True,
        "SONY2FUJI_ENABLE_WAVELET_DENOISE": True,
        "SONY2FUJI_ENABLE_DNGSDK": True,
        "SONY2FUJI_ENABLE_LENSFUN": True,
        "SONY2FUJI_ENABLE_OPENMP": False,
        "SONY2FUJI_LIBRAW_RAWLAB_PATCHES": True,
        "SONY2FUJI_ENABLE_AI_DENOISE": ai_denoise,
        "SONY2FUJI_ENABLE_DIRECTML": ai_denoise,
        "RAWLAB_DUALDN_TEST_PACKAGE": ai_denoise,
        "RAWLAB_DUALDN_TEST_MODEL": False,
        "Python3_Interpreter_FOUND": True,
        "RAWLAB_SHADER_PYTHON": True,
        "RAWLAB_GLSLANG": True,
        "SONY2FUJI_DENOISE_LIBRARIES": True,
        "RAWLAB_X3F_RUST_TARGET": "x86_64-pc-windows-msvc",
        "CMAKE_CXX_COMPILER_ID": "MSVC",
    }
    tests = set()
    tests |= _parse_cmake_ctests(ROOT / "lutools/CMakeLists.txt", env)
    tests |= _parse_cmake_ctests(ROOT / "lutools/cmake/ai-denoise.cmake", env)
    tests |= _parse_cmake_ctests(ROOT / "RawLabWindows/native/CMakeLists.txt", env)
    tests |= _parse_cmake_ctests(ROOT / "RawLabWindows/Rendering/HDR/CMakeLists.txt", env)
    return tests


class WindowsInventoryTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        self.windows_steps = "\n".join(
            step.get("run", "") for step in self.workflow["jobs"]["windows"]["steps"]
        )
        self.windows_models_ps1 = WINDOWS_MODELS.read_text(encoding="utf-8")

    def test_windows_projects_and_scripts_are_partitioned_without_drift(self):
        actual_csprojs = {
            p.relative_to(WIN_TESTS).as_posix() for p in WIN_TESTS.rglob("*.csproj")
        }
        accounted_csprojs = CI_MODEL_CSPROJS | CI_NATIVE_BUILD_AND_SELECTIVE_CSPROJS | set(EXCLUDED_CSPROJS)
        self.assertEqual(actual_csprojs - accounted_csprojs, set(),
                         "Uncategorized RawLabWindows/tests .csproj suites exist on disk")
        self.assertEqual(accounted_csprojs - actual_csprojs, set(),
                         "Listed RawLabWindows/tests .csproj suites do not exist on disk")

        for proj in sorted(CI_MODEL_CSPROJS):
            self.assertIn(proj, self.windows_models_ps1,
                          f"Model suite {proj} missing from scripts/ci/windows-models.ps1")
        for proj in sorted(CI_NATIVE_BUILD_AND_SELECTIVE_CSPROJS):
            self.assertIn(f"RawLabWindows/tests/{proj}", self.windows_steps,
                          f"Native suite {proj} missing from ci.yml windows steps")

        actual_ps1s = {
            p.relative_to(WIN_TESTS).as_posix() for p in WIN_TESTS.rglob("*.ps1")
        }
        accounted_ps1s = CI_MODEL_PS1S | CI_NATIVE_PS1S | set(HELPER_OR_EXCLUDED_PS1S)
        self.assertEqual(actual_ps1s - accounted_ps1s, set(),
                         "Uncategorized RawLabWindows/tests .ps1 scripts exist on disk")
        self.assertEqual(accounted_ps1s - actual_ps1s, set(),
                         "Listed RawLabWindows/tests .ps1 scripts do not exist on disk")

        for script in sorted(CI_MODEL_PS1S | CI_NATIVE_PS1S):
            self.assertIn(f"RawLabWindows/tests/{script}", self.windows_steps,
                          f"Headless Windows script RawLabWindows/tests/{script} is not invoked in ci.yml")

        # Bidirectional check: every RawLabWindows/tests/ path mentioned in ci.yml or windows-models.ps1 exists.
        refs = set(re.findall(r"RawLabWindows/tests/[A-Za-z0-9_./-]+\.(?:csproj|ps1)",
                              self.windows_steps + "\n" + self.windows_models_ps1))
        for rel_from_tests in re.findall(r"\$root/([A-Za-z0-9_./-]+\.csproj)", self.windows_models_ps1):
            refs.add(f"RawLabWindows/tests/{rel_from_tests}")
        for ref in sorted(refs):
            self.assertTrue((ROOT / ref).is_file(), f"CI references missing file: {ref}")

    def test_edit_workflow_checks_and_banners_are_admitted(self):
        editing_dir = WIN_TESTS / "editing"
        csproj = ET.parse(editing_dir / "EditWorkflow.Tests.csproj")
        prog_text = (editing_dir / "Program.cs").read_text(encoding="utf-8")

        check_files: dict[str, Path] = {
            p.stem: p for p in editing_dir.glob("*Checks.cs")
        }
        for el in csproj.iter("Compile"):
            inc = el.attrib.get("Include", "")
            if inc.endswith("Checks.cs"):
                resolved = (editing_dir / inc).resolve()
                self.assertTrue(resolved.is_file(), f"Missing linked EditWorkflow check: {inc}")
                check_files[resolved.stem] = resolved

        # Split Program.cs into early return `--*` flags section vs unconditional default execution body.
        default_start = prog_text.index('if (args.Contains("--master-recipes"))')
        # Checks run unconditionally are those called outside an `args.Contains(...)` return branch.
        unconditional_text = re.sub(
            r'if\s*\(\s*args\.Contains\([^\)]+\)\s*\)\s*\{[^}]*\}', "", prog_text
        )
        # Also include calls in default section (unconditional_text still contains lines 58..end except the return blocks).
        self.assertGreater(default_start, 0)

        for name, path in sorted(check_files.items()):
            with self.subTest(check=name):
                src = path.read_text(encoding="utf-8")
                self.assertTrue(
                    "PASS" in src,
                    f"{name} ({path.relative_to(ROOT)}) does not emit a PASS banner/assertion message",
                )
                if name in NATIVE_ONLY_EDIT_CHECKS:
                    flag = NATIVE_ONLY_EDIT_CHECKS[name]
                    self.assertIn(flag, prog_text, f"Flag {flag} for {name} missing in editing/Program.cs")
                    self.assertIn(f"{name}.Run", prog_text, f"{name}.Run missing in editing/Program.cs")
                    self.assertIn(flag, self.windows_steps,
                                  f"Native-only EditWorkflow check {name} ({flag}) is never invoked in ci.yml")
                    self.assertIn("RAWLAB_TEST_NATIVE_HDR_LIBRARY", self.windows_steps,
                                  f"ci.yml must bind RAWLAB_TEST_NATIVE_HDR_LIBRARY when running {flag}")
                else:
                    self.assertRegex(
                        unconditional_text,
                        rf"\b{re.escape(name)}\.Run\s*\(",
                        f"{name} is not unconditionally executed on the default EditWorkflow.Tests path",
                    )

    def test_run_v08_and_runner_selection_and_program_flags_reconcile(self):
        run_v08 = (WIN_TESTS / "run-v08.ps1").read_text(encoding="utf-8")
        runner_checks = (WIN_TESTS / "RunnerSelectionChecks.ps1").read_text(encoding="utf-8")
        prog_text = (WIN_TESTS / "Program.cs").read_text(encoding="utf-8")

        def extract_names(text: str) -> list[str]:
            match = re.search(r"\$names\s*=\s*@\(([^)]+)\)", text, re.S)
            self.assertIsNotNone(match, "Could not locate $names array")
            return re.findall(r"'([^']+)'", match.group(1))

        v08_names = extract_names(run_v08)
        sel_names = extract_names(runner_checks)
        # RunnerSelectionChecks.ps1 puts baseline non-AI suites in $names and checks 'ai-window' explicitly.
        self.assertIn("ai-window", v08_names, "'ai-window' missing from run-v08.ps1 $names")
        self.assertIn("'ai-window'", runner_checks, "'ai-window' selection checks missing from RunnerSelectionChecks.ps1")
        self.assertEqual([n for n in v08_names if n != "ai-window"], sel_names,
                         "run-v08.ps1 $names drifted from RunnerSelectionChecks.ps1")

        # Validate CI -Only selection items exist in run-v08.ps1 $names.
        match_only = re.search(r"run-v08\.ps1[^\n]*-Only '([^']+)'", self.windows_steps)
        self.assertIsNotNone(match_only)
        ci_only = [s.strip() for s in match_only.group(1).split(",")]
        for suite in ci_only:
            self.assertIn(suite, v08_names, f"ci.yml -Only suite '{suite}' does not exist in run-v08.ps1")

        # Separate build/sub-project suites from RawLabWindows.Tests `--<flag>` dispatches.
        non_flag_suites = {
            "build", "build-localization-ui", "editing", "looks", "denoise-model",
            "localization", "updates", "localization-ui",
        }
        explicit_flag_aliases = {
            "localization-admission": "--default-isolation",
        }
        prog_flags = set(re.findall(r'"(--[a-z0-9-]+)"', prog_text))
        for suite in v08_names:
            if suite in non_flag_suites:
                continue
            expected_flag = explicit_flag_aliases.get(suite, f"--{suite}")
            if f"'{suite}'" in run_v08.split("$modes", 1)[-1]:
                # Dynamic `$modes` suites invoke `--$name`.
                pass
            self.assertIn(expected_flag, prog_flags,
                          f"run-v08.ps1 suite '{suite}' expects missing Program.cs flag {expected_flag}")

    def test_windows_cmake_ctests_reconcile_with_ci_allowlist(self):
        match_tests = re.search(r"(?m)^\s*\$tests\s*=\s*'([^']+)'", self.windows_steps)
        self.assertIsNotNone(match_tests, "Could not find `$tests = '...'` allowlist in ci.yml windows job")
        pattern_text = match_tests.group(1)
        compiled = re.compile(pattern_text)

        self.assertTrue(pattern_text.startswith("^(") and pattern_text.endswith(")$"),
                        "$tests allowlist must stay anchored with `^(...)$`")
        alternatives = pattern_text[2:-2].split("|")
        self.assertEqual(len(alternatives), len(set(alternatives)),
                         "Duplicate alternatives in ci.yml $tests allowlist")

        exclude_match = re.search(r"'-E',\s*'([^']+)'", self.windows_steps)
        exclude_re = re.compile(exclude_match.group(1)) if exclude_match else None

        ctests_no_ai = windows_cmake_ctests(ai_denoise=False)
        ctests_ai = windows_cmake_ctests(ai_denoise=True)
        all_windows_ctests = ctests_no_ai | ctests_ai

        # 1) "selected but does not exist": every branch of `$tests` must match >= 1 Windows CTest.
        unmatched_branches = [
            alt for alt in alternatives
            if not any(re.fullmatch(alt, name) for name in all_windows_ctests)
        ]
        self.assertEqual(
            unmatched_branches, [],
            f"ci.yml $tests contains patterns matching no Windows CTest: {unmatched_branches}",
        )

        # 2) "exists/built but never selected": ctests - allowlist - KNOWN_INAPPLICABLE_WINDOWS_CTESTS == empty.
        for label, ctests in (("ai_off", ctests_no_ai), ("ai_on", ctests_ai)):
            with self.subTest(mode=label):
                selected = {
                    name for name in ctests
                    if compiled.search(name) and not (exclude_re and exclude_re.search(name))
                }
                uncovered = sorted(ctests - selected - set(KNOWN_INAPPLICABLE_WINDOWS_CTESTS))
                self.assertEqual(
                    uncovered, [],
                    f"Windows CTests built in {label} are neither selected in ci.yml nor documented inapplicable: {uncovered}",
                )
                overlap = sorted(selected & set(KNOWN_INAPPLICABLE_WINDOWS_CTESTS))
                self.assertEqual(
                    overlap, [],
                    f"Inapplicable Windows CTests must not be selected by ci.yml in {label}: {overlap}",
                )


if __name__ == "__main__":
    unittest.main()
