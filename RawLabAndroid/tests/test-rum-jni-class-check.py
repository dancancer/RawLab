#!/usr/bin/env python3
"""Exercise the RUM DEX verifier against class definitions and references."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
CHECKER_PATH = ROOT / "check-rum-jni-classes.py"
SPEC = importlib.util.spec_from_file_location("rum_jni_class_checker", CHECKER_PATH)
CHECKER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CHECKER)


class RumDexVerifierTests(unittest.TestCase):
    def run_checker(self, output: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="rawlab-rum-dex-check-") as tmp:
            directory = Path(tmp)
            apk = directory / "release.apk"
            apk.touch()
            analyzer = directory / "apkanalyzer"
            analyzer.write_text(
                "#!/usr/bin/env python3\nprint(" + repr(output) + ")\n",
                encoding="utf-8",
            )
            analyzer.chmod(0o755)
            return subprocess.run(
                [sys.executable, str(CHECKER_PATH), str(apk), "--apkanalyzer", str(analyzer)],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_method_type_reference_does_not_satisfy_defined_class(self) -> None:
        missing = CHECKER.REQUIRED_CLASSES[-1]
        output = "\n".join(
            [
                *(f"C d 1 1 1 {name}" for name in CHECKER.REQUIRED_CLASSES if name != missing),
                f"M d 1 1 1 owner java.lang.Object method {missing}",
            ]
        )

        result = self.run_checker(output)

        self.assertEqual(result.returncode, 1)
        self.assertIn(missing, result.stderr)

    def test_defined_class_record_satisfies_verifier(self) -> None:
        output = "\n".join(f"C d 1 1 1 {name}" for name in CHECKER.REQUIRED_CLASSES)

        result = self.run_checker(output)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RUM JNI classes are defined", result.stdout)

    def test_native_method_hosts_are_in_the_required_set(self) -> None:
        self.assertIn("com.alibabacloud.rum.producer.LogProducerClient", CHECKER.REQUIRED_CLASSES)
        self.assertIn("com.alibabacloud.rum.producer.LogProducerConfig", CHECKER.REQUIRED_CLASSES)


if __name__ == "__main__":
    unittest.main()
