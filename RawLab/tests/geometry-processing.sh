#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FRAMEWORK="${1:?Pass the built arm64-simulator sony2fuji.framework path}"
DEVICE="${2:?Pass the task-owned simulator UDID}"
RAW="${3:-${RAWLAB_TEST_RAW:-}}"
BASE="$ROOT/build/geometry-processing"
mkdir -p "$BASE"
OUT="$(mktemp -d "$BASE/run.XXXXXX")"
if [[ -n "$RAW" ]]; then
    test -f "$RAW" || { echo "Missing RAW fixture: $RAW" >&2; exit 1; }
    RAW="$(cd "$(dirname "$RAW")" && pwd)/$(basename "$RAW")"
fi
HARNESS="$OUT/GeometryProcessingTests.app"
mkdir -p "$HARNESS/Frameworks"
cat > "$HARNESS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.rawlab.tests.geometry-processing</string>
<key>CFBundleExecutable</key><string>geometry-processing</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>MinimumOSVersion</key><string>18.0</string>
</dict></plist>
PLIST
cp -R "$FRAMEWORK" "$HARNESS/Frameworks/sony2fuji.framework"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -fmodules-cache-path="$OUT/module-cache" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
xcrun --sdk iphonesimulator swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/HSLTargetAdjustment.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/HSLTargetNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/ColorGradingNative.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/ExportSize.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/EditPersistence.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/CachedPhotoFile.swift" \
    "$ROOT/RawLab/RawLab/Core/Batch/Model/BatchExportModels.swift" \
    "$ROOT/RawLab/RawLab/Core/Batch/Storage/BatchExportStorage.swift" \
    "$ROOT/RawLab/RawLab/Core/Batch/Execution/BatchExportRunner.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift" "$ROOT/RawLab/RawLab/Core/RawProcessing/Errors/ProcessorError.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/RecipeWhiteBalanceCache.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Lens.swift" \
    "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLab/tests/GeometryProcessingTests.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/geometry-processing"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/geometry-processing" "$OUT" "$ROOT" "$RAW"
echo "Artifacts: $OUT"
