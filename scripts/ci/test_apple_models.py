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
                        self.assertEqual(len(calls), 1, "A failing suite must stop later suites")
                    else:
                        self.assertGreater(len(calls), 1)

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
        self.assertIn("[model] Shared/tests/adjustment-summary.sh", result.stdout,
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
            "/Users/SKIP/repo/Shared/HDRSettings.swift:8:1: note: in expansion of macro",
            "PASS: batch export SKIP action preserves active draft",
        ))
        for platform in ("macos", "ios"):
            with self.subTest(platform=platform):
                result = self._run_skip_probe(root, runner, tools, platform, benign)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS: batch export SKIP action preserves active draft", result.stdout)


if __name__ == "__main__":
    unittest.main()
