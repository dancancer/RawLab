#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the current built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task-owned simulator UUID}"
if [ "$#" -ge 3 ]; then
    rawlab_ios_make_temp_dir OUT run "$3" keep
    CACHE="$3/module-cache"
else
    rawlab_ios_make_temp_dir OUT rawlab-ios-adjustment-history
    CACHE="$OUT/module-cache"
fi
mkdir -p "$CACHE"
HARNESS="$OUT/AdjustmentHistoryModelTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.adjustment-history-model adjustment-history-model "$APP"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o" "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" "$CACHE"
rawlab_ios_core_shared_sources SOURCES
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$CACHE" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/AdjustmentHistoryModelTests.swift" "$ROOT/RawLab/tests/IOSQuickPresetModelChecks.swift" "$ROOT/RawLab/tests/IOSBatchFlowModelChecks.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/adjustment-history-model"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/adjustment-history-model" "$OUT"
if [ "$#" -ge 3 ]; then
    echo "Artifacts: $OUT"
fi
