#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d /tmp/rawlab-ios-batch.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "$SDK" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/tests/ImportState/BatchSourceJournalTests.swift" \
    "$ROOT/RawLab/tests/BatchSelectionTests.swift" \
    "$ROOT/RawLab/tests/BatchExportTests.swift" \
    -o "$OUT/batch-export"
mkdir -p "$OUT/profile"
CFFIXED_USER_HOME="$OUT/profile" RAWLAB_TEST_PROFILE="$OUT/profile" "$OUT/batch-export"
