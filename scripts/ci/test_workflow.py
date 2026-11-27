"""Semantic invariant guards for the hosted CI workflows."""
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

import yaml

if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from affected_platforms import EDIT_JOB, PLATFORMS, SELECT_JOB, macos_matrix, windows_runner


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
CLEANUP = ROOT / ".github/workflows/pr-cache-cleanup.yml"
ACTIONLINT = ROOT / ".github/actionlint.yaml"
APPLE_MODELS = ROOT / "scripts/ci/apple-models.sh"
WINDOWS_MODELS = ROOT / "scripts/ci/windows-models.ps1"
STANDARD_HOSTED_PREFIXES = ("ubuntu-", "windows-", "macos-")
ALLOWED_ARTIFACT_EXTENSIONS = (".log", ".json", ".jsonl", ".xml")
NATIVE_BUILD_MARKERS = (
    "native_cache.py",
    "build-framework.sh",
    "RawLabMac/build.sh",
    "RawLabWindows/build.ps1",
    "assembleDebug",
    "assembleRelease",
    "run-v08.ps1",
)
UI_TEST_MARKERS = (
    "test-without-building",
    "connectedDebugAndroidTest",
    "hdr-rendition-ui.sh",
    "update-ui.sh",
    "offline.ps1",
    "horizontal-picker-native.sh",
    "mac-straighten-preview.sh",
    "parameter-value.sh",
    "mac-canvas-input.sh",
)


def _norm(value):
    return " ".join(str(value).split())


def _strip_expr(value):
    text = _norm(value)
    if text.startswith("${{") and text.endswith("}}"):
        return text[3:-2].strip()
    return text


def _gha_truthy(value):
    if value is None or value is False:
        return False
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value != ""
    return bool(value)


def _gha_tokenize(expr):
    tokens = []
    i = 0
    n = len(expr)
    while i < n:
        ch = expr[i]
        if ch.isspace():
            i += 1
            continue
        if expr.startswith("&&", i) or expr.startswith("||", i) or expr.startswith("==", i) or expr.startswith("!=", i):
            tokens.append(("OP", expr[i:i + 2]))
            i += 2
            continue
        if ch in "(),!":
            tokens.append((ch, ch))
            i += 1
            continue
        if ch == "'":
            j = i + 1
            buf = []
            while j < n:
                if expr[j] == "'":
                    if j + 1 < n and expr[j + 1] == "'":
                        buf.append("'")
                        j += 2
                        continue
                    break
                buf.append(expr[j])
                j += 1
            else:
                raise ValueError(f"Unterminated string in expression: {expr}")
            tokens.append(("STR", "".join(buf)))
            i = j + 1
            continue
        if ch.isalpha() or ch == "_":
            j = i
            while j < n and (expr[j].isalnum() or expr[j] in "._-"):
                j += 1
            ident = expr[i:j]
            tokens.append(("IDENT", ident))
            i = j
            continue
        if ch.isdigit():
            j = i
            while j < n and (expr[j].isdigit() or expr[j] == "."):
                j += 1
            tokens.append(("NUM", float(expr[i:j]) if "." in expr[i:j] else int(expr[i:j])))
            i = j
            continue
        raise ValueError(f"Unsupported token at {i} in expression: {expr}")
    return tokens


def _eval_gha_expr(expr, context):
    tokens = _gha_tokenize(expr)
    pos = 0

    def peek():
        return tokens[pos] if pos < len(tokens) else (None, None)

    def consume(expected_kind=None, expected_val=None):
        nonlocal pos
        tok = peek()
        if expected_kind is not None and tok[0] != expected_kind:
            raise ValueError(f"Expected {expected_kind}, got {tok} in {expr}")
        if expected_val is not None and tok[1] != expected_val:
            raise ValueError(f"Expected {expected_val}, got {tok} in {expr}")
        pos += 1
        return tok

    def resolve(path):
        cur = context
        for part in path.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                return None
        return cur

    def parse_or():
        val = parse_and()
        while peek() == ("OP", "||"):
            consume()
            rhs = parse_and()
            val = val if _gha_truthy(val) else rhs
        return val

    def parse_and():
        val = parse_eq()
        while peek() == ("OP", "&&"):
            consume()
            rhs = parse_eq()
            val = rhs if _gha_truthy(val) else val
        return val

    def parse_eq():
        val = parse_unary()
        while peek()[0] == "OP" and peek()[1] in ("==", "!="):
            op = consume()[1]
            rhs = parse_unary()
            eq = val == rhs
            val = eq if op == "==" else not eq
        return val

    def parse_unary():
        if peek()[0] == "!":
            consume()
            return not _gha_truthy(parse_unary())
        return parse_primary()

    def parse_primary():
        kind, val = peek()
        if kind == "(":
            consume("(")
            inner = parse_or()
            consume(")")
            return inner
        if kind in ("STR", "NUM"):
            consume()
            return val
        if kind == "IDENT":
            consume()
            if peek()[0] == "(":
                consume("(")
                args = []
                if peek()[0] != ")":
                    args.append(parse_or())
                    while peek()[0] == ",":
                        consume(",")
                        args.append(parse_or())
                consume(")")
                if val == "success":
                    return bool(context.get("_success", True))
                if val == "cancelled":
                    return bool(context.get("_cancelled", False))
                if val == "format":
                    fmt = str(args[0])
                    return fmt.format(*["" if a is None else a for a in args[1:]])
                raise ValueError(f"Unsupported function {val} in {expr}")
            if val == "true":
                return True
            if val == "false":
                return False
            if val == "null":
                return None
            return resolve(val)
        raise ValueError(f"Unexpected token {kind, val} in {expr}")

    result = parse_or()
    if pos != len(tokens):
        raise ValueError(f"Trailing tokens {tokens[pos:]} in {expr}")
    return result


def _eval_gha_template(template, context):
    def repl(match):
        val = _eval_gha_expr(match.group(1), context)
        return "" if val is None else str(val)

    return re.sub(r"\$\{\{(.*?)\}\}", repl, str(template))


def _expr_root_contexts(expr):
    contexts = set()
    i = 0
    n = len(expr)
    while i < n:
        ch = expr[i]
        if ch == "'":
            i += 1
            while i < n:
                if expr[i] == "'":
                    if i + 1 < n and expr[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        if ch.isalpha() or ch == "_":
            j = i
            while j < n and (expr[j].isalnum() or expr[j] in "._-"):
                j += 1
            ident = expr[i:j]
            k = j
            while k < n and expr[k].isspace():
                k += 1
            is_call = k < n and expr[k] == "("
            prev_is_dot = i > 0 and expr[i - 1] == "."
            ident_lower = ident.lower()
            if not is_call and not prev_is_dot and ident_lower not in {"true", "false", "null"}:
                contexts.add(ident_lower.split(".", 1)[0])
            i = j
            continue
        i += 1
    return contexts


def _extract_gha_expressions(text):
    exprs = []
    s = str(text)
    i = 0
    n = len(s)
    while i < n:
        start = s.find("${{", i)
        if start == -1:
            break
        j = start + 3
        in_quote = False
        end = -1
        while j < n:
            ch = s[j]
            if in_quote:
                if ch == "'":
                    if j + 1 < n and s[j + 1] == "'":
                        j += 2
                        continue
                    in_quote = False
                j += 1
                continue
            if ch == "'":
                in_quote = True
                j += 1
                continue
            if s.startswith("}}", j):
                end = j
                break
            j += 1
        if end == -1:
            break
        exprs.append(s[start + 3:end])
        i = end + 2
    return exprs


def _env_expr_root_contexts(env_map):
    refs = []
    if not isinstance(env_map, dict):
        return refs
    for key, value in env_map.items():
        for field, raw in (("key", key), ("value", value)):
            for expr in _extract_gha_expressions(raw):
                refs.append((str(key), field, expr.strip(), _expr_root_contexts(expr)))
    return refs


WORKFLOW_ENV_FORBIDDEN_CONTEXTS = {"env", "secrets", "runner", "steps", "job", "needs", "strategy", "matrix"}
JOB_ENV_FORBIDDEN_CONTEXTS = {"env", "runner", "steps", "job"}


def _invalid_env_context_errors(wf_data, rel="workflow"):
    errors = []
    if not isinstance(wf_data, dict):
        return errors
    for key, field, expr, roots in _env_expr_root_contexts(wf_data.get("env")):
        bad = sorted(roots & WORKFLOW_ENV_FORBIDDEN_CONTEXTS)
        if bad:
            errors.append(
                f"{rel} workflow-level env[{key!r}] ({field}) references invalid contexts {bad} in: {expr}"
            )
    for job_id, job in (wf_data.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for key, field, expr, roots in _env_expr_root_contexts(job.get("env")):
            bad = sorted(roots & JOB_ENV_FORBIDDEN_CONTEXTS)
            if bad:
                errors.append(
                    f"{rel} jobs.{job_id}.env[{key!r}] ({field}) references invalid contexts {bad} in: {expr}"
                )
    return errors


def _needs_set(job):
    needs = job.get("needs", [])
    if isinstance(needs, str):
        return {needs}
    return set(needs)


def _non_comment_text(script):
    return "\n".join(line for line in script.splitlines() if not line.lstrip().startswith("#"))


def _ctest_invocations(run_script):
    joined = re.sub(r"\\\r?\n\s*", " ", run_script)
    invocations = []
    for raw_line in joined.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if re.search(r"(?:^|[;&|\s])ctest(?:\.exe)?\s+(?:--?[A-Za-z]|@\()", line):
            invocations.append(line)
    return invocations


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(WORKFLOW.is_file(), "Hosted CI workflow is missing")
        self.text = WORKFLOW.read_text(encoding="utf-8")
        # BaseLoader keeps GitHub's YAML 1.2 `on` key intact.
        self.workflow = yaml.load(self.text, Loader=yaml.BaseLoader)

    def test_events_do_not_publish(self):
        events = self.workflow["on"]
        self.assertEqual(set(events), {"pull_request", "push", "workflow_dispatch"})
        self.assertNotIn("tags", events["push"])
        self.assertNotIn("schedule", events)
        inputs = events["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["platform"]["options"], ["all", *PLATFORMS])
        self.assertEqual(inputs["checks"]["options"], ["contracts", "models", "build", "native", "full"])

        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertNotIn("secrets.", self.text)
        self.assertNotIn("environment", self.workflow)
        self.assertNotRegex(self.text, r"(?m)^\s*environment:")

        group = self.workflow["concurrency"]["group"]
        self.assertIn("github.event_name", group)
        self.assertIn("github.event.pull_request.number", group)
        self.assertIn("github.ref", group)
        self.assertIn("inputs.platform", group)
        self.assertIn("inputs.checks", group)

        for job in self.workflow["jobs"].values():
            self.assertNotIn("environment", job)
            self.assertNotIn("continue-on-error", job)
            for step in job["steps"]:
                if "continue-on-error" in step:
                    # Only cache restore steps may soft-fail and fall back to source download.
                    self.assertTrue(step.get("uses", "").startswith("actions/cache/restore@"))

    def test_pr_cache_cleanup_only_deletes_its_own_merge_ref(self):
        cleanup = yaml.load(CLEANUP.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        self.assertEqual(cleanup["on"], {"pull_request": {"types": ["closed"]}})
        self.assertEqual(cleanup["permissions"], {"actions": "write"})
        job = cleanup["jobs"]["cleanup"]
        self.assertEqual(_norm(job["if"]), "github.event.pull_request.head.repo.full_name == github.repository")
        self.assertEqual([step for step in job["steps"] if "uses" in step], [], "Do not run repository code")
        run_steps = [step for step in job["steps"] if "run" in step]
        self.assertEqual(len(run_steps), 1)
        step = run_steps[0]
        self.assertEqual(step["env"]["CACHE_REF"], "refs/pull/${{ github.event.pull_request.number }}/merge")
        self.assertIn("actions/caches?ref=$CACHE_REF", step["run"])
        self.assertEqual(step["run"].count("--method DELETE"), 1)

    def test_all_platforms_are_selected_bounded_and_gated(self):
        jobs = self.workflow["jobs"]
        self.assertEqual(set(jobs), {"changes", "contracts", *PLATFORMS, "windows-batch-selection", "result"})
        for name, job in jobs.items():
            with self.subTest(job=name):
                timeout = int(job["timeout-minutes"])
                self.assertGreater(timeout, 0)
                self.assertLessEqual(timeout, 180)
                if name == "changes":
                    self.assertEqual(job["permissions"], {"contents": "read", "actions": "read"})
                else:
                    self.assertNotIn("permissions", job)
                self.assertNotIn("self-hosted", str(job["runs-on"]))
                if name in PLATFORMS or name == "contracts":
                    self.assertIn("changes", _needs_set(job))
                    self.assertEqual(_strip_expr(job["if"]), f"needs.changes.outputs.{name} == 'true'")

        selection = jobs["changes"]
        self.assertTrue(
            {*PLATFORMS, "cold", "draft", "windows_runner", "mode", "scope",
             "checks", "contracts", "models", "build", "native", "macos_matrix"}.issubset(set(selection["outputs"]))
        )
        self.assertIn("affected_platforms.py select",
                      "\n".join(step.get("run", "") for step in selection["steps"]))

        for row in macos_matrix("full"):
            self.assertNotIn("self-hosted", str(row["runner"]))
        self.assertNotIn("self-hosted", windows_runner("pull_request", False, "full"))

        result = jobs["result"]
        self.assertEqual(_needs_set(result), set(jobs) - {"result"})
        result_if = _strip_expr(result["if"])
        self.assertIn("!cancelled()", result_if)
        self.assertIn("needs.changes.outputs.draft != 'true'", result_if)
        verify_steps = [step for step in result["steps"] if "affected_platforms.py verify" in step.get("run", "")]
        self.assertEqual(len(verify_steps), 1)
        self.assertEqual(verify_steps[0]["env"]["NEEDS"], "${{ toJSON(needs) }}")

    def test_actions_and_artifact_paths_are_constrained(self):
        for name, job in self.workflow["jobs"].items():
            uploads = []
            for step in job["steps"]:
                uses = step.get("uses")
                if not uses:
                    continue
                self.assertRegex(uses, r"^[^@]+@[0-9a-f]{40}$")
                if uses.startswith("actions/checkout@"):
                    self.assertEqual(step["with"]["persist-credentials"], "false")
                if uses.startswith("actions/upload-artifact@"):
                    uploads.append(step)
                    self.assertEqual(_strip_expr(step["if"]), "always()")
                    retention = int(step["with"]["retention-days"])
                    self.assertGreaterEqual(retention, 1)
                    self.assertLessEqual(retention, 30)
                    paths = [line.strip() for line in step["with"]["path"].splitlines() if line.strip()]
                    self.assertTrue(paths)
                    for path in paths:
                        self.assertTrue(path.startswith("build/ci/"), f"{name}: unsafe artifact path {path}")
                        self.assertNotIn("..", path.split("/"))
                        self.assertTrue(path.endswith(ALLOWED_ARTIFACT_EXTENSIONS),
                                        f"{name}: non-log/report artifact path {path}")
            if name in ("changes", "result"):
                self.assertEqual(uploads, [], name)
            else:
                self.assertGreaterEqual(len(uploads), 1, name)

    def test_actionlint_declares_custom_hosted_labels_without_legacy_self_hosted(self):
        self.assertTrue(ACTIONLINT.is_file(), "Declare custom labels for actionlint")
        policy = yaml.load(ACTIONLINT.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        labels = policy["self-hosted-runner"]["labels"]
        self.assertTrue(labels)
        for label in labels:
            self.assertFalse(label.startswith("rawlab-"), f"Legacy self-hosted label left in actionlint.yaml: {label}")
            self.assertNotEqual(label, "self-hosted")

        custom_runs_on = set()
        cleanup = yaml.load(CLEANUP.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        for workflow in (self.workflow, cleanup):
            for job in workflow["jobs"].values():
                runs_on = job["runs-on"]
                items = runs_on if isinstance(runs_on, list) else [runs_on]
                for item in items:
                    if not str(item).startswith("${{") and not str(item).startswith(STANDARD_HOSTED_PREFIXES):
                        custom_runs_on.add(str(item))
        for row in macos_matrix("full"):
            if not row["runner"].startswith(STANDARD_HOSTED_PREFIXES):
                custom_runs_on.add(row["runner"])
        win_runner = windows_runner("pull_request", False, "full")
        if not win_runner.startswith(STANDARD_HOSTED_PREFIXES):
            custom_runs_on.add(win_runner)
        self.assertTrue(custom_runs_on.issubset(set(labels)),
                        f"Missing custom runner labels in actionlint.yaml: {custom_runs_on - set(labels)}")

    def test_exact_native_caches_are_reused_except_by_cold_builds(self):
        for name in PLATFORMS:
            with self.subTest(job=name):
                steps = self.workflow["jobs"][name]["steps"]
                restores = [s for s in steps if s.get("uses", "").startswith("actions/cache/restore@")]
                saves = [s for s in steps if s.get("uses", "").startswith("actions/cache/save@")]

                native_restores = [s for s in restores if s.get("id") == "native-cache"]
                self.assertEqual(len(native_restores), 1)
                restore = native_restores[0]
                native_saves = [s for s in saves if s["with"].get("key") == restore["with"].get("key")]
                self.assertEqual(len(native_saves), 1)
                save = native_saves[0]

                self.assertEqual(_strip_expr(restore["if"]), "needs.changes.outputs.build == 'true'")
                self.assertEqual(restore.get("continue-on-error"), "true")
                self.assertEqual(_norm(restore["with"].get("lookup-only")),
                                 "${{ needs.changes.outputs.cold == 'true' }}")
                self.assertNotIn("restore-keys", restore["with"])
                self.assertEqual(save["with"], {k: restore["with"][k] for k in ("key", "path")})
                save_if = _strip_expr(save["if"])
                self.assertIn("success()", save_if)
                self.assertIn("steps.native-cache.outcome == 'success'", save_if)
                self.assertIn("steps.native-cache.outputs.cache-hit != 'true'", save_if)

                builds = [s for s in steps if "run" in s and _strip_expr(s.get("if", "")) == "needs.changes.outputs.build == 'true'"
                          and "RAWLAB_CI_CACHE_HIT" in s.get("env", {})]
                self.assertEqual(len(builds), 1)
                build = builds[0]
                cache_hit_expr = _norm(build["env"]["RAWLAB_CI_CACHE_HIT"])
                self.assertIn("needs.changes.outputs.cold != 'true'", cache_hit_expr)
                self.assertIn("steps.native-cache.outputs.cache-hit == 'true'", cache_hit_expr)
                self.assertLess(steps.index(restore), steps.index(build))
                self.assertLess(steps.index(build), steps.index(save))

                extra_restores = [s for s in restores if s is not restore]
                for extra in extra_restores:
                    self.assertEqual(extra.get("continue-on-error"), "true")
                    extra_id = extra["id"]
                    matching_saves = [s for s in saves if s["with"].get("key") == extra["with"].get("key")]
                    self.assertEqual(len(matching_saves), 1)
                    extra_save = matching_saves[0]
                    extra_save_if = _strip_expr(extra_save["if"])
                    self.assertIn("success()", extra_save_if)
                    self.assertIn(f"steps.{extra_id}.outcome == 'success'", extra_save_if)
                    self.assertIn(f"steps.{extra_id}.outputs.cache-hit != 'true'", extra_save_if)
                    self.assertLess(steps.index(extra), steps.index(build))
                    self.assertLess(steps.index(build), steps.index(extra_save))

    def test_fast_models_are_separate_from_native_builds_on_every_platform(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                steps = self.workflow["jobs"][platform]["steps"]
                model_steps = [s for s in steps if "needs.changes.outputs.models" in s.get("if", "")]
                self.assertEqual(len(model_steps), 1)
                model_run = model_steps[0]["run"]
                for marker in NATIVE_BUILD_MARKERS:
                    self.assertNotIn(marker, model_run)
                if platform in ("macos", "ios"):
                    self.assertIn("apple-models.sh", model_run)
                for step in steps:
                    if step.get("id") in ("native-key", "native-cache") or "RAWLAB_CI_CACHE_HIT" in step.get("env", {}):
                        self.assertEqual(_strip_expr(step.get("if", "")), "needs.changes.outputs.build == 'true'")

    def test_builds_are_not_feature_reduced_and_ui_stays_local(self):
        self.assertNotRegex(self.text, r"SONY2FUJI_ENABLE_\w+=OFF")
        self.assertNotRegex(self.text, r"RAWLAB_RUM_LOCAL[=: ]+['\"]?1")
        self.assertNotIn("-Test -SelfContained", self.text)

        sources = [
            *(_non_comment_text(step.get("run", ""))
              for job in self.workflow["jobs"].values()
              for step in job["steps"]),
            _non_comment_text(APPLE_MODELS.read_text(encoding="utf-8")),
            _non_comment_text(WINDOWS_MODELS.read_text(encoding="utf-8")),
        ]
        for source in sources:
            for ui_marker in UI_TEST_MARKERS:
                self.assertNotIn(ui_marker, source)

        for job in self.workflow["jobs"].values():
            for step in job["steps"]:
                for line in _non_comment_text(step.get("run", "")).splitlines():
                    if "presentation.sh" in line:
                        self.assertIn("--models-only", line)

    def test_ctest_never_silently_skips_and_hosted_ci_needs_no_private_dcp(self):
        invocations = []
        for job_name, job in self.workflow["jobs"].items():
            for step in job["steps"]:
                for invocation in _ctest_invocations(step.get("run", "")):
                    invocations.append((job_name, invocation))
                    self.assertIn("--no-tests=error", invocation, f"{job_name}: ctest missing --no-tests=error")
                    if job_name.startswith("windows"):
                        self.assertNotRegex(invocation, r"(?i)-C\s+['\"]?Debug['\"]?")
        self.assertGreaterEqual(len(invocations), 2)
        self.assertNotRegex(self.text, r"\bRAWLAB_TEST_(?:CANON_)?DCP\b",
                            "Hosted CI must not require private DCP profiles")

    def test_warp_regressions_require_an_explicit_windows_request(self):
        warp_steps = [
            step for step in self.workflow["jobs"]["windows"]["steps"]
            if "d3d11" in step.get("run", "") and "check-mutations.ps1" in step.get("run", "")
        ]
        self.assertEqual(len(warp_steps), 1)
        step = warp_steps[0]
        self.assertEqual(_strip_expr(step["if"]),
                         "github.event_name == 'workflow_dispatch' && inputs.platform == 'windows' && inputs.checks == 'models'")
        self.assertNotIn("continue-on-error", step)
        self.assertIn("--no-tests=error", step["run"])
        self.assertIn("$LASTEXITCODE", step["run"])

    def test_gpu_ai_inputs_are_gated_to_arm64_full_checks(self):
        mac_steps = [step for step in self.workflow["jobs"]["macos"]["steps"]
                     if "ai-inputs.py" in step.get("run", "")]
        self.assertEqual(len(mac_steps), 1)
        self.assertEqual(_strip_expr(mac_steps[0]["if"]), "needs.changes.outputs.checks == 'full' && matrix.arch == 'arm64'")
        full_matrix = macos_matrix("full")
        self.assertTrue(any(row["arch"] == "arm64" for row in full_matrix))
        self.assertTrue(any(row["arch"] == "x86_64" for row in full_matrix))

        win_steps = [step for step in self.workflow["jobs"]["windows"]["steps"]
                     if "ai-inputs.py" in step.get("run", "")]
        for step in win_steps:
            self.assertEqual(_strip_expr(step["if"]), "needs.changes.outputs.checks == 'full'")

    def test_batch_selection_is_an_isolated_automatic_hosted_job(self):
        job = self.workflow["jobs"]["windows-batch-selection"]
        self.assertIn("changes", _needs_set(job))
        self.assertNotIn("self-hosted", str(job["runs-on"]))
        self.assertEqual(_strip_expr(job["if"]),
                         "needs.changes.outputs.windows == 'true' && "
                         "needs.changes.outputs.mode == 'automatic' && "
                         "needs.changes.outputs.checks == 'models'")
        suite_steps = [step for step in job["steps"] if "run-v08.ps1" in step.get("run", "")]
        self.assertEqual(len(suite_steps), 1)
        suite = suite_steps[0]
        self.assertNotIn("if", suite)
        self.assertNotIn("continue-on-error", suite)
        self.assertRegex(suite["run"], r"-Only\s+['\"]batch-selection['\"]")

    def test_manual_concurrency_groups_isolate_platform_and_checks(self):
        group_tmpl = self.workflow["concurrency"]["group"]
        seen = {}
        for platform in ("all", *PLATFORMS):
            for checks in ("contracts", "models", "build", "native", "full"):
                ctx = {
                    "github": {
                        "workflow": "Hosted CI",
                        "event_name": "workflow_dispatch",
                        "ref": "refs/heads/development",
                        "event": {},
                    },
                    "inputs": {"platform": platform, "checks": checks},
                }
                group = _eval_gha_template(group_tmpl, ctx)
                self.assertNotIn(group, seen, f"Duplicate concurrency group for {(platform, checks)} and {seen.get(group)}")
                seen[group] = (platform, checks)
                self.assertEqual(group, _eval_gha_template(group_tmpl, ctx))

        push_group = _eval_gha_template(group_tmpl, {
            "github": {
                "workflow": "Hosted CI",
                "event_name": "push",
                "ref": "refs/heads/development",
                "event": {},
            },
            "inputs": {},
        })
        self.assertNotIn(push_group, seen)

    def test_fork_pull_requests_never_save_caches(self):
        save_steps = []
        for job_name, job in self.workflow["jobs"].items():
            for step in job["steps"]:
                uses = step.get("uses", "")
                if uses.startswith("actions/cache@"):
                    self.fail(f"{job_name}: bare actions/cache@ is forbidden; split restore and fork-gated save")
                if uses.startswith("actions/setup-") and "cache" in step.get("with", {}):
                    self.fail(f"{job_name}: {uses} must not configure built-in cache")
                if uses.startswith("actions/cache/save@"):
                    save_steps.append((job_name, step))

        self.assertGreaterEqual(len(save_steps), 12)
        base_steps = {
            "assets-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}},
            "native-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}},
            "dep-archives-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}},
            "gradle-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}},
            "pip-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}},
            "cargo-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}},
            "x3f-rust-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}},
            "swiftpm-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}},
            "source-archives-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}},
        }
        base_matrix = {"suite": "all"}
        for job_name, step in save_steps:
            with self.subTest(job=job_name, step=step.get("name")):
                expr = _strip_expr(step["if"])
                fork_ctx = {
                    "_success": True,
                    "github": {
                        "repository": "dancancer/RawLab",
                        "event_name": "pull_request",
                        "event": {"pull_request": {"head": {"repo": {"full_name": "contributor/RawLab"}}}},
                    },
                    "steps": base_steps,
                    "matrix": base_matrix,
                }
                deleted_fork_ctx = {
                    **fork_ctx,
                    "github": {
                        "repository": "dancancer/RawLab",
                        "event_name": "pull_request",
                        "event": {"pull_request": {"head": {"repo": None}}},
                    },
                }
                internal_pr_ctx = {
                    **fork_ctx,
                    "github": {
                        "repository": "dancancer/RawLab",
                        "event_name": "pull_request",
                        "event": {"pull_request": {"head": {"repo": {"full_name": "dancancer/RawLab"}}}},
                    },
                }
                push_ctx = {
                    **fork_ctx,
                    "github": {"repository": "dancancer/RawLab", "event_name": "push", "event": {}},
                }
                dispatch_ctx = {
                    **fork_ctx,
                    "github": {"repository": "dancancer/RawLab", "event_name": "workflow_dispatch", "event": {}},
                }
                self.assertFalse(_gha_truthy(_eval_gha_expr(expr, fork_ctx)))
                self.assertFalse(_gha_truthy(_eval_gha_expr(expr, deleted_fork_ctx)))
                self.assertTrue(_gha_truthy(_eval_gha_expr(expr, internal_pr_ctx)))
                self.assertTrue(_gha_truthy(_eval_gha_expr(expr, push_ctx)))
                self.assertTrue(_gha_truthy(_eval_gha_expr(expr, dispatch_ctx)))

    def test_edited_pull_requests_only_rerun_on_base_change(self):
        pr_cfg = self.workflow["on"]["pull_request"]
        self.assertIn("edited", pr_cfg["types"])

        # Title/body edits run the selection job, which reuses the head's automatic result
        # under its own name instead of selecting checks (see affected_platforms.edit_reference).
        self.assertNotIn("if", self.workflow["jobs"]["changes"])
        changes_name = _strip_expr(self.workflow["jobs"]["changes"]["name"])
        self.assertEqual(self.workflow["jobs"]["changes"]["outputs"]["reference"], "${{ steps.select.outputs.reference }}")
        result_if = _strip_expr(self.workflow["jobs"]["result"]["if"])
        group_tmpl = self.workflow["concurrency"]["group"]

        title_edit_ctx = {
            "github": {
                "workflow": "Hosted CI",
                "event_name": "pull_request",
                "ref": "refs/pull/42/merge",
                "event": {"action": "edited", "pull_request": {"number": 42}, "changes": {"title": {"from": "old"}}},
            },
        }
        base_edit_ctx = {
            "github": {
                "workflow": "Hosted CI",
                "event_name": "pull_request",
                "ref": "refs/pull/42/merge",
                "event": {
                    "action": "edited",
                    "pull_request": {"number": 42},
                    "changes": {"base": {"ref": {"from": "development"}}},
                },
            },
        }
        sync_ctx = {
            "github": {
                "workflow": "Hosted CI",
                "event_name": "pull_request",
                "ref": "refs/pull/42/merge",
                "event": {"action": "synchronize", "pull_request": {"number": 42}},
            },
        }
        push_ctx = {
            "github": {
                "workflow": "Hosted CI",
                "event_name": "push",
                "ref": "refs/heads/development",
                "event": {},
            },
        }
        dispatch_ctx = {
            "github": {
                "workflow": "Hosted CI",
                "event_name": "workflow_dispatch",
                "ref": "refs/heads/development",
                "event": {},
            },
            "inputs": {"platform": "all", "checks": "models"},
        }

        self.assertEqual(_eval_gha_expr(changes_name, title_edit_ctx), EDIT_JOB)
        for ctx in (base_edit_ctx, sync_ctx, push_ctx, dispatch_ctx):
            self.assertEqual(_eval_gha_expr(changes_name, ctx), SELECT_JOB)

        # With the selection a title/body edit writes (test_affected_platforms.EditSelectionOutputTests),
        # every check job stays skipped; only the aggregate result runs.
        edit_outputs = {**{platform: "false" for platform in PLATFORMS}, "contracts": "false",
                        "mode": "edit", "checks": "models", "draft": "false", "reference": "success"}
        edit_needs = {"_cancelled": False, "needs": {"changes": {"result": "success", "outputs": edit_outputs}}}
        for name, job in self.workflow["jobs"].items():
            if name in ("changes", "result"):
                continue
            with self.subTest(job=name):
                self.assertFalse(_gha_truthy(_eval_gha_expr(_strip_expr(job["if"]), edit_needs)))
        self.assertTrue(_gha_truthy(_eval_gha_expr(result_if, edit_needs)))

        self.assertNotEqual(
            _eval_gha_template(group_tmpl, title_edit_ctx),
            _eval_gha_template(group_tmpl, sync_ctx),
            "PR title/body edit must not cancel an active PR check run",
        )
        self.assertEqual(
            _eval_gha_template(group_tmpl, base_edit_ctx),
            _eval_gha_template(group_tmpl, sync_ctx),
            "PR base edit should supersede stale runs on the old base branch",
        )

        self.assertFalse(_gha_truthy(_eval_gha_expr(result_if, {
            "_cancelled": False,
            "needs": {"changes": {"result": "skipped", "outputs": {"draft": ""}}},
        })))
        self.assertTrue(_gha_truthy(_eval_gha_expr(result_if, {
            "_cancelled": False,
            "needs": {"changes": {"result": "failure", "outputs": {"draft": ""}}},
        })))
        self.assertFalse(_gha_truthy(_eval_gha_expr(result_if, {
            "_cancelled": False,
            "needs": {"changes": {"result": "success", "outputs": {"draft": "true"}}},
        })))
        self.assertTrue(_gha_truthy(_eval_gha_expr(result_if, {
            "_cancelled": False,
            "needs": {"changes": {"result": "success", "outputs": {"draft": "false"}}},
        })))

    def test_windows_ci_drops_legacy_self_hosted_and_batch_selection_builds_tests(self):
        self.assertNotIn("self-hosted", self.text)
        self.assertNotIn("RawLabCI", self.text)

        batch_job = self.workflow["jobs"]["windows-batch-selection"]
        build_steps = [
            step for step in batch_job["steps"]
            if "RawLabWindows/native" in step.get("run", "")
        ]
        self.assertEqual(len(build_steps), 1)
        script = build_steps[0]["run"]
        self.assertNotIn("-DBUILD_TESTING=OFF", script)
        self.assertIn("-DBUILD_TESTING=ON", script)
        self.assertIn("check_ctest_inventory.py", script)
        for target in (
            "sony2fuji",
            "windows_display_image_tests",
            "edit_pixel_golden_tests",
            "hdr_portable_tests",
            "d3d11_shader_tests",
        ):
            self.assertIn(target, script)

    def test_windows_test_runners_guard_against_zero_matches_and_source_reads(self):
        models_ps1 = WINDOWS_MODELS.read_text(encoding="utf-8")
        run_v08 = (ROOT / "RawLabWindows/tests/run-v08.ps1").read_text(encoding="utf-8")
        runner_checks = (ROOT / "RawLabWindows/tests/RunnerSelectionChecks.ps1").read_text(encoding="utf-8")

        for content in (models_ps1, run_v08):
            self.assertIn("RAWLAB_APPDATA_ROOT", content)
            self.assertIn("trx;LogFileName=", content)
            self.assertIn("Test-TrxExecution", content)

        self.assertIn("zero-tests", runner_checks)
        self.assertIn("missing-trx", runner_checks)

        match = re.search(r"\$names\s*=\s*@\(([^)]+)\)", run_v08)
        self.assertIsNotNone(match, "run-v08.ps1 must declare $names")
        declared_suites = set(re.findall(r"'([^']+)'", match.group(1))) - {"build"}

        dedicated_suites = {"default", "ai-denoise", "benchmark", "updates-sdk-offline"}
        tests_root = ROOT / "RawLabWindows/tests"
        discovered_suites = set()
        for cs_path in sorted(tests_root.rglob("*.cs")):
            text = cs_path.read_text(encoding="utf-8")
            discovered_suites.update(re.findall(r'\[Trait\("Suite",\s*"([^"]+)"\)\]', text))
            if cs_path.name not in {"StaticKeyChecks.cs", "LocalizationTests.cs"}:
                self.assertNotRegex(
                    text,
                    r'File\.ReadAll(?:Text|Lines)\([^\n]*(?:\.cs|\.xaml|RenderEngine\.cs|RenderedDngChecks\.cs)',
                    f"Source-text test assertion left in {cs_path.relative_to(ROOT)}",
                )

        self.assertEqual(discovered_suites - dedicated_suites, declared_suites)

        pwsh = os.environ.get("RAWLAB_TEST_PWSH") or shutil.which("pwsh")
        if pwsh:
            self._exercise_windows_runners_with_pwsh(pwsh)

    def _exercise_windows_runners_with_pwsh(self, pwsh):
        with tempfile.TemporaryDirectory(prefix="rawlab-win-runners-") as tmp:
            sandbox = Path(tmp)
            (sandbox / "scripts/ci").mkdir(parents=True)
            (sandbox / "RawLabWindows/tests").mkdir(parents=True)
            shutil.copy2(WINDOWS_MODELS, sandbox / "scripts/ci/windows-models.ps1")
            shutil.copy2(ROOT / "RawLabWindows/tests/run-v08.ps1", sandbox / "RawLabWindows/tests/run-v08.ps1")
            shutil.copy2(ROOT / "RawLabWindows/tests/CheckProcess.ps1", sandbox / "RawLabWindows/tests/CheckProcess.ps1")
            native = sandbox / "native"
            (native / "ExifTool").mkdir(parents=True)
            for rel in ("sony2fuji.dll", "raw.dll", "ExifTool/sentinel"):
                (native / rel).write_text("stub", encoding="utf-8")
            (sandbox / "fixture.arw").write_text("raw", encoding="utf-8")

            stub = sandbox / "dotnet-stub.py"
            stub.write_text(
                "#!/usr/bin/env python3\n"
                "import os, pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "mode = os.environ.get('STUB_MODE', 'ok')\n"
                "if args and args[0] == 'msbuild':\n"
                "    out = pathlib.Path(os.environ['STUB_TARGET'])\n"
                "    out.mkdir(parents=True, exist_ok=True)\n"
                "    print(str(out) + os.sep)\n"
                "    sys.exit(0)\n"
                "if args and args[0] == 'test':\n"
                "    if not os.environ.get('RAWLAB_APPDATA_ROOT', '').strip():\n"
                "        sys.stderr.write('missing RAWLAB_APPDATA_ROOT\\n')\n"
                "        sys.exit(9)\n"
                "    if '--list-tests' in args:\n"
                "        print('The following Tests are available:')\n"
                "        if mode != 'zero-list':\n"
                "            print('    RawLab.Windows.Tests.AppPathsTests.DefaultProfileUsesTestIsolationRootAndRoutesStaticDefaults')\n"
                "        sys.exit(0)\n"
                "    trx = next((a.split('trx;LogFileName=', 1)[1] for a in args if a.startswith('trx;LogFileName=')), None)\n"
                "    if trx and mode != 'missing-trx':\n"
                "        path = pathlib.Path(trx)\n"
                "        path.parent.mkdir(parents=True, exist_ok=True)\n"
                "        count = '0' if mode == 'zero-exec' else '1'\n"
                "        path.write_text(f'<TestRun><ResultSummary outcome=\"Completed\"><Counters total=\"{count}\" executed=\"{count}\" passed=\"{count}\" failed=\"0\" /></ResultSummary></TestRun>', encoding='utf-8')\n"
                "sys.exit(0)\n",
                encoding="utf-8",
            )
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)

            base_env = {k: v for k, v in os.environ.items() if k != "RAWLAB_APPDATA_ROOT"}
            base_env["STUB_TARGET"] = str(sandbox / "target")

            ok_models = subprocess.run(
                [pwsh, "-NoProfile", "-File", str(sandbox / "scripts/ci/windows-models.ps1"), "-DotNet", str(stub)],
                env={**base_env, "STUB_MODE": "ok"},
                capture_output=True, text=True,
            )
            self.assertEqual(ok_models.returncode, 0, ok_models.stdout + ok_models.stderr)

            for bad_mode in ("zero-exec", "zero-list", "missing-trx"):
                bad_models = subprocess.run(
                    [pwsh, "-NoProfile", "-File", str(sandbox / "scripts/ci/windows-models.ps1"), "-DotNet", str(stub)],
                    env={**base_env, "STUB_MODE": bad_mode},
                    capture_output=True, text=True,
                )
                self.assertNotEqual(bad_models.returncode, 0, f"windows-models.ps1 passed on {bad_mode}")

            for bad_mode in ("zero-exec", "missing-trx"):
                bad_v08 = subprocess.run(
                    [pwsh, "-NoProfile", "-File", str(sandbox / "RawLabWindows/tests/run-v08.ps1"),
                     "-RawPath", str(sandbox / "fixture.arw"),
                     "-NativeArtifacts", str(native),
                     "-DotNet", str(stub),
                     "-Only", "about"],
                    env={**base_env, "STUB_MODE": bad_mode},
                    capture_output=True, text=True,
                )
                self.assertNotEqual(bad_v08.returncode, 0, f"run-v08.ps1 passed on {bad_mode}")

    def test_android_build_verifies_minified_release_apk_jni_and_alignment(self):
        steps = self.workflow["jobs"]["android"]["steps"]
        build_steps = [
            step for step in steps
            if _strip_expr(step.get("if", "")) == "needs.changes.outputs.build == 'true'"
            and "RAWLAB_CI_CACHE_HIT" in step.get("env", {})
        ]
        self.assertEqual(len(build_steps), 1)
        run = _non_comment_text(build_steps[0]["run"])
        self.assertIn("fetch-rum-sdk.sh", run)
        self.assertIn(":app:assembleRelease", run)
        self.assertIn("libproducer.so", run)
        self.assertIn("check-rum-jni-classes.py", run)
        self.assertIn("app-release-unsigned.apk", run)
        self.assertIn("zipalign", run)
        self.assertIn("check-native.sh", run)
        self.assertNotIn("--no-rum", run)
        self.assertNotIn("apksigner sign", run)
        self.assertNotIn("RAWLAB_RELEASE_KEYSTORE", run)

    def test_android_uses_split_gradle_cache_and_bounded_workers(self):
        steps = self.workflow["jobs"]["android"]["steps"]
        restores = [s for s in steps if s.get("id") == "gradle-cache"]
        self.assertEqual(len(restores), 1)
        restore = restores[0]
        self.assertTrue(restore["uses"].startswith("actions/cache/restore@"))
        self.assertEqual(restore.get("continue-on-error"), "true")
        self.assertIn("~/.gradle/caches", restore["with"]["path"])
        self.assertIn("~/.gradle/wrapper", restore["with"]["path"])

        saves = [
            s for s in steps
            if s.get("uses", "").startswith("actions/cache/save@")
            and s["with"].get("key") == restore["with"].get("key")
        ]
        self.assertEqual(len(saves), 1)
        save_if = _strip_expr(saves[0]["if"])
        self.assertIn("steps.gradle-cache.outcome == 'success'", save_if)
        self.assertIn("steps.gradle-cache.outputs.cache-hit != 'true'", save_if)

        models_step = [s for s in steps if "testDebugUnitTest" in s.get("run", "")]
        self.assertEqual(len(models_step), 1)
        self.assertIn("--max-workers=4", models_step[0]["run"])

        build_step = [s for s in steps if ":app:assembleRelease" in s.get("run", "")]
        self.assertEqual(len(build_step), 1)
        self.assertIn("--max-workers=2", build_step[0]["run"])

    def test_batch_selection_reuses_windows_native_cargo_and_pip_caches(self):
        steps = self.workflow["jobs"]["windows-batch-selection"]["steps"]
        restores = [s for s in steps if s.get("uses", "").startswith("actions/cache/restore@")]
        saves = [s for s in steps if s.get("uses", "").startswith("actions/cache/save@")]

        key_steps = [s for s in steps if s.get("id") == "native-key"]
        self.assertEqual(len(key_steps), 1)
        self.assertIn("native_cache.py key --platform windows --arch x86_64", key_steps[0]["run"])

        by_id = {s.get("id"): s for s in restores}
        for required_id in ("native-cache", "cargo-cache", "x3f-rust-cache", "pip-cache"):
            self.assertIn(required_id, by_id, f"Missing restore step {required_id} in windows-batch-selection")
            restore = by_id[required_id]
            self.assertEqual(restore.get("continue-on-error"), "true")
            matching_saves = [s for s in saves if s["with"].get("key") == restore["with"].get("key")]
            self.assertEqual(len(matching_saves), 1, f"Expected single save step for {required_id}")
            save_if = _strip_expr(matching_saves[0]["if"])
            self.assertIn("success()", save_if)
            self.assertIn(f"steps.{required_id}.outcome == 'success'", save_if)
            self.assertIn(f"steps.{required_id}.outputs.cache-hit != 'true'", save_if)

        self.assertEqual(_norm(by_id["native-cache"]["with"].get("lookup-only")), "${{ needs.changes.outputs.cold == 'true' }}")
        self.assertNotIn("restore-keys", by_id["native-cache"]["with"])
        self.assertNotIn("restore-keys", by_id["x3f-rust-cache"]["with"])

        builds = [s for s in steps if "RawLabWindows/native" in s.get("run", "")]
        self.assertEqual(len(builds), 1)
        build = builds[0]
        cache_hit_expr = _norm(build.get("env", {}).get("RAWLAB_CI_CACHE_HIT", ""))
        self.assertIn("needs.changes.outputs.cold != 'true'", cache_hit_expr)
        self.assertIn("steps.native-cache.outputs.cache-hit == 'true'", cache_hit_expr)
        for restore in restores:
            self.assertLess(steps.index(restore), steps.index(build))
        for save in saves:
            self.assertLess(steps.index(build), steps.index(save))

        self.assertNotIn("rust-docs", build["run"])
        self.assertIn("-DRAWLAB_COLLECT_X3F_LICENSES=OFF", build["run"])
        self.assertIn("'inventory'", build["run"])

        job_env = self.workflow["jobs"]["windows-batch-selection"].get("env", {})
        self.assertNotIn("PIP_CACHE_DIR", job_env)
        pip_restore_path = by_id["pip-cache"]["with"]["path"]
        self.assertEqual(pip_restore_path, "${{ runner.temp }}/rawlab-ci/cache/pip")
        dep_key_steps = [s for s in steps if s.get("id") == "dep-archives-key"]
        self.assertEqual(len(dep_key_steps), 1)
        dep_key_run = dep_key_steps[0]["run"]
        self.assertIn("$env:PIP_CACHE_DIR = \"$ciRoot\\cache\\pip\"", dep_key_run)
        self.assertIn("\"PIP_CACHE_DIR=$env:PIP_CACHE_DIR\"", dep_key_run)
        self.assertLess(dep_key_run.index("PIP_CACHE_DIR=$env:PIP_CACHE_DIR"), dep_key_run.index("pip install"))
        self.assertLess(steps.index(dep_key_steps[0]), steps.index(build))

        win_steps = self.workflow["jobs"]["windows"]["steps"]
        win_rust = [s for s in win_steps if "rustup" in s.get("run", "")]
        self.assertEqual(len(win_rust), 1)
        self.assertIn("--component rust-docs", win_rust[0]["run"])
        win_build = [s for s in win_steps if "RawLabWindows/build.ps1" in s.get("run", "")]
        self.assertEqual(len(win_build), 1)
        self.assertNotIn("RAWLAB_COLLECT_X3F_LICENSES=OFF", win_build[0]["run"])

    def test_windows_native_ctest_runs_in_parallel_without_sccache(self):
        steps = self.workflow["jobs"]["windows"]["steps"]
        win_build = [s for s in steps if "RawLabWindows/build.ps1" in s.get("run", "")]
        self.assertEqual(len(win_build), 1)
        invocations = _ctest_invocations(win_build[0]["run"])
        self.assertEqual(len(invocations), 1)
        self.assertIn("--parallel", invocations[0])
        self.assertIn("$env:JOBS", invocations[0])
        self.assertNotIn("sccache", self.text)

    def test_apple_jobs_wire_swiftpm_caches(self):
        for job_name, expected_key_fragment in (
            ("macos", "rawlab-swiftpm-v1-macos-${{ matrix.runner }}-${{ matrix.arch }}-"),
            ("ios", "rawlab-swiftpm-v1-ios-xcode27-"),
        ):
            with self.subTest(job=job_name):
                steps = self.workflow["jobs"][job_name]["steps"]
                restores = [s for s in steps if s.get("id") == "swiftpm-cache"]
                self.assertEqual(len(restores), 1)
                restore = restores[0]
                self.assertIn(expected_key_fragment, restore["with"]["key"])
                model_steps = [s for s in steps if "apple-models.sh" in s.get("run", "")]
                self.assertEqual(len(model_steps), 1)
                self.assertEqual(model_steps[0].get("env", {}).get("RAWLAB_CI_SWIFTPM_CACHE"), ".cache/ci/swiftpm")
                self.assertLess(steps.index(restore), steps.index(model_steps[0]))

    def test_apple_swiftpm_cache_is_never_saved_when_unpopulated(self):
        base_github = {
            "repository": "dancancer/RawLab",
            "event_name": "workflow_dispatch",
            "event": {},
        }
        for checks in ("models", "build", "native", "full"):
            changes_outputs = {
                "checks": checks,
                "models": "true" if checks in ("models", "full") else "false",
                "build": "true" if checks in ("build", "native", "full") else "false",
                "native": "true" if checks in ("native", "full") else "false",
            }
            for row in macos_matrix(checks):
                with self.subTest(job="macos", checks=checks, arch=row["arch"], suite=row["suite"]):
                    steps = self.workflow["jobs"]["macos"]["steps"]
                    restore = next(s for s in steps if s.get("id") == "swiftpm-cache")
                    save = next(
                        s for s in steps
                        if s.get("uses", "").startswith("actions/cache/save@")
                        and s["with"].get("key") == restore["with"].get("key")
                    )
                    ctx = {
                        "_success": True,
                        "github": base_github,
                        "needs": {"changes": {"outputs": changes_outputs}},
                        "matrix": row,
                    }
                    restore_runs = _gha_truthy(_eval_gha_expr(_strip_expr(restore["if"]), ctx))
                    expected = (checks == "models" and row["arch"] == "arm64") or (
                        checks in ("native", "full") and row["suite"] in ("all", "core", "intel")
                    )
                    self.assertEqual(restore_runs, expected)

                    save_expr = _strip_expr(save["if"])
                    sim_ctx = {
                        **ctx,
                        "steps": {"swiftpm-cache": {"outcome": "success" if restore_runs else "skipped", "outputs": {"cache-hit": "false"}}},
                    }
                    standalone_ctx = {
                        **ctx,
                        "steps": {"swiftpm-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}}},
                    }
                    self.assertEqual(_gha_truthy(_eval_gha_expr(save_expr, sim_ctx)), expected)
                    self.assertEqual(_gha_truthy(_eval_gha_expr(save_expr, standalone_ctx)), expected)
                    if checks == "build" or row["suite"] in ("build", "agent", "render"):
                        self.assertFalse(_gha_truthy(_eval_gha_expr(save_expr, sim_ctx)))
                        self.assertFalse(_gha_truthy(_eval_gha_expr(save_expr, standalone_ctx)))

            with self.subTest(job="ios", checks=checks):
                steps = self.workflow["jobs"]["ios"]["steps"]
                restore = next(s for s in steps if s.get("id") == "swiftpm-cache")
                save = next(
                    s for s in steps
                    if s.get("uses", "").startswith("actions/cache/save@")
                    and s["with"].get("key") == restore["with"].get("key")
                )
                ctx = {
                    "_success": True,
                    "github": base_github,
                    "needs": {"changes": {"outputs": changes_outputs}},
                }
                restore_runs = _gha_truthy(_eval_gha_expr(_strip_expr(restore["if"]), ctx))
                expected = checks in ("models", "full")
                self.assertEqual(restore_runs, expected)

                save_expr = _strip_expr(save["if"])
                sim_ctx = {
                    **ctx,
                    "steps": {"swiftpm-cache": {"outcome": "success" if restore_runs else "skipped", "outputs": {"cache-hit": "false"}}},
                }
                standalone_ctx = {
                    **ctx,
                    "steps": {"swiftpm-cache": {"outcome": "success", "outputs": {"cache-hit": "false"}}},
                }
                self.assertEqual(_gha_truthy(_eval_gha_expr(save_expr, sim_ctx)), expected)
                self.assertEqual(_gha_truthy(_eval_gha_expr(save_expr, standalone_ctx)), expected)
                if checks in ("build", "native"):
                    self.assertFalse(_gha_truthy(_eval_gha_expr(save_expr, sim_ctx)))
                    self.assertFalse(_gha_truthy(_eval_gha_expr(save_expr, standalone_ctx)))

        mac_build = next(
            s for s in self.workflow["jobs"]["macos"]["steps"]
            if "RawLabMac/build.sh" in s.get("run", "")
        )
        run_lines = mac_build["run"].splitlines()
        core_idx = next(i for i, line in enumerate(run_lines) if "if in_suite core; then" in line)
        mkdir_idx = next(i for i, line in enumerate(run_lines) if ".cache/ci/swiftpm/deps" in line)
        self.assertGreater(mkdir_idx, core_idx)

    def test_workflows_pass_actionlint(self):
        # Contracts runs the pinned actionlint and exports it as RAWLAB_ACTIONLINT; locally use the one
        # on PATH (`brew install actionlint`) so workflow mistakes surface before a push.
        pinned = re.search(r"actionlint/releases/download/v([0-9.]+)/", self.text).group(1)
        binary = os.environ.get("RAWLAB_ACTIONLINT") or shutil.which("actionlint")
        if not binary:
            if os.environ.get("CI"):
                self.fail("CI must provide actionlint through RAWLAB_ACTIONLINT")
            self.skipTest(f"actionlint {pinned} is not installed (brew install actionlint)")
        version = subprocess.run([binary, "-version"], capture_output=True, text=True).stdout.splitlines()[0].strip()
        if os.environ.get("CI"):
            self.assertEqual(version, pinned, "CI must lint with the pinned actionlint")
        result = subprocess.run([binary, "-no-color"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, f"actionlint {version}:\n{result.stdout}{result.stderr}")

    def test_mac_suite_selection_runs_each_suite_once_per_architecture(self):
        # Execute the workflow's own in_suite() so the matrix rows and the shell gate cannot drift.
        mac_build = next(s for s in self.workflow["jobs"]["macos"]["steps"] if "RawLabMac/build.sh" in s.get("run", ""))
        match = re.search(r"^ *in_suite\(\) \{(?:[^\n]*\}$|\n.*?^ *\}$)", mac_build["run"], re.S | re.M)
        self.assertIsNotNone(match, "in_suite() must stay a standalone shell function")
        groups = ("core", "agent", "render", "model")
        for checks in ("native", "full"):
            for arch in ("arm64", "x86_64"):
                ran = []
                for row in (r for r in macos_matrix(checks) if r["arch"] == arch):
                    script = match.group(0) + "\nfor g in " + " ".join(groups) + "; do in_suite $g && echo $g; done; true\n"
                    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True,
                                            env={**os.environ, "RAWLAB_CI_NATIVE": "true", "RAWLAB_MAC_SUITE": row["suite"]})
                    ran += result.stdout.split()
                with self.subTest(checks=checks, arch=arch):
                    expected = list(groups) if arch == "arm64" else ["core", "agent", "render"]
                    self.assertEqual(sorted(ran), sorted(expected), "each suite group runs exactly once")
        result = subprocess.run(["bash", "-c", match.group(0) + "\nin_suite core"], capture_output=True, text=True,
                                env={**os.environ, "RAWLAB_CI_NATIVE": "false", "RAWLAB_MAC_SUITE": "intel"})
        self.assertNotEqual(result.returncode, 0, "build-only runs must not enter native suites")
        self.assertEqual(len([r for r in macos_matrix("full") if r["arch"] == "x86_64"]), 1,
                         "the cold full gate must build x86_64 once")

    def test_build_jobs_cache_cargo_and_source_archives_around_the_native_build(self):
        build_markers = {"macos": "RawLabMac/build.sh", "windows": "build.ps1", "android": "assembleRelease",
                         "ios": "build-framework.sh"}
        same_repo = "github.event.pull_request.head.repo.full_name == github.repository"
        for job_name, marker in build_markers.items():
            steps = self.workflow["jobs"][job_name]["steps"]
            names = [step.get("name", "") for step in steps]
            build = next(i for i, step in enumerate(steps) if marker in step.get("run", ""))
            prep = names.index("Prepare X3F Rust renderer toolchain")
            caches = [("cargo-cache", "Save Cargo registry and git cache")]
            if job_name != "windows":  # Windows keeps its dep-archives cache keyed by native_cache.py
                caches.append(("source-archives-cache", "Save dependency source archives"))
            for cache_id, save_name in caches:
                with self.subTest(job=job_name, cache=cache_id):
                    restore = next(i for i, step in enumerate(steps) if step.get("id") == cache_id)
                    self.assertLess(prep, restore, "restore after the Rust toolchain owns CARGO_HOME")
                    self.assertLess(restore, build, "restore before the native build downloads anything")
                    save = steps[names.index(save_name)]
                    self.assertGreater(names.index(save_name), build)
                    self.assertEqual(save["with"]["key"], steps[restore]["with"]["key"])
                    self.assertEqual(save["with"]["path"], steps[restore]["with"]["path"],
                                     "restore and save must use the same paths or the cache version differs")
                    self.assertIn(same_repo, save["if"])
                    self.assertIn(f"steps.{cache_id}.outputs.cache-hit != 'true'", save["if"])
                    self.assertEqual(steps[restore].get("continue-on-error"), "true")
            if job_name == "windows":
                continue
            env = steps[build].get("env", {})
            cached = steps[next(i for i, step in enumerate(steps) if step.get("id") == "source-archives-cache")]["with"]["path"]
            for variable in ("RAWLAB_SOURCE_ARCHIVE_CACHE", "RAWLAB_LENS_SOURCE_CACHE"):
                if variable in env:
                    relative = env[variable].replace("${{ github.workspace }}/", "")
                    with self.subTest(job=job_name, variable=variable):
                        self.assertIn(relative, cached.split())
            self.assertIn("RAWLAB_SOURCE_ARCHIVE_CACHE", env)
        cargo_paths = self.workflow["jobs"]["windows"]["steps"]
        restore = next(step for step in cargo_paths if step.get("id") == "cargo-cache")
        self.assertIn("${{ runner.temp }}/rawlab-x3f-tools/cargo/registry/cache", restore["with"]["path"],
                      "the cached registry must live in the CARGO_HOME the Rust prep step exports")

    def test_workflow_and_job_env_do_not_reference_invalid_contexts(self):
        workflow_files = sorted(
            list((ROOT / ".github/workflows").glob("*.yml"))
            + list((ROOT / ".github/workflows").glob("*.yaml"))
        )
        self.assertTrue(workflow_files, "No GitHub workflow files found")

        for wf_path in workflow_files:
            wf_data = yaml.load(wf_path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
            rel = wf_path.relative_to(ROOT).as_posix()
            with self.subTest(workflow=rel):
                self.assertEqual(_invalid_env_context_errors(wf_data, rel=rel), [])

        self.assertEqual(_expr_root_contexts("runner.temp"), {"runner"})
        self.assertEqual(_expr_root_contexts("runner['temp']"), {"runner"})
        self.assertEqual(_expr_root_contexts("RUNNER.temp"), {"runner"})
        self.assertEqual(_expr_root_contexts("Runner['TEMP']"), {"runner"})
        self.assertEqual(_expr_root_contexts("format('{0}', steps.foo.outputs.bar)"), {"steps"})
        self.assertEqual(_expr_root_contexts("'runner.temp'"), set())
        self.assertEqual(_expr_root_contexts("TRUE || FALSE || NULL"), set())

        self.assertEqual(
            _env_expr_root_contexts({"TRICKY": "${{ format('}} {0}', runner.temp) }}"}),
            [("TRICKY", "value", "format('}} {0}', runner.temp)", {"runner"})],
        )
        self.assertEqual(
            _env_expr_root_contexts({"TRICKY_ESCAPED": "${{ format('''}} {0}', runner.temp) }}"}),
            [("TRICKY_ESCAPED", "value", "format('''}} {0}', runner.temp)", {"runner"})],
        )

        self.assertEqual(
            _invalid_env_context_errors({
                "env": {"OK": "${{ vars.FOO }}-${{ github.ref }}-${{ inputs.bar }}"},
                "jobs": {"build": {"env": {"OK": "${{ matrix.os }}-${{ needs.prep.outputs.x }}-${{ secrets.TOK }}"}}},
            }),
            [],
        )

        self.assertTrue(_invalid_env_context_errors({"env": {"BAD": "${{ env.FOO }}"}}))
        self.assertTrue(_invalid_env_context_errors({"env": {"BAD": "${{ secrets.TOKEN }}"}}))
        self.assertTrue(_invalid_env_context_errors({"jobs": {"b": {"env": {"BAD": "${{ env.FOO }}"}}}}))
        self.assertTrue(_invalid_env_context_errors({"jobs": {"b": {"env": {"BAD": "${{ RUNNER.temp }}"}}}}))
        self.assertTrue(
            _invalid_env_context_errors({"jobs": {"b": {"env": {"BAD": "${{ format('}} {0}', runner.temp) }}"}}}})
        )


if __name__ == "__main__":
    unittest.main()
