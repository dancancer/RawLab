#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
source "$ROOT/Shared/tests/hdr-native-sources.sh"
source "$ROOT/RawLabMac/tests/native-env.sh"
INPUT="${1:?Pass a real RAW fixture}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-batch-render.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
  "$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" "$ROOT/RawLabMac/Sources/Looks/Film.swift" \
  "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" "$ROOT/Shared/Native/ProcessingMigrationNative.swift" "${HDR_SWIFT_SOURCES[@]}" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/HSLTargetNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" "$ROOT/RawLabMac/Sources/Editor/Storage/EditPersistence.swift" \
  "$ROOT/RawLabMac/Sources/Export/BatchExport.swift" "$ROOT/RawLabMac/Sources/Export/BatchExportModel.swift" "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransfer.swift" "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift" "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferWB.swift" \
  "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" "${RAWLAB_BATCH_TEST_SOURCE:-$ROOT/RawLabMac/tests/BatchRenderTests.swift}" \
  "${CORE_LINK[@]}" -L "$(pkg-config --variable=libdir libraw_r)" \
  -lraw_r $(pkg-config --libs opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$INPUT"
