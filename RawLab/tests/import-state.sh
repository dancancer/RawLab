#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task simulator UUID}"
if [[ -n "${RAWLAB_IMPORT_STATE_OUT:-}" ]]; then
    OUT="$RAWLAB_IMPORT_STATE_OUT"
    mkdir -p "$OUT"
else
    rawlab_ios_make_temp_dir OUT rawlab-ios-import-state
fi
cleanup() {
    if [[ "${RAWLAB_TEST_PHOTO_LIBRARY:-0}" == "1" ]]; then
        xcrun simctl uninstall "$DEVICE" com.rawlab.tests.import-state >/dev/null 2>&1 || true
    fi
    rawlab_ios_cleanup_temp_dirs
}
trap cleanup EXIT
HARNESS="$OUT/ImportStateTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.import-state import-state "$APP"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o"
rawlab_ios_core_shared_sources SOURCES
TEST_SOURCES=("$ROOT/RawLab/tests/ImportState/"*.swift)
if [[ -n "${RAWLAB_IMPORT_STATE_TEST_SOURCE:-}" ]]; then TEST_SOURCES=("$RAWLAB_IMPORT_STATE_TEST_SOURCE"); fi
rawlabnative_flags link "$OUT/swiftpm" iphonesimulator 0 all
rawlab_ios_sim_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/RawLab/UI/EditorState/EditorCropOverlay.swift" \
    "${TEST_SOURCES[@]}" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/import-state"
codesign --force --deep --sign - "$HARNESS" >/dev/null
if [[ "${RAWLAB_TEST_PHOTO_LIBRARY:-0}" == "1" ]]; then
    xcrun simctl install "$DEVICE" "$HARNESS"
    xcrun simctl privacy "$DEVICE" grant photos com.rawlab.tests.import-state
fi
SIMCTL_CHILD_RAWLAB_TEST_PHOTO_LIBRARY="${RAWLAB_TEST_PHOTO_LIBRARY:-0}" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/import-state" "$OUT" "${3:-}"
if [[ -n "${RAWLAB_IMPORT_STATE_OUT:-}" ]]; then
    echo "Artifacts: $OUT"
fi
