#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="${RAWLAB_GEOMETRY_DRAFT_OUTPUT_DIR:-$(mktemp -d /tmp/rawlab-mac-geometry-draft.XXXXXX)}"
RAW="${1:-${RAWLAB_TEST_RAW:-$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an existing RAW path' >&2; exit 1; }
test -f "$BUILD/libsony2fuji_core.a" || { echo 'Build the Mac core first: bash RawLabMac/build.sh' >&2; exit 1; }
mkdir -p "$OUT"
SOURCES=()
for name in Engine RenderError Film Adjustments AdjustmentTypes MasterRecipe EditPersistence BatchExport EditorModel EditorModel+Geometry EditorModel+Workflow EditorModel+Rendering RenderScheduling FileLibrary BatchExportModel ExportSizePicker MacGeometryWindowGuard GeometryControls ParameterValueField ParameterPrecision AdjustmentRow MacRotationRuler MacStraightenPreview MacCropInteraction; do
    source="$(find "$ROOT/RawLabMac/Sources" -name "$name.swift" -print -quit)"
    test -n "$source" || { echo "Missing Mac source: $name" >&2; exit 1; }
    SOURCES+=("$source")
done
for name in Localization GeometrySettings HSLSettings HSLNative ExportMetadata UsageAnalytics BundledLook DCPCompiler LookLibrary; do
    SOURCES+=("$ROOT/Shared/$name.swift")
done
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -module-cache-path "$OUT/ModuleCache" -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT/RawLabMac/tests/Geometry/"*.swift \
    "$BUILD/libsony2fuji_core.a" $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) \
    -Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir opencv4)" \
    -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$RAW" "$OUT"
echo "Artifacts: $OUT"
