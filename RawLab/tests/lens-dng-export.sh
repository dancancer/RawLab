#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the built arm64-simulator RawLab.app absolute path}"
DEVICE="${2:?Pass the owned simulator UDID}"
RAW="${3:?Pass a real RAW with matching Lensfun calibration}"
OUTPUT="${4:-$ROOT/build/ios-lens-dng-output}"
rawlab_ios_make_temp_dir OUT rawlab-ios-lens-dng
HARNESS="$OUT/LensDNGExportTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.lens-dng-export lens-dng-export "$APP"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o"
rawlab_ios_processor_export_sources SOURCES full
rawlabnative_flags link "$OUT/swiftpm" iphonesimulator 0 all
rawlab_ios_sim_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -O \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" \
    "$ROOT/RawLab/tests/LensDNGExportTests.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/lens-dng-export"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl spawn "$DEVICE" "$HARNESS/lens-dng-export" "$RAW" "$OUTPUT"
echo "Artifacts: $OUTPUT"
