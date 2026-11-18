#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-system-open.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "$SDK" -module-cache-path "$OUT/module-cache" \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/tests/SystemOpenTests.swift" -o "$OUT/test"
"$OUT/test"
