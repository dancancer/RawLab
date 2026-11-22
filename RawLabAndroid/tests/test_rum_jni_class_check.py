#!/usr/bin/env python3
"""Exercise the release DEX JNI verifier for both RawLab and Aliyun RUM classes."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
CHECKER_PATH = ROOT / "check-rum-jni-classes.py"
SPEC = importlib.util.spec_from_file_location("rum_jni_class_checker", CHECKER_PATH)
CHECKER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CHECKER)

SYNTHETIC_RAWLAB_SO = (
    b"\x00com/rawlab/android/engine/NativeProcessWhiteBalance"
    b"\x00com/rawlab/android/engine/NativeDenoiseConfig"
    b"\x00Lcom/rawlab/android/engine/NativeFrame;"
    b"\x00[Lcom/rawlab/android/looks/DcpCompilationException;"
    b"\x00Java_com_rawlab_android_engine_NativeProcessor_nativeCreate\x00"
    b"Java_com_rawlab_android_engine_NativeLookBridge_native_1check__J\x00"
)
SYNTHETIC_RUM_SO = (
    b"\x00com/alibabacloud/rum/config/ConfigManager"
    b"\x00com/alibabacloud/rum/extra/DynamicNativeClass\x00"
)
EXPECTED_RAWLAB_CLASSES = (
    "com.rawlab.android.engine.NativeProcessWhiteBalance",
    "com.rawlab.android.engine.NativeDenoiseConfig",
    "com.rawlab.android.engine.NativeFrame",
    "com.rawlab.android.looks.DcpCompilationException",
    "com.rawlab.android.engine.NativeProcessor",
    "com.rawlab.android.engine.NativeLookBridge",
)
EXPECTED_RUM_CLASSES = (
    *CHECKER.REQUIRED_CLASSES,
    "com.alibabacloud.rum.extra.DynamicNativeClass",
)


class ReleaseDexJniVerifierTests(unittest.TestCase):
    def _write_apk(self, path: Path, entries: dict[str, bytes]) -> None:
        with zipfile.ZipFile(path, "w") as zf:
            for name, payload in entries.items():
                zf.writestr(name, payload)

    def run_checker(
        self,
        dex_output: str,
        *,
        apk_entries: dict[str, bytes] | None = None,
        extra_args: tuple[str, ...] = (),
    ) -> subprocess.CompletedProcess[str]:
        if apk_entries is None:
            apk_entries = {
                "lib/arm64-v8a/librawlab-jni.so": SYNTHETIC_RAWLAB_SO,
                "lib/arm64-v8a/libproducer.so": SYNTHETIC_RUM_SO,
            }
        with tempfile.TemporaryDirectory(prefix="rawlab-rum-dex-check-") as tmp:
            directory = Path(tmp)
            apk = directory / "release.apk"
            self._write_apk(apk, apk_entries)
            analyzer = directory / "apkanalyzer"
            analyzer.write_text(
                "#!/usr/bin/env python3\nprint(" + repr(dex_output) + ")\n",
                encoding="utf-8",
            )
            analyzer.chmod(0o755)
            return subprocess.run(
                [sys.executable, str(CHECKER_PATH), str(apk), "--apkanalyzer", str(analyzer), *extra_args],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_method_type_reference_does_not_satisfy_defined_class(self) -> None:
        missing = CHECKER.REQUIRED_CLASSES[-1]
        defined = [*(c for c in EXPECTED_RUM_CLASSES if c != missing), *EXPECTED_RAWLAB_CLASSES]
        output = "\n".join(
            [
                *(f"C d 1 1 1 {name}" for name in defined),
                f"M d 1 1 1 owner java.lang.Object method {missing}",
            ]
        )

        result = self.run_checker(output)

        self.assertEqual(result.returncode, 1)
        self.assertIn(missing, result.stderr)

    def test_defined_class_records_satisfy_verifier(self) -> None:
        all_required = (*EXPECTED_RUM_CLASSES, *EXPECTED_RAWLAB_CLASSES)
        output = "\n".join(f"C d 1 1 1 {name}" for name in all_required)

        result = self.run_checker(output)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RUM JNI classes are defined", result.stdout)

    def test_dynamically_discovered_rum_class_in_so_must_be_defined(self) -> None:
        defined = [*CHECKER.REQUIRED_CLASSES, *EXPECTED_RAWLAB_CLASSES]
        output = "\n".join(f"C d 1 1 1 {name}" for name in defined)

        result = self.run_checker(output)

        self.assertEqual(result.returncode, 1)
        self.assertIn("com.alibabacloud.rum.extra.DynamicNativeClass", result.stderr)

    def test_adjacent_nul_delimited_rawlab_jni_class_must_be_defined(self) -> None:
        missing = "com.rawlab.android.engine.NativeDenoiseConfig"
        defined = [*EXPECTED_RUM_CLASSES, *(c for c in EXPECTED_RAWLAB_CLASSES if c != missing)]
        output = "\n".join(f"C d 1 1 1 {name}" for name in defined)

        result = self.run_checker(output)

        self.assertEqual(result.returncode, 1)
        self.assertIn(missing, result.stderr)

    def test_rawlab_native_method_host_class_must_be_defined(self) -> None:
        missing = "com.rawlab.android.engine.NativeLookBridge"
        defined = [*EXPECTED_RUM_CLASSES, *(c for c in EXPECTED_RAWLAB_CLASSES if c != missing)]
        output = "\n".join(f"C d 1 1 1 {name}" for name in defined)

        result = self.run_checker(output)

        self.assertEqual(result.returncode, 1)
        self.assertIn(missing, result.stderr)

    def test_no_rum_skips_rum_checks_but_still_requires_rawlab_jni_classes(self) -> None:
        entries = {"lib/arm64-v8a/librawlab-jni.so": SYNTHETIC_RAWLAB_SO}
        full_rawlab = "\n".join(f"C d 1 1 1 {name}" for name in EXPECTED_RAWLAB_CLASSES)

        ok_result = self.run_checker(full_rawlab, apk_entries=entries, extra_args=("--no-rum",))
        self.assertEqual(ok_result.returncode, 0, ok_result.stderr)
        self.assertIn("RawLab JNI classes are defined", ok_result.stdout)

        missing = "com.rawlab.android.engine.NativeProcessor"
        incomplete_rawlab = "\n".join(f"C d 1 1 1 {name}" for name in EXPECTED_RAWLAB_CLASSES if name != missing)
        bad_result = self.run_checker(incomplete_rawlab, apk_entries=entries, extra_args=("--no-rum",))
        self.assertEqual(bad_result.returncode, 1)
        self.assertIn(missing, bad_result.stderr)

    def test_missing_native_libraries_fail_cleanly(self) -> None:
        all_defined = "\n".join(f"C d 1 1 1 {name}" for name in (*EXPECTED_RUM_CLASSES, *EXPECTED_RAWLAB_CLASSES))

        no_rawlab = self.run_checker(all_defined, apk_entries={"lib/arm64-v8a/libproducer.so": SYNTHETIC_RUM_SO})
        self.assertEqual(no_rawlab.returncode, 2)
        self.assertIn("librawlab-jni.so", no_rawlab.stderr)

        no_producer = self.run_checker(all_defined, apk_entries={"lib/arm64-v8a/librawlab-jni.so": SYNTHETIC_RAWLAB_SO})
        self.assertEqual(no_producer.returncode, 2)
        self.assertIn("libproducer.so", no_producer.stderr)

    def test_decode_jni_host_class_handles_underscores_and_overloads(self) -> None:
        self.assertEqual(
            CHECKER.decode_jni_host_class("Java_com_rawlab_android_engine_Native_1Foo_do_1work__IJ"),
            "com.rawlab.android.engine.Native_Foo",
        )
        self.assertEqual(
            CHECKER.decode_jni_host_class("Java_com_rawlab_android_raster_NativePng16_nativeDecode"),
            "com.rawlab.android.raster.NativePng16",
        )

    def test_native_method_hosts_are_in_the_required_set(self) -> None:
        self.assertIn("com.alibabacloud.rum.producer.LogProducerClient", CHECKER.REQUIRED_CLASSES)
        self.assertIn("com.alibabacloud.rum.producer.LogProducerConfig", CHECKER.REQUIRED_CLASSES)


if __name__ == "__main__":
    unittest.main()
