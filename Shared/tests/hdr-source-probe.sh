#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${RAWLAB_TEST_TMP_DIR:-${TMPDIR:-/tmp}}/rawlab-hdr-source-probe.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/HSLSettings.swift" \
    "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/Native/HDRSource.swift" \
    "$ROOT/Shared/tests/HDRSourceProbeTests.swift" "$ROOT/Shared/tests/HDRSourceProbeHarness.swift" \
    -o "$OUT/test"
"$OUT/test"
