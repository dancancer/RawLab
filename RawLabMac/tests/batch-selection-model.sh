#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
source "$ROOT/Shared/tests/hdr-native-sources.sh"
source "$ROOT/RawLabMac/tests/native-env.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d "${RAWLAB_TEST_TMP_DIR:-${TMPDIR:-/tmp}}/rawlab-adjustment-history.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
SOURCES=("$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift" "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift" "$ROOT/Shared/Native/ProcessingMigrationNative.swift" "${HDR_SWIFT_SOURCES[@]}" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/HSLTargetNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" "$ROOT/RawLabMac/Sources/Export/BatchSelection.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+BatchSelection.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+ProcessingMigration.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+HDR.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Geometry.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Rendering.swift" "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+HSLTarget.swift" "$ROOT/Shared/DCPCompiler.swift" "$ROOT/Shared/LookLibrary.swift" "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" "$ROOT/RawLabMac/Sources/Looks/LUTCompatibilityDialog.swift" "$ROOT/Shared/LUTCompatibilityView.swift" "$ROOT/Shared/LUTCompatibilityPreview.swift" "$ROOT/RawLabMac/Sources/Library/FileBrowser.swift")
if [ -f "$ROOT/RawLabMac/Sources/Export/BatchExportModel.swift" ]; then SOURCES+=("$ROOT/RawLabMac/Sources/Export/BatchExportModel.swift"); fi
SOURCES+=("$ROOT/RawLabMac/Sources/Export/ExportSizePicker.swift" "$ROOT/RawLabMac/Sources/Presentation/MacNeutralReference.swift")
SOURCES+=("$ROOT/RawLabMac/Sources/Lens/MacStraightenPreview.swift")
SOURCES+=("$ROOT/RawLabMac/Sources/Geometry/MacCropInteraction.swift")
SOURCES+=("$ROOT/RawLabMac/Sources/Inputs/ParameterValueField.swift")
TRANSFER_SOURCES=(
  "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransfer.swift"
  "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift"
  "$ROOT/RawLabMac/Sources/Adjustments/MacAdjustmentTransferWB.swift"
  "$ROOT/RawLabMac/Sources/Editor/Storage/AdjustmentTransferSession.swift"
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentHistory.swift"
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentTransfer.swift"
  "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentPresets.swift"
)
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" "${TRANSFER_SOURCES[@]}" -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
  "${SOURCES[@]}" "$ROOT/Shared/tests/HDRSourceProbeTests.swift" "$ROOT/RawLabMac/tests/BatchSelectionModelTests.swift" "$ROOT/RawLabMac/tests/BatchFlowModelTests.swift" \
  "${CORE_LINK[@]}" -L "$(pkg-config --variable=libdir libraw_r)" \
  -lraw_r $(pkg-config --libs opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
cd "$ROOT"
TMPDIR="$OUT" "$OUT/test" "$@"
