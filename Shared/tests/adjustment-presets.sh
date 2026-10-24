#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-adjustment-presets.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "${RAWLAB_PRESET_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/Shared/AdjustmentTransfer.swift" "$ROOT/Shared/AdjustmentPresetStore.swift" \
    "$ROOT/Shared/tests/AdjustmentPresetStoreTests.swift" \
    -framework Foundation -o "$OUT/test"
"$OUT/test" "$ROOT/Shared/fixtures/adjustment-presets-v1.json"
