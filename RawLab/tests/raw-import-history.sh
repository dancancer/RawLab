#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the current built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task-owned simulator UUID}"
RAW="${3:?Pass a private real RAW fixture path}"
BASE="${4:-/tmp/rawlab-ios-raw-history}"
mkdir -p "$BASE"
OUT="$(mktemp -d "$BASE/run.XXXXXX")"
HARNESS="$OUT/RawImportHistoryTests.app"
mkdir -p "$HARNESS/Frameworks"
cp "$APP/Info.plist" "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.raw-import-history' \
    -c 'Set CFBundleExecutable raw-import-history' "$HARNESS/Info.plist"
cp -R "$APP/Frameworks/sony2fuji.framework" "$HARNESS/Frameworks/"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -fmodules-cache-path="$OUT/module-cache" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$ROOT/RawLab/RawLab/Core" "$ROOT/Shared" -g '*.swift')
xcrun --sdk iphonesimulator swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/RawImportHistoryTests.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/raw-import-history"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl spawn "$DEVICE" "$HARNESS/raw-import-history" "$RAW" "$OUT"
echo "Artifacts: $OUT"
