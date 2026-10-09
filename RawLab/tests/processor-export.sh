#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:-booted}"
OUT="$(mktemp -d /tmp/rawlab-ios-export.XXXXXX)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios18.0-simulator
xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift" \
    "$ROOT/RawLab/RawLab/UI/PhotoZoomGeometry.swift" "$ROOT/RawLab/RawLab/UI/ZoomablePhoto.swift" \
    "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLab/tests/ProcessorExportTests.swift" "$OUT/bridge.o" \
    -F "$APP/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker "$APP/Frameworks" -o "$OUT/processor-export"
xcrun simctl spawn "$DEVICE" "$OUT/processor-export" "$ROOT" "$OUT"
echo "Artifacts: $OUT"
