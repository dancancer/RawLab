#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-ai-batch
MODEL="${1:?Complete AI model package is required}"
RAW="${2:?RAW input is required}"
APP="$OUT/RawLab.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/AI" "$OUT/home"
ln -s "$MODEL" "$APP/Contents/Resources/AI/DualDn"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.rawlab.tests.ai-batch</string><key>CFBundleExecutable</key><string>test</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' > "$APP/Contents/Info.plist"
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$APP/Contents/MacOS/test" -- \
    "$ROOT/RawLabMac/tests/AIBatchNativeTests.swift"
CFFIXED_USER_HOME="$OUT/home" "$APP/Contents/MacOS/test" "$RAW" "$OUT" "${3:-$OUT}"
