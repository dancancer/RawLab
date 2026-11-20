#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-usage-ui
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    "$ROOT/RawLabMac/Sources/Presentation/AboutView.swift" \
    "$ROOT/RawLabMac/tests/UsagePrivacyPresentationTests.swift" -o "$OUT/test"
"$OUT/test" "$@"
