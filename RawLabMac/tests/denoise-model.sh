#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-denoise-model.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/Shared/BundledLook.swift" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
  "$ROOT/Shared/UsageAnalytics.swift" \
  "$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" "$ROOT/RawLabMac/Sources/Looks/Film.swift" "$ROOT/Shared/ExportMetadata.swift" \
  "$ROOT/RawLabMac/Sources/Lens/MacStraightenPreview.swift" \
  "$ROOT/RawLabMac/Sources/Geometry/MacCropInteraction.swift" \
  "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Geometry.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Rendering.swift" \
  "$ROOT/RawLabMac/Sources/Editor/Storage/EditPersistence.swift" "$ROOT/RawLabMac/Sources/Export/BatchExport.swift" \
  "$ROOT/RawLabMac/Sources/Export/BatchExportModel.swift" \
  "$ROOT/RawLabMac/Sources/Export/ExportSizePicker.swift" \
  "$ROOT/RawLabMac/Sources/Library/LookLibrary.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderScheduling.swift" \
  "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" "$ROOT/RawLabMac/tests/DenoiseModelTests.swift" \
  "$ROOT/lutools/build-macos/libsony2fuji_core.a" $(pkg-config --libs libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "${1:?Pass a RAW fixture}"
