#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-ios-adjustment-scale
rawlab_ios_host_swiftc -module-cache-path "$OUT/module-cache" \
    "$ROOT/RawLab/RawLab/UI/Adjustments/AdjustmentScale.swift" \
    "$ROOT/RawLab/tests/AdjustmentScaleTests.swift" -o "$OUT/adjustment-scale"
"$OUT/adjustment-scale"
