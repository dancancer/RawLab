#!/usr/bin/env python3
"""Verify that R8 keeps Aliyun RUM Java classes referenced by native libraries."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


REQUIRED_CLASSES = (
    "com.alibabacloud.rum.capture.anr.CaptureANRService",
    "com.alibabacloud.rum.capture.nativecrash.BreakpadInit",
    "com.alibabacloud.rum.capture.nativecrash.NativeCrashInfo",
    "com.alibabacloud.rum.config.ConfigManager",
    "com.alibabacloud.rum.config.ConfigServerHttpTool",
    "com.alibabacloud.rum.config.LogHttpResponse",
    "com.alibabacloud.rum.producer.LogProducerClient",
    "com.alibabacloud.rum.producer.LogProducerConfig",
    "com.alibabacloud.rum.producer.LogHttpResponse",
    "com.alibabacloud.rum.producer.LogProducerHttpTool",
)


def defined_classes(dex_output: str) -> set[str]:
    classes = set()
    for line in dex_output.splitlines():
        columns = line.split()
        if len(columns) >= 6 and columns[0] == "C" and columns[1] == "d":
            classes.add(columns[-1])
    return classes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path, help="minified release APK to inspect")
    parser.add_argument(
        "--apkanalyzer",
        type=Path,
        help="path to Android SDK apkanalyzer (defaults to PATH)",
    )
    args = parser.parse_args()

    apkanalyzer = str(args.apkanalyzer) if args.apkanalyzer else shutil.which("apkanalyzer")
    if not apkanalyzer:
        print("apkanalyzer is required to inspect release DEX classes", file=sys.stderr)
        return 2

    result = subprocess.run(
        [apkanalyzer, "dex", "packages", "--defined-only", str(args.apk)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        print(result.stderr.strip() or "apkanalyzer failed", file=sys.stderr)
        return result.returncode

    present = defined_classes(result.stdout)
    missing = [name for name in REQUIRED_CLASSES if name not in present]
    if missing:
        print("Release APK is missing RUM JNI classes: " + ", ".join(missing), file=sys.stderr)
        return 1

    print("RUM JNI classes are defined in the release APK DEX")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
