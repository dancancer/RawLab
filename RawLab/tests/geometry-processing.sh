#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
FRAMEWORK="${1:?Pass the built arm64-simulator sony2fuji.framework path}"
DEVICE="${2:?Pass the task-owned simulator UDID}"
RAW="${3:-${RAWLAB_TEST_RAW:-}}"
if [[ -n "${RAWLAB_GEOMETRY_OUTPUT_DIR:-}" ]]; then
    OUT="$RAWLAB_GEOMETRY_OUTPUT_DIR"
    mkdir -p "$OUT"
else
    rawlab_ios_make_temp_dir OUT rawlab-ios-geometry-processing
fi
if [[ -n "$RAW" ]]; then
    test -f "$RAW" || { echo "Missing RAW fixture: $RAW" >&2; exit 1; }
    RAW="$(cd "$(dirname "$RAW")" && pwd)/$(basename "$RAW")"
fi
HARNESS="$OUT/GeometryProcessingTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.geometry-processing geometry-processing "$FRAMEWORK"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o" "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" "$OUT/module-cache"
rawlab_ios_processor_export_sources SOURCES hdr
rawlabnative_flags link "$OUT/swiftpm" iphonesimulator 0 types_only
rawlab_ios_sim_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" \
    "$ROOT/RawLab/tests/GeometryProcessingTests.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/geometry-processing"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/geometry-processing" "$OUT" "$ROOT" "$RAW"
if [[ -n "${RAWLAB_GEOMETRY_OUTPUT_DIR:-}" ]]; then
    echo "Artifacts: $OUT"
fi
