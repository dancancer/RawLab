#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-retention
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -whole-module-optimization -module-cache-path "$OUT/modules" \
    "$ROOT/RawLab/RawLab/Core/Batch/Storage/ExportEvidenceStore.swift" \
    "$ROOT/RawLab/tests/RetentionTests.swift" -o "$OUT/tests"
"$OUT/tests"
