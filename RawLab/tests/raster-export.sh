#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task-owned simulator UUID}"
RAW="${3:?Pass a private Sony RAW fixture path}"
OUTPUT="${4:?Pass the isolated output directory}"
MODE="${5:-tests}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-raster-export.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
HARNESS="$OUT/RasterExportTests.app"
mkdir -p "$HARNESS/Frameworks" "$OUTPUT"
cp "$APP/Info.plist" "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.raster-export' \
    -c 'Set CFBundleExecutable raster-export' "$HARNESS/Info.plist"
cp -R "$APP/Frameworks/sony2fuji.framework" "$HARNESS/Frameworks/"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -fmodules-cache-path="$OUT/module-cache" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
SOURCES=()
while IFS= read -r file; do
    if [[ "$file" == */RawEditorViewModel+PersistenceAndExport.swift && -n "${RAWLAB_EXPORT_SOURCE:-}" ]]; then
        SOURCES+=("$RAWLAB_EXPORT_SOURCE")
    else
        SOURCES+=("$file")
    fi
done < <(find "$ROOT/RawLab/RawLab/Core" "$ROOT/Shared" -name '*.swift' -not -path '*/tests/*' | sort)
# bash 3.2 在 set -u 展开空数组失败时，EXIT trap 会把退出码吞成 0，所以显式失败。
[[ ${#SOURCES[@]} -gt 0 ]] || { echo "No Swift sources found under $ROOT" >&2; exit 1; }
xcrun --sdk iphonesimulator swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/RasterExport/"*.swift "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/raster-export"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/raster-export" "$MODE" "$RAW" "$OUTPUT"
echo "Artifacts: $OUTPUT"
