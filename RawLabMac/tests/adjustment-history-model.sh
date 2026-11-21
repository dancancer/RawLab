#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-adjustment-history
rawlab_mac_compile_native editor-model "$OUT/swiftpm" "$OUT/test" -- \
    "$ROOT/RawLabMac/tests/QuickPresetModelChecks.swift" \
    "${RAWLAB_HISTORY_TEST_SOURCE:-$ROOT/RawLabMac/tests/EditorAdjustmentHistoryTests.swift}"
"$OUT/test" "$@"
