#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="$(mktemp -d /tmp/rawlab-look-model.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -O -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-15.0}" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/Engine.swift" "$ROOT/Shared/ExportMetadata.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments.swift" "$ROOT/RawLabMac/Sources/RenderScheduling.swift" \
    "$ROOT/RawLabMac/Sources/EditPersistence.swift" "$ROOT/RawLabMac/Sources/BatchExport.swift" \
    "$ROOT/RawLabMac/Sources/BatchExportModel.swift" "$ROOT/RawLabMac/Sources/FileLibrary.swift" \
    "$ROOT/RawLabMac/Sources/LookLibrary.swift" "$ROOT/RawLabMac/Sources/EditorModel.swift" \
    "$ROOT/RawLabMac/Sources/ExportSizePicker.swift" \
    "$ROOT/RawLabMac/tests/LookImportModelTests.swift" "$BUILD/libsony2fuji_core.a" \
    -L "$(pkg-config --variable=libdir libraw)" -lraw $(pkg-config --libs opencv4 wavelib) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal \
    -o "$OUT/look-import-model"
"$OUT/look-import-model"
