#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
source "$ROOT/Shared/tests/mac-native-sources.sh"
rawlab_mac_native_env
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
if [ -n "${RAWLAB_GEOMETRY_DRAFT_OUTPUT_DIR:-}" ]; then
    OUT="$RAWLAB_GEOMETRY_DRAFT_OUTPUT_DIR"
    mkdir -p "$OUT"
else
    rawlab_mac_make_temp_dir OUT rawlab-mac-geometry-draft
fi
RAW="${1:-${RAWLAB_TEST_RAW:-$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG}}"
test -f "$RAW" || { echo 'Set RAWLAB_TEST_RAW or pass an existing RAW path' >&2; exit 1; }
test -f "$BUILD/libsony2fuji_core.a" || { echo 'Build the Mac core first: bash RawLabMac/build.sh' >&2; exit 1; }
SOURCES=()
for name in MacNeutralReference RenderScheduling MacFilm ParameterPrecision Engine RenderError Adjustments+Native BatchSelection EditorModel+BatchSelection EditorModel EditorModel+Geometry EditorModel+HDR EditorModel+ProcessingMigration EditorModel+Workflow EditorModel+Rendering EditorModel+HSLTarget EditorModel+WBProbe EditorModel+Inspection EditorModel+PointColor FileLibrary BatchExportModel ExportSizePicker MacGeometryWindowGuard DesktopUpdateController UpdateAdapter UpdateState UpdateStore UpdateInstallGate LUTCompatibilityDialog FileBrowser GeometryControls ParameterValueField AdjustmentRow MacStraightenPreview MacCropInteraction; do
    source="$(find "$ROOT/RawLabMac/Sources" -name "$name.swift" -print -quit)"
    test -n "$source" || { echo "Missing Mac source: $name" >&2; exit 1; }
    SOURCES+=("$source")
done
for name in HSLTargetNative LUTCompatibilityPreview LUTCompatibilityView; do
    SOURCES+=("$ROOT/Shared/$name.swift")
done
TRANSFER_SOURCES=(
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentHistory.swift"
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentTransfer.swift"
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentPresets.swift"
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+ExternalReload.swift"
)
rawlabnative_flags link "$OUT/swiftpm" macos 0 all
rawlab_mac_native_link_flags NATIVE_LINK
rawlab_mac_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" "${TRANSFER_SOURCES[@]}" -parse-as-library \
    -module-cache-path "$OUT/ModuleCache" -import-objc-header "$MAC_NATIVE_BRIDGING_HEADER" \
    "${SOURCES[@]}" "${MAC_NATIVE_SWIFT_SOURCES[@]}" "$ROOT/RawLabMac/tests/Geometry/"*.swift \
    "${NATIVE_LINK[@]}" -Xlinker -rpath -Xlinker "$(pkg-config --variable=libdir opencv4)" -o "$OUT/test"
"$OUT/test" "$RAW" "$OUT"
if [ -n "${RAWLAB_GEOMETRY_DRAFT_OUTPUT_DIR:-}" ]; then
    echo "Artifacts: $OUT"
fi
