#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-effects-ui
rawlab_mac_compile_native full-app "$OUT/swiftpm" "$OUT/effects-ui" -- \
    -O "$ROOT/RawLabMac/tests/PhotoEffectsPresentationTests.swift"
"$OUT/effects-ui" "${1:?Pass a RAW fixture}" "${2:?Pass a screenshot directory}"
