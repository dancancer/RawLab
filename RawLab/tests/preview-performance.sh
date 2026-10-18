#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FRAMEWORK_DIR="${1:?Usage: preview-performance.sh framework-dir simulator-uuid raw-path output-dir}"
DEVICE="${2:?Pass an already booted simulator UUID}"
RAW="${3:?Pass an external RAW fixture}"
OUT="${4:?Pass a git-ignored output directory inside this checkout}"
test -f "$RAW" || { echo "Missing RAW fixture: $RAW" >&2; exit 1; }
RAW="$(cd "$(dirname "$RAW")" && pwd)/$(basename "$RAW")"
if [[ "$(basename "$FRAMEWORK_DIR")" == sony2fuji.framework ]]; then
    FRAMEWORK="$FRAMEWORK_DIR"
else
    FRAMEWORK="$FRAMEWORK_DIR/sony2fuji.framework"
fi
test -f "$FRAMEWORK/sony2fuji" || { echo "Missing simulator framework: $FRAMEWORK" >&2; exit 1; }
if [[ -d "$OUT" ]]; then
    shopt -s nullglob dotglob
    CONTENTS=("$OUT"/*)
    shopt -u nullglob dotglob
    if (( ${#CONTENTS[@]} != 0 )); then
        echo "Output directory must be empty; select a new path to preserve earlier measurements." >&2
        exit 1
    fi
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
git -C "$ROOT" check-ignore -q "$OUT/" || {
    echo "Output must be git-ignored in this checkout (for example build/performance/baseline)." >&2
    exit 1
}
PROCESSOR_ROOT="${RAWLAB_PROCESSOR_SOURCE_ROOT:-$ROOT/RawLab/RawLab/Core/RawProcessing}"
PROCESSOR_ROOT="$(cd "$PROCESSOR_ROOT" && pwd)"
PROCESSOR_SOURCES=("$PROCESSOR_ROOT/Sony2FujiProcessor.swift" "$PROCESSOR_ROOT/Errors/ProcessorError.swift" "$PROCESSOR_ROOT/Sony2FujiProcessor+Helpers.swift"
                   "$PROCESSOR_ROOT/Sony2FujiProcessor+Lens.swift")
if [[ -f "$PROCESSOR_ROOT/RecipeWhiteBalanceCache.swift" ]]; then
    PROCESSOR_SOURCES+=("$PROCESSOR_ROOT/RecipeWhiteBalanceCache.swift")
fi
DEFINES=()
if [[ -z "${RAWLAB_PROCESSOR_SOURCE_ROOT:-}" ]]; then
    DEFINES+=(-D RAWLAB_RECIPE_CACHE_TESTS)
fi
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-preview-performance.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
HARNESS="$TEMP/PreviewPerformanceTests.app"
mkdir -p "$HARNESS/Frameworks"
cp -R "$FRAMEWORK" "$HARNESS/Frameworks/sony2fuji.framework"
cat > "$HARNESS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.rawlab.tests.preview-performance</string>
<key>CFBundleExecutable</key><string>preview-performance</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict></plist>
PLIST
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="${RAWLAB_SIMULATOR_ARCH:-$(uname -m)}-apple-ios18.0-simulator"
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$TEMP/bridge.o"
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
    ${DEFINES[@]+"${DEFINES[@]}"} -module-cache-path "$TEMP/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" \
    "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/ExportMetadata.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" "$ROOT/RawLab/RawLab/Core/Models/ExportSize.swift" \
    "${PROCESSOR_SOURCES[@]}" "$ROOT/RawLab/tests/PreviewPerformanceTests.swift" "$TEMP/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/preview-performance"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
SIMCTL_CHILD_RAWLAB_PERFORMANCE_REFERENCE="${RAWLAB_PERFORMANCE_REFERENCE:-}" \
SIMCTL_CHILD_RAWLAB_PROCESSOR_SOURCE_ROOT="$PROCESSOR_ROOT" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/preview-performance" "$ROOT" "$RAW" "$OUT"
echo "Artifacts: $OUT"
