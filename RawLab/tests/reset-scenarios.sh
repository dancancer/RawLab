#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-ios-reset-scenarios
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/modules}" \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "${RAWLAB_RESET_TEST_SOURCE:-$ROOT/RawLab/tests/ResetScenarioTests.swift}" -o "$OUT/tests"
cd "$ROOT"
"$OUT/tests"
