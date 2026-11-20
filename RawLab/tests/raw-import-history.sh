#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the current built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task-owned simulator UUID}"
RAW="${3:?Pass a private real RAW fixture path}"
if [ "$#" -ge 4 ]; then
    rawlab_ios_make_temp_dir OUT run "$4" keep
else
    rawlab_ios_make_temp_dir OUT rawlab-ios-raw-history
fi
HARNESS="$OUT/RawImportHistoryTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.raw-import-history raw-import-history "$APP"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o" "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" "$OUT/module-cache"
rawlab_ios_core_shared_sources SOURCES
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/RawImportHistoryTests.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/raw-import-history"
codesign --force --deep --sign - "$HARNESS" >/dev/null
xcrun simctl spawn "$DEVICE" "$HARNESS/raw-import-history" "$RAW" "$OUT"
if [ "$#" -ge 4 ]; then
    echo "Artifacts: $OUT"
fi
