#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task-owned simulator UUID}"
RAW="${3:?Pass a private Sony RAW fixture path}"
OUTPUT="${4:?Pass the isolated output directory}"
MODE="${5:-tests}"
rawlab_ios_make_temp_dir OUT rawlab-ios-raster-export
HARNESS="$OUT/RasterExportTests.app"
mkdir -p "$OUTPUT"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.raster-export raster-export "$APP"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o" "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" "$OUT/module-cache"
rawlab_ios_core_shared_sources _BASE_SOURCES
SOURCES=()
for file in "${_BASE_SOURCES[@]}"; do
    if [[ "$file" == */RawEditorViewModel+PersistenceAndExport.swift && -n "${RAWLAB_EXPORT_SOURCE:-}" ]]; then
        SOURCES+=("$RAWLAB_EXPORT_SOURCE")
    else
        SOURCES+=("$file")
    fi
done
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/RasterExport/"*.swift "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/raster-export"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/raster-export" "$MODE" "$RAW" "$OUTPUT"
echo "Artifacts: $OUTPUT"
