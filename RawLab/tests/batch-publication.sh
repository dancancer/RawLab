#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass a dedicated simulator UDID}"
rawlab_ios_make_temp_dir OUT rawlab-ios-publication
BUNDLE_ID=com.rawlab.tests.batch-publication
HARNESS="$OUT/BatchPublicationTests.app"
cleanup() {
    xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
    rawlab_ios_cleanup_temp_dirs
}
trap cleanup EXIT
rawlab_ios_prepare_sim_app "$HARNESS" "$BUNDLE_ID" batch-publication "$APP"
RAW_FIXTURE="${RAWLAB_TEST_RAW:-$ROOT/lutools/examples/DJI_20250602164503_0444_D.DNG}"
if [[ -f "$RAW_FIXTURE" ]]; then
    cp "$RAW_FIXTURE" "$HARNESS/batch-raw-fixture.DNG"
fi
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o"
rawlab_ios_core_shared_sources SOURCES "$ROOT/RawLab/RawLab/Core" "$ROOT/RawLab/RawLab/UI" "$ROOT/Shared"
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" "${SOURCES[@]}" \
    "$ROOT/RawLab/tests/BatchPublicationTests.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/batch-publication"
codesign --force --sign - "$HARNESS" >/dev/null
xcrun simctl install "$DEVICE" "$HARNESS"
xcrun simctl privacy "$DEVICE" revoke photos "$BUNDLE_ID"
if [[ -n "${RAWLAB_TEST_RAW:-}" ]]; then
    SIMCTL_CHILD_RAWLAB_TEST_RAW="$RAWLAB_TEST_RAW" xcrun simctl spawn "$DEVICE" "$HARNESS/batch-publication"
else
    xcrun simctl spawn "$DEVICE" "$HARNESS/batch-publication"
fi
