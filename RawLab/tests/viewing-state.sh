#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-viewing-state
for TEST in PhotoViewingTests PhotoZoomTests; do
    rawlab_ios_host_swiftc "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" "$ROOT/RawLab/tests/$TEST.swift" -o "$OUT/$TEST"
    "$OUT/$TEST"
done
