#!/usr/bin/env python3
"""Verify that R8 keeps RawLab and Aliyun RUM Java classes referenced by native libraries."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import zipfile
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

_SO_ENTRY_RE = re.compile(r"^lib/[^/]+/[^/]+\.so$")
# Non-consuming boundaries preserve adjacent NUL-delimited class names in .rodata/.dynstr.
_JNI_CLASS_RE = re.compile(
    rb"(?<=[\x00L\[])(com/(?:rawlab/android|alibabacloud/rum)/[A-Za-z0-9_/$]+)(?=[\x00;])"
)
_RAWLAB_JAVA_SYMBOL_RE = re.compile(rb"(?<=\x00)(Java_com_rawlab_android_[A-Za-z0-9_]+)(?=\x00)")


def defined_classes(dex_output: str) -> set[str]:
    classes = set()
    for line in dex_output.splitlines():
        columns = line.split()
        if len(columns) >= 6 and columns[0] == "C" and columns[1] == "d":
            classes.add(columns[-1])
    return classes


def decode_jni_host_class(symbol: str) -> str:
    """Decode a `Java_<pkg>_<cls>_<method>[__sig]` symbol into its dotted class name."""
    if not symbol.startswith("Java_"):
        raise ValueError(f"Expected Java_ JNI symbol, got: {symbol}")
    body = symbol[len("Java_") :].split("__", 1)[0]
    parts: list[str] = []
    buf: list[str] = []
    i = 0
    while i < len(body):
        if body[i] == "_":
            nxt = body[i + 1 : i + 2]
            if nxt == "1":
                buf.append("_")
                i += 2
            elif nxt == "2":
                buf.append(";")
                i += 2
            elif nxt == "3":
                buf.append("[")
                i += 2
            elif nxt == "0" and i + 6 <= len(body):
                buf.append(chr(int(body[i + 2 : i + 6], 16)))
                i += 6
            else:
                parts.append("".join(buf))
                buf = []
                i += 1
        else:
            buf.append(body[i])
            i += 1
    parts.append("".join(buf))
    if len(parts) < 2:
        raise ValueError(f"Malformed JNI symbol (missing method segment): {symbol}")
    return ".".join(parts[:-1])


def native_jni_classes_from_apk(apk: Path, include_rum: bool = True) -> set[str]:
    """Discover JNI class references and RawLab native host classes from packaged `.so` files."""
    if not apk.is_file():
        raise ValueError(f"APK file does not exist: {apk}")
    try:
        zf_ctx = zipfile.ZipFile(apk)
    except zipfile.BadZipFile as exc:
        raise ValueError(f"Invalid APK archive: {apk}") from exc

    rawlab_classes: set[str] = set()
    rum_classes: set[str] = set()
    has_rawlab_jni = False
    has_rum_producer = False

    with zf_ctx as zf:
        for entry in sorted(zf.namelist()):
            if not _SO_ENTRY_RE.match(entry):
                continue
            is_rawlab_jni = entry.endswith("/librawlab-jni.so")
            if is_rawlab_jni:
                has_rawlab_jni = True
            if entry.endswith("/libproducer.so"):
                has_rum_producer = True
            data = zf.read(entry)
            for match in _JNI_CLASS_RE.finditer(data):
                cls = match.group(1).decode("ascii").replace("/", ".")
                if is_rawlab_jni and cls.startswith("com.rawlab.android."):
                    rawlab_classes.add(cls)
                elif include_rum and not is_rawlab_jni and cls.startswith("com.alibabacloud.rum."):
                    rum_classes.add(cls)
            if is_rawlab_jni:
                for match in _RAWLAB_JAVA_SYMBOL_RE.finditer(data):
                    rawlab_classes.add(decode_jni_host_class(match.group(1).decode("ascii")))

    if not has_rawlab_jni:
        raise ValueError(f"Release APK is missing librawlab-jni.so: {apk}")
    if include_rum and not has_rum_producer:
        raise ValueError(f"Release APK is missing libproducer.so (Aliyun RUM SDK): {apk}")

    if include_rum:
        return set(REQUIRED_CLASSES) | rum_classes | rawlab_classes
    return rawlab_classes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path, help="minified release APK to inspect")
    parser.add_argument(
        "--apkanalyzer",
        type=Path,
        help="path to Android SDK apkanalyzer (defaults to PATH)",
    )
    parser.add_argument(
        "--no-rum",
        action="store_true",
        help="skip Aliyun RUM SDK checks (for explicit -PrawlabRumRelease=false offline builds)",
    )
    args = parser.parse_args()

    apkanalyzer = str(args.apkanalyzer) if args.apkanalyzer else shutil.which("apkanalyzer")
    if not apkanalyzer:
        print("apkanalyzer is required to inspect release DEX classes", file=sys.stderr)
        return 2

    include_rum = not args.no_rum
    try:
        required = sorted(native_jni_classes_from_apk(args.apk, include_rum=include_rum))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
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
    missing = [name for name in required if name not in present]
    if missing:
        print("Release APK is missing required JNI classes: " + ", ".join(missing), file=sys.stderr)
        return 1

    scope = "RawLab and RUM JNI classes" if include_rum else "RawLab JNI classes"
    print(f"{scope} are defined in the release APK DEX ({len(required)} checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
