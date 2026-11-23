#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:-booted}"
if [[ -n "${RAWLAB_PROCESSOR_EXPORT_OUT:-}" ]]; then
    OUT="$RAWLAB_PROCESSOR_EXPORT_OUT"
    mkdir -p "$OUT"
else
    rawlab_ios_make_temp_dir OUT rawlab-ios-export
fi
HARNESS="$OUT/ProcessorExportTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.processor-export processor-export "$APP"
TEST_SOURCES=("$ROOT/RawLab/tests/ProcessorExport/"*.swift)
if [[ -n "${RAWLAB_PROCESSOR_TEST_SOURCE:-}" ]]; then TEST_SOURCES=("$RAWLAB_PROCESSOR_TEST_SOURCE"); fi
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o"
rawlab_ios_processor_export_sources SOURCES full
rawlabnative_flags link "$OUT/swiftpm" iphonesimulator 0 all
rawlab_ios_sim_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" \
    "${TEST_SOURCES[@]}" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/processor-export"
codesign --force --deep --sign - "$HARNESS" >/dev/null
if [[ "${RAWLAB_BUILD_ONLY:-0}" == 1 ]]; then
    echo "Built processor export harness without running tests: $HARNESS"
    exit 0
fi
if [[ -n "${RAWLAB_TEST_RAW:-}" ]]; then
    SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
        SIMCTL_CHILD_RAWLAB_TEST_MASTER_RECIPES="${RAWLAB_TEST_MASTER_RECIPES:-0}" \
    SIMCTL_CHILD_RAWLAB_TEST_RAW="$RAWLAB_TEST_RAW" \
    SIMCTL_CHILD_RAWLAB_TEST_DENOISE_RAW="${RAWLAB_TEST_DENOISE_RAW:-$RAWLAB_TEST_RAW}" \
        xcrun simctl spawn "$DEVICE" "$HARNESS/processor-export" "$ROOT" "$OUT"
else
    xcrun simctl spawn "$DEVICE" "$HARNESS/processor-export" "$ROOT" "$OUT"
fi
if [[ -n "${RAWLAB_PROCESSOR_EXPORT_OUT:-}" ]]; then
    echo "Artifacts: $OUT"
fi
