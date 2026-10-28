#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-denoise-model.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
TRANSFER_SOURCES=(
  "$ROOT/Shared/AdjustmentTransfer.swift"
  "$ROOT/Shared/AdjustmentPresetStore.swift"
  "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransfer.swift"
  "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift"
  "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferWB.swift"
  "$ROOT/RawLabMac/Sources/Editor/Storage/AdjustmentTransferSession.swift"
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentHistory.swift"
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentTransfer.swift"
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentPresets.swift"
)
swiftc "${TRANSFER_SOURCES[@]}" "$ROOT/Shared/Localization.swift" -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    "$ROOT/Shared/BundledLook.swift" \
  "$ROOT/RawLabMac/Sources/Presentation/MacNeutralReference.swift" "$ROOT/RawLabMac/Sources/Inputs/ParameterValueField.swift" "$ROOT/RawLabMac/Sources/Inputs/ParameterPrecision.swift" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
  "$ROOT/Shared/UsageAnalytics.swift" \
  "$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" "$ROOT/RawLabMac/Sources/Looks/Film.swift" "$ROOT/Shared/ExportMetadata.swift" \
  "$ROOT/RawLabMac/Sources/Lens/MacStraightenPreview.swift" \
  "$ROOT/RawLabMac/Sources/Geometry/MacCropInteraction.swift" \
  "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/HSLTargetAdjustment.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/HSLTargetNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" "$ROOT/Shared/BatchSelectionSession.swift" "$ROOT/RawLabMac/Sources/Export/BatchSelection.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+BatchSelection.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Geometry.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift" "$ROOT/RawLabMac/Sources/Looks/LUTCompatibilityDialog.swift" "$ROOT/Shared/LUTCompatibilityView.swift" "$ROOT/Shared/LUTCompatibilityPreview.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Rendering.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+HSLTarget.swift" \
  "$ROOT/RawLabMac/Sources/Editor/Storage/EditPersistence.swift" "$ROOT/RawLabMac/Sources/Export/BatchExport.swift" \
  "$ROOT/RawLabMac/Sources/Export/BatchExportModel.swift" \
  "$ROOT/RawLabMac/Sources/Export/ExportSizePicker.swift" \
  "$ROOT/Shared/DCPCompiler.swift" "$ROOT/Shared/LookLibrary.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderScheduling.swift" \
  "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" "$ROOT/RawLabMac/Sources/Library/FileBrowser.swift" "$ROOT/RawLabMac/tests/DenoiseModelTests.swift" \
  "${CORE_LINK[@]}" $(pkg-config --libs libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "${1:?Pass a RAW fixture}"
