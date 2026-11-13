#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-hdr-resource-notice.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -swift-version 5 -sdk "$SDK" -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/RawLab/Core/ViewModel/HDRResourceNotice.swift" \
    "$ROOT/RawLab/tests/HDRResourceNoticeTests.swift" -o "$OUT/tests"
cd "$ROOT"
"$OUT/tests"
