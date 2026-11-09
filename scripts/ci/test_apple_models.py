"""Exercise model-runner cache ownership and failure propagation without Xcode."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


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


if __name__ == "__main__":
    unittest.main()
