#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:-booted}"
OUT="$(mktemp -d /tmp/rawlab-ios-export.XXXXXX)"
HARNESS="$OUT/ProcessorExportTests.app"
mkdir -p "$HARNESS/Frameworks"
cp "$APP/Info.plist" "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.processor-export' \
    -c 'Set CFBundleExecutable processor-export' "$HARNESS/Info.plist"
cp -R "$APP/Frameworks/sony2fuji.framework" "$HARNESS/Frameworks/"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
xcrun --sdk iphonesimulator swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/ExportSize.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift" \
  "$ROOT/RawLab/RawLab/Core/RawProcessing/RecipeWhiteBalanceCache.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Lens.swift" \
    "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" "$ROOT/RawLab/RawLab/UI/Preview/ZoomablePhoto.swift" \
    "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLab/tests/ProcessorExport/ProcessorExportTests.swift" "$ROOT/RawLab/tests/ProcessorExport/ProcessorExportFixtures.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/processor-export"
codesign --force --deep --sign - "$HARNESS" >/dev/null
if [[ -n "${RAWLAB_TEST_RAW:-}" ]]; then
    SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
        SIMCTL_CHILD_RAWLAB_TEST_MASTER_RECIPES="${RAWLAB_TEST_MASTER_RECIPES:-0}" \
    SIMCTL_CHILD_RAWLAB_TEST_RAW="$RAWLAB_TEST_RAW" \
    SIMCTL_CHILD_RAWLAB_TEST_DENOISE_RAW="${RAWLAB_TEST_DENOISE_RAW:-$RAWLAB_TEST_RAW}" \
        xcrun simctl spawn "$DEVICE" "$HARNESS/processor-export" "$ROOT" "$OUT"
else
    xcrun simctl spawn "$DEVICE" "$HARNESS/processor-export" "$ROOT" "$OUT"
fi
echo "Artifacts: $OUT"
