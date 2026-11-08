#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-system-open.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -swift-version 5 -sdk "$SDK" -module-cache-path "$OUT/module-cache" \
    "$ROOT/Shared/Localization.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/tests/SystemOpenTests.swift" -o "$OUT/test"
"$OUT/test"
