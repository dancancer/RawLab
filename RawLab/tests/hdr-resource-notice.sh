#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-ios-hdr-resource-notice
rawlab_ios_host_swiftc -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/RawLab/Core/ViewModel/HDRResourceNotice.swift" \
    "$ROOT/RawLab/tests/HDRResourceNoticeTests.swift" -o "$OUT/tests"
cd "$ROOT"
"$OUT/tests"
