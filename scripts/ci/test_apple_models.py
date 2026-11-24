"""Exercise model-runner cache ownership and failure propagation without Xcode."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]

# The shared AX gate's fixed honest-skip pair (RawLabMac/tests/ax-gate.sh). The models
# invariant-7 enforcement lets exactly this wording through, and only for the suites
# in AX_HONEST_SKIP_SUITES there.
AX_GATE_SKIP_PAIR = "\n".join((
    "SKIP: accessibility is not trusted here; the AX checks did not run",
    "::warning::SKIP: accessibility is not trusted here; the AX checks did not run",
))


class AppleModelRunnerTests(unittest.TestCase):
    def test_cache_is_shared_within_a_run_and_removed_after_success_or_failure(self):
        with tempfile.TemporaryDirectory(prefix="rawlab model cache ") as directory:
            root = Path(directory)
            runner = root / "scripts/ci/apple-models.sh"
            runner.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "scripts/ci/apple-models.sh", runner)
            tools = root / "bin"
            tools.mkdir()
            for name in ("xcode-select", "xcrun", "python3"):
                tool = tools / name
                tool.write_text("#!/bin/sh\necho /unused/sdk\n")
                tool.chmod(0o755)
            swift_tool = tools / "swift"
            swift_tool.write_text("#!/bin/sh\necho 'PASS: simulated swift test'\n")
            swift_tool.chmod(0o755)
            child = tools / "bash"
            child.write_text('''#!/bin/bash
set -eu
: "${RAWLAB_TRANSFER_MODULE_CACHE:?missing shared cache}"
if [[ -f "$PROBE_LOG" ]]; then
    test -f "$RAWLAB_TRANSFER_MODULE_CACHE/marker"
else
    mkdir -p "$RAWLAB_TRANSFER_MODULE_CACHE"
    touch "$RAWLAB_TRANSFER_MODULE_CACHE/marker"
fi
printf '%s\n' "$RAWLAB_TRANSFER_MODULE_CACHE" >> "$PROBE_LOG"
exit "$PROBE_EXIT"
''')
            child.chmod(0o755)
            external = root / "caller-cache"
            external.mkdir()
            sentinel = external / "keep"
            sentinel.write_text("caller-owned")
            seen = set()
            for platform, code in (("macos", 0), ("ios", 0), ("macos", 23), ("ios", 7)):
                with self.subTest(platform=platform, exit=code):
                    log = root / "calls"
                    log.unlink(missing_ok=True)
                    result = subprocess.run(["/bin/bash", str(runner), platform],
                        env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                             "TMPDIR": str(root), "PROBE_LOG": str(log), "PROBE_EXIT": str(code),
                             "RAWLAB_TRANSFER_MODULE_CACHE": str(external)},
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                    calls = log.read_text().splitlines()
                    self.assertEqual(len(set(calls)), 1, "Child suites must reuse the same cache")
                    cache = Path(calls[0])
                    self.assertNotEqual(cache, external)
                    self.assertNotIn(cache, seen, "Separate runs must not reuse a cache")
                    seen.add(cache)
                    self.assertFalse(cache.exists(), "Success and failure must clean up owned cache")
                    self.assertEqual(sentinel.read_text(), "caller-owned")
                    self.assertEqual(list(external.iterdir()), [sentinel])
                    if code:
                        self.assertGreaterEqual(len(calls), 1)
                        self.assertLessEqual(len(calls), 4, "A failing batch must stop remaining suites")
                    else:
                        self.assertGreater(len(calls), 1)
            for platform, code in (("macos", 23), ("ios", 7)):
                with self.subTest(platform=platform, exit=code, jobs="1"):
                    log = root / "calls"
                    log.unlink(missing_ok=True)
                    result = subprocess.run(["/bin/bash", str(runner), platform],
                        env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                             "TMPDIR": str(root), "PROBE_LOG": str(log), "PROBE_EXIT": str(code),
                             "RAWLAB_APPLE_MODELS_JOBS": "1",
                             "RAWLAB_TRANSFER_MODULE_CACHE": str(external)},
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                    calls = log.read_text().splitlines()
                    self.assertEqual(len(calls), 1, "A failing suite must stop later suites under JOBS=1")

    def _skip_probe_root(self):
        directory = tempfile.TemporaryDirectory(prefix="rawlab model skip ")
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        runner = root / "scripts/ci/apple-models.sh"
        runner.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/ci/apple-models.sh", runner)
        tools = root / "bin"
        tools.mkdir()
        for name in ("xcode-select", "xcrun", "python3"):
            tool = tools / name
            tool.write_text("#!/bin/sh\necho /unused/sdk\n")
            tool.chmod(0o755)
        swift_tool = tools / "swift"
        swift_tool.write_text("#!/bin/bash\nset -eu\nif [[ -n \"${INJECT_FOR:-}\" ]]; then printf 'PASS: simulated swift test\\n'; else printf '%s\\n' \"${INJECT_OUT:-PASS: simulated swift test}\"; fi\n")
        swift_tool.chmod(0o755)
        child = tools / "bash"
        child.write_text('''#!/bin/bash
set -eu
if [[ -n "${INJECT_FOR:-}" && "$1" != *"$INJECT_FOR"* ]]; then
    printf 'PASS: simulated success without skip\\n'
else
    printf '%s\\n' "${INJECT_OUT:-PASS: simulated success without skip}"
fi
exit 0
''')
        child.chmod(0o755)
        return root, runner, tools

    def _run_skip_probe(self, root, runner, tools, platform, injected, only_for=None):
        env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
               "TMPDIR": str(root), "INJECT_OUT": injected}
        if only_for is not None:
            env["INJECT_FOR"] = only_for
        return subprocess.run(["/bin/bash", str(runner), platform],
            env=env, capture_output=True, text=True)

    def test_logged_skip_fails_both_platform_routes_even_if_child_exited_zero(self):
        root, runner, tools = self._skip_probe_root()
        markers = {"colon-marker": "SKIP: simulated skipped capability",
                   "fixture-marker": "SKIP HDR originals: pass read-only HDR fixture paths"}
        for platform in ("macos", "ios"):
            for name, injected in markers.items():
                with self.subTest(platform=platform, marker=name):
                    result = self._run_skip_probe(root, runner, tools, platform, injected)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("logged SKIP (forbidden by CI invariant 7)", result.stderr)

    def test_ax_gate_honest_skip_passes_for_the_allowlisted_model_suite(self):
        # The gate scripts joined the models list (ios-reset-entry-ui.sh), so the models
        # route is the first place invariant 7 meets the gate's designed honest skip.
        root, runner, tools = self._skip_probe_root()
        result = self._run_skip_probe(root, runner, tools, "ios", AX_GATE_SKIP_PAIR,
                                      only_for="RawLab/tests/ios-reset-entry-ui.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("::warning::SKIP: accessibility is not trusted here", result.stdout)
        self.assertNotIn("forbidden by CI invariant 7", result.stderr)
        self.assertIn("[model] RawLab/tests/edit-records.sh", result.stdout,
                      "the allowed honest skip must not stop the later suites")

    def test_ax_gate_skip_wording_outside_the_allowlist_still_fails(self):
        # The wording itself grants no exemption: logged by non-allowlisted suites (the
        # global injection hits the first suite of each route), the skip stays red.
        root, runner, tools = self._skip_probe_root()
        for platform in ("macos", "ios"):
            with self.subTest(platform=platform):
                result = self._run_skip_probe(root, runner, tools, platform, AX_GATE_SKIP_PAIR)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("logged SKIP (forbidden by CI invariant 7)", result.stderr)

    def test_allowlisted_suite_needs_the_exact_gate_skip_pair(self):
        root, runner, tools = self._skip_probe_root()
        variants = {
            "skip-without-warning": AX_GATE_SKIP_PAIR.splitlines()[0],
            "other-accessibility-wording": "\n".join((
                "SKIP: accessibility is not trusted here; this AX check is skipped",
                "::warning::SKIP: accessibility is not trusted here; this AX check is skipped",
            )),
        }
        for name, injected in variants.items():
            with self.subTest(variant=name):
                result = self._run_skip_probe(root, runner, tools, "ios", injected,
                                              only_for="RawLab/tests/ios-reset-entry-ui.sh")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("logged SKIP (forbidden by CI invariant 7)", result.stderr)

    def test_allowlisted_suite_still_fails_on_a_smuggled_second_skip(self):
        # The allow-list exempts exactly the gate's own pair; a smuggled leading-SKIP
        # line in the same log keeps the suite red (round-2 review Should-fix 2).
        root, runner, tools = self._skip_probe_root()
        smuggled = AX_GATE_SKIP_PAIR + "\nSKIP: simulated skipped capability"
        result = self._run_skip_probe(root, runner, tools, "ios", smuggled,
                                      only_for="RawLab/tests/ios-reset-entry-ui.sh")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("logged SKIP (forbidden by CI invariant 7)", result.stderr)

    def test_benign_skip_like_output_stays_green(self):
        root, runner, tools = self._skip_probe_root()
        benign = "\n".join((
            "PASS: RAWLAB_SKIP_AX=0 and SKIP_RETURN_CODE=77",
            "PASS: skipped=0 SKIPPED=0 CGImageAlphaInfo.noneSkipLast",
            "/tmp/worktree-SKIP-check/Shared/Localization.swift:12:5: warning: unused value",
            "/U" "sers/SKIP/repo/Shared/HDRSettings.swift:8:1: note: in expansion of macro",
            "PASS: batch export SKIP action preserves active draft",
        ))
        for platform in ("macos", "ios"):
            with self.subTest(platform=platform):
                result = self._run_skip_probe(root, runner, tools, platform, benign)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS: batch export SKIP action preserves active draft", result.stdout)

    def test_apple_models_includes_thumbnail_cache_suite(self):
        script = (ROOT / "scripts/ci/apple-models.sh").read_text(encoding="utf-8")
        self.assertIn("RawLabMac/tests/thumbnail-cache.sh", script)

    def _parallel_probe_root(self):
        directory = tempfile.TemporaryDirectory(prefix="rawlab parallel models ")
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        runner = root / "scripts/ci/apple-models.sh"
        runner.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/ci/apple-models.sh", runner)
        tools = root / "bin"
        tools.mkdir()
        for name in ("xcode-select", "xcrun", "python3"):
            tool = tools / name
            tool.write_text("#!/bin/sh\necho /unused/sdk\n")
            tool.chmod(0o755)
        swift_tool = tools / "swift"
        swift_tool.write_text("#!/bin/sh\necho 'PASS: simulated swift test'\n")
        swift_tool.chmod(0o755)
        child = tools / "bash"
        child.write_text('''#!/bin/bash
set -eu
suite="$1"
printf '%s|%s|%s\n' "$suite" "$TMPDIR" "$RAWLAB_TEST_TMP_DIR" >> "$PROBE_RECORDS"
active_dir="$PROBE_ACTIVE/$(basename "$suite").$$"
mkdir -p "$active_dir"
sleep 0.12
count="$(ls -1 "$PROBE_ACTIVE" | wc -l | tr -d ' ')"
printf '%s\n' "$count" >> "$PROBE_COUNTS"
rmdir "$active_dir"
if [[ -n "${SKIP_SUITES:-}" ]] && [[ ",${SKIP_SUITES}," == *",${suite},"* ]]; then
    printf '%s\n' "${SKIP_PAYLOAD:-SKIP: simulated concurrent skip}"
    exit 0
fi
printf 'PASS: %s line 1\n' "$suite"
sleep 0.02
printf 'PASS: %s line 2\n' "$suite"
''')
        child.chmod(0o755)
        return root, runner, tools

    def test_parallel_suites_isolate_logs_and_tmpdirs_and_respect_concurrency_cap(self):
        root, runner, tools = self._parallel_probe_root()
        for jobs, min_c, max_c in ((None, 2, 4), ("1", 1, 1)):
            with self.subTest(jobs=jobs):
                records = root / f"records-{jobs or 'default'}"
                counts = root / f"counts-{jobs or 'default'}"
                active = root / f"active-{jobs or 'default'}"
                active.mkdir()
                env = {
                    **os.environ,
                    "PATH": f"{tools}:{os.environ['PATH']}",
                    "TMPDIR": f"{root}/",
                    "PROBE_RECORDS": str(records),
                    "PROBE_COUNTS": str(counts),
                    "PROBE_ACTIVE": str(active),
                }
                if jobs is not None:
                    env["RAWLAB_APPLE_MODELS_JOBS"] = jobs
                else:
                    env.pop("RAWLAB_APPLE_MODELS_JOBS", None)
                result = subprocess.run(["/bin/bash", str(runner), "ios"], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                lines = records.read_text().splitlines()
                self.assertEqual(len(lines), 30)
                tmpdirs = [line.split("|")[1] for line in lines]
                rawlab_tmps = [line.split("|")[2] for line in lines]
                self.assertEqual(len(set(tmpdirs)), len(lines), "Each suite must get an isolated TMPDIR")
                self.assertEqual(tmpdirs, rawlab_tmps)
                for td in tmpdirs:
                    self.assertNotIn("//", td, f"Suite TMPDIR must normalize trailing slash: {td}")
                    self.assertFalse(Path(td).exists(), f"Suite temp dir not cleaned: {td}")
                observed_max = max(int(c) for c in counts.read_text().splitlines())
                self.assertGreaterEqual(observed_max, min_c)
                self.assertLessEqual(observed_max, max_c)
                # Verify logs are replayed atomically per suite without interleaving.
                out_lines = [l for l in result.stdout.splitlines() if l.startswith(("[model] ", "PASS: "))]
                model_headers = [i for i, l in enumerate(out_lines) if l.startswith("[model] ")]
                self.assertEqual(len(model_headers), len(lines))
                for idx in model_headers:
                    suite_name = out_lines[idx].split(" ", 1)[1]
                    self.assertEqual(out_lines[idx + 1], f"PASS: {suite_name} line 1")
                    self.assertEqual(out_lines[idx + 2], f"PASS: {suite_name} line 2")

    def test_parallel_logged_skip_in_any_concurrent_worker_fails_without_swallowing(self):
        root, runner, tools = self._parallel_probe_root()
        records = root / "records"
        counts = root / "counts"
        active = root / "active"
        active.mkdir()
        result = subprocess.run(
            ["/bin/bash", str(runner), "macos"],
            env={
                **os.environ,
                "PATH": f"{tools}:{os.environ['PATH']}",
                "TMPDIR": str(root),
                "PROBE_RECORDS": str(records),
                "PROBE_COUNTS": str(counts),
                "PROBE_ACTIVE": str(active),
                "SKIP_SUITES": "Shared/tests/hdr-source-probe.sh",
                "SKIP_PAYLOAD": "SKIP: simulated concurrent skip",
            },
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("error: Shared/tests/hdr-source-probe.sh logged SKIP (forbidden by CI invariant 7)", result.stderr)

    def test_parallel_ax_honest_skip_allows_only_allowlisted_suite_while_concurrent_skip_elsewhere_fails(self):
        root, runner, tools = self._parallel_probe_root()
        for idx, (skip_suites, expected_rc) in enumerate((
            ("RawLab/tests/ios-reset-entry-ui.sh", 0),
            ("RawLab/tests/ios-reset-entry-ui.sh,RawLab/tests/hdr-model.sh", 1),
        )):
            with self.subTest(skip_suites=skip_suites):
                active = root / f"active-{idx}"
                active.mkdir()
                result = subprocess.run(
                    ["/bin/bash", str(runner), "ios"],
                    env={
                        **os.environ,
                        "PATH": f"{tools}:{os.environ['PATH']}",
                        "TMPDIR": str(root),
                        "PROBE_RECORDS": str(root / f"records-{idx}"),
                        "PROBE_COUNTS": str(root / f"counts-{idx}"),
                        "PROBE_ACTIVE": str(active),
                        "SKIP_SUITES": skip_suites,
                        "SKIP_PAYLOAD": AX_GATE_SKIP_PAIR,
                    },
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, expected_rc, result.stdout + result.stderr)
                if expected_rc == 0:
                    self.assertIn("::warning::SKIP: accessibility is not trusted here", result.stdout)
                else:
                    self.assertIn("error: RawLab/tests/hdr-model.sh logged SKIP (forbidden by CI invariant 7)", result.stderr)


if __name__ == "__main__":
    unittest.main()
