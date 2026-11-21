#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-ios-rum-threading-tests
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -D DEBUG \
    "$ROOT/RawLab/RawLab/Core/Usage/RUMUsageTransport.swift" \
    "$ROOT/RawLab/tests/RUMThreadingTests.swift" \
    -o "$OUT/tests"
"$OUT/tests"
