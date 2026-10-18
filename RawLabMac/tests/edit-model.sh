#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-edit-model.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SOURCES=("$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" "$ROOT/RawLabMac/Sources/Looks/Film.swift" "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/RawLabMac/Sources/Editor/Storage/EditPersistence.swift" "$ROOT/RawLabMac/Sources/Export/BatchExport.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Geometry.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Rendering.swift" "$ROOT/Shared/DCPCompiler.swift" "$ROOT/Shared/LookLibrary.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderScheduling.swift" "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift")
if [ -f "$ROOT/RawLabMac/Sources/Export/BatchExportModel.swift" ]; then SOURCES+=("$ROOT/RawLabMac/Sources/Export/BatchExportModel.swift"); fi
SOURCES+=("$ROOT/RawLabMac/Sources/Export/ExportSizePicker.swift")
SOURCES+=("$ROOT/RawLabMac/Sources/Lens/MacStraightenPreview.swift")
SOURCES+=("$ROOT/RawLabMac/Sources/Geometry/MacCropInteraction.swift")
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "$ROOT/Shared/BundledLook.swift" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
  "$ROOT/Shared/UsageAnalytics.swift" \
  "${SOURCES[@]}" "$ROOT/RawLabMac/tests/EditModelTests.swift" \
  "$ROOT/lutools/build-macos/libsony2fuji_core.a" -L "$(pkg-config --variable=libdir libraw)" \
  -lraw $(pkg-config --libs opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$@"
