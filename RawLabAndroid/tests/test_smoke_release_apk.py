#!/usr/bin/env python3
"""Exercise RawLabAndroid/scripts/smoke-release-apk.sh with stubbed Android CLI tools."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "smoke-release-apk.sh"


class SmokeReleaseApkTests(unittest.TestCase):
    def _run_smoke(
        self,
        *,
        serial: str = "emulator-5554",
        launches: int = 2,
        settle_seconds: int = 0,
        adb_mode: str = "ok",
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory(prefix="rawlab-smoke-test-") as tmp:
            tmp_dir = Path(tmp)
            apk = tmp_dir / "RawLab-Android-release.apk"
            apk.write_bytes(b"PK\x03\x04stub-apk")
            adb_log = tmp_dir / "adb-calls.log"
            state_file = tmp_dir / "launched.state"

            apksigner = tmp_dir / "apksigner"
            apksigner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            apksigner.chmod(apksigner.stat().st_mode | stat.S_IXUSR)

            adb = tmp_dir / "adb"
            adb.write_text(
                f"""#!/usr/bin/env python3
import pathlib
import sys

log_path = pathlib.Path({str(adb_log)!r})
state_path = pathlib.Path({str(state_file)!r})
mode = {adb_mode!r}

args = sys.argv[1:]
with log_path.open("a", encoding="utf-8") as fh:
    fh.write(" ".join(args) + "\\n")

# Strip leading -P <port> and -s <serial>
idx = 0
while idx < len(args) and args[idx] in ("-P", "-s"):
    idx += 2
cmd = args[idx:]

if cmd[:1] == ["devices"]:
    print("List of devices attached")
    print("emulator-5554\\tdevice")
    sys.exit(0)
if cmd[:1] == ["uninstall"] or cmd[:1] == ["install"]:
    sys.exit(0)
if cmd[:1] == ["logcat"]:
    if "-d" in cmd and "-b" in cmd and "crash" in cmd:
        if mode == "crash_buffer":
            print("--------- beginning of crash")
            print("Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in com.rawlab.android")
            print("Process: com.rawlab.android, PID: 4242")
    elif "-d" in cmd:
        if mode == "main_class_error":
            print("01-01 00:00:01.000  4242  4242 E AndroidRuntime: java.lang.NoClassDefFoundError: Failed resolution of: Lcom/alibabacloud/rum/config/ConfigServerHttpTool; for com.rawlab.android")
    sys.exit(0)
if cmd[:2] == ["shell", "am"]:
    if cmd[2:3] == ["force-stop"]:
        state_path.unlink(missing_ok=True)
        sys.exit(0)
    if cmd[2:3] == ["start"]:
        state_path.write_text("4242", encoding="utf-8")
        print("Starting: Intent {{ cmp=com.rawlab.android/.MainActivity }}")
        print("Status: ok")
        print("LaunchState: COLD")
        sys.exit(0)
if cmd[:2] == ["shell", "pidof"]:
    if state_path.exists():
        if mode == "silent_exit":
            sys.exit(0)
        print("4242")
    sys.exit(0)
sys.exit(0)
""",
                encoding="utf-8",
            )
            adb.chmod(adb.stat().st_mode | stat.S_IXUSR)

            env = {
                key: value
                for key, value in os.environ.items()
                if key not in ("ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_SERIAL")
            }
            result = subprocess.run(
                [
                    "bash",
                    str(SCRIPT),
                    str(apk),
                    "--serial",
                    serial,
                    "--launches",
                    str(launches),
                    "--settle-seconds",
                    str(settle_seconds),
                    "--adb",
                    str(adb),
                    "--apksigner",
                    str(apksigner),
                ],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            calls = adb_log.read_text(encoding="utf-8") if adb_log.exists() else ""
            return result, calls

    def test_refuses_physical_device_serial_before_uninstalling(self) -> None:
        result, calls = self._run_smoke(serial="R5CW12345")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("emulator", result.stderr.lower())
        self.assertNotIn("uninstall", calls)

    def test_fails_when_crash_logcat_records_sigabrt(self) -> None:
        result, _ = self._run_smoke(adb_mode="crash_buffer")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SIGABRT", result.stderr)

    def test_fails_when_process_exits_after_launch(self) -> None:
        result, _ = self._run_smoke(adb_mode="silent_exit", settle_seconds=0)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exited immediately", result.stderr)

    def test_fails_when_main_logcat_records_missing_class_error(self) -> None:
        result, _ = self._run_smoke(adb_mode="main_class_error")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NoClassDefFoundError", result.stderr)

    def test_passes_after_two_clean_cold_starts(self) -> None:
        result, calls = self._run_smoke(launches=2, settle_seconds=0, adb_mode="ok")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2/2 launches", result.stdout)
        self.assertEqual(calls.count("shell am start -W -S"), 2)
        self.assertGreaterEqual(calls.count("shell am force-stop"), 3)


if __name__ == "__main__":
    unittest.main()
