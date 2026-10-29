#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-hdr-request.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
SOURCES=("$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift"
    "$ROOT/Shared/HDRRecipe.swift" "$ROOT/Shared/Native/HDRRequest.swift")
swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "${SOURCES[@]}" "$ROOT/Shared/tests/HDRNativeRequestTests.swift" -o "$BUILD/test"
"$BUILD/test"
