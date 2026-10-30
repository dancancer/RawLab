#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the current built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task-owned simulator UUID}"
BASE="${3:-/tmp/rawlab-ios-adjustment-history}"
mkdir -p "$BASE"
CACHE="$BASE/module-cache"
OUT="$(mktemp -d "$BASE/run.XXXXXX")"
HARNESS="$OUT/AdjustmentHistoryModelTests.app"
mkdir -p "$HARNESS/Frameworks"
cp "$APP/Info.plist" "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.adjustment-history-model' \
    -c 'Set CFBundleExecutable adjustment-history-model' "$HARNESS/Info.plist"
cp -R "$APP/Frameworks/sony2fuji.framework" "$HARNESS/Frameworks/"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -fmodules-cache-path="$CACHE" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$ROOT/RawLab/RawLab/Core" "$ROOT/Shared" -g '*.swift' -g '!**/tests/**')
xcrun --sdk iphonesimulator swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$CACHE" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/AdjustmentHistoryModelTests.swift" "$ROOT/RawLab/tests/IOSQuickPresetModelChecks.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/adjustment-history-model"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/adjustment-history-model" "$OUT"
echo "Artifacts: $OUT"
