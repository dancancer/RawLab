#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-sparkle-adapter
FRAMEWORK="$(bash "$ROOT/RawLabMac/prepare-sparkle.sh")"
rawlab_mac_swiftc -warnings-as-errors \
    -F "$(dirname "$FRAMEWORK")" -framework Sparkle -Xlinker -rpath -Xlinker "$(dirname "$FRAMEWORK")" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/MacUpdateTrust.swift" "$ROOT/RawLabMac/Sources/System/Updates/MacUpdatePackage.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/SparkleUpdateAdapter.swift" "$ROOT/RawLabMac/tests/SparkleUpdateAdapterTests.swift" -o "$OUT/test"
"$OUT/test"
