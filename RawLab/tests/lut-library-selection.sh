#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT="$(mktemp -d /tmp/rawlab-lut-library.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$(uname -m)-apple-macosx14.0" \
    "$ROOT/Shared/Localization.swift" "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/RawLab/Core/Looks/IOSLUTLibrarySelection.swift" "$ROOT/RawLab/tests/LUTLibrarySelectionTests.swift" \
    -framework PhotosUI -framework SwiftUI -o "$OUT/library-selection"
"$OUT/library-selection"
