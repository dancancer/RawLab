#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:-booted}"
rawlab_ios_make_temp_dir OUT rawlab-ios-viewport-state
HARNESS="$OUT/ViewportStateTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.viewport-state viewport-state "$APP"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o"
rawlab_ios_core_shared_sources SOURCES
rawlabnative_flags link "$OUT/swiftpm" iphonesimulator 0 all
rawlab_ios_sim_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/ViewportStateTests.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/viewport-state"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl spawn "$DEVICE" "$HARNESS/viewport-state" "$OUT"
