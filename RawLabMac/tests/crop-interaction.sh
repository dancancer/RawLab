#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-crop-interaction.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -swift-version 5 -sdk "$SDK" \
    -module-cache-path "$OUT/ModuleCache" \
    "$ROOT/Shared/GeometrySettings.swift" "$ROOT/RawLabMac/tests/CropInteractionTests.swift" -o "$OUT/tests"
"$OUT/tests"
