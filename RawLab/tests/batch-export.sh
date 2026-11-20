#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-ios-batch
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/tests/ImportState/BatchSourceJournalTests.swift" \
    "$ROOT/RawLab/tests/BatchSelectionTests.swift" \
    "$ROOT/RawLab/tests/BatchExportTests.swift" \
    -o "$OUT/batch-export"
mkdir -p "$OUT/profile"
CFFIXED_USER_HOME="$OUT/profile" RAWLAB_TEST_PROFILE="$OUT/profile" "$OUT/batch-export"
