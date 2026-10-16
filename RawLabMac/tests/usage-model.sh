#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-usage-model.XXXXXX")"
trap 'rm -r "$OUT"' EXIT
swiftc -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
  "$ROOT/Shared/UsageAnalytics.swift" "$ROOT/Shared/ExportMetadata.swift" \
  "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" \
  "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" \
  "$ROOT/RawLabMac/Sources/Engine.swift" "$ROOT/RawLabMac/Sources/Adjustments.swift" \
  "$ROOT/RawLabMac/Sources/AgentRecipe.swift" \
  "$ROOT/RawLabMac/Sources/MasterRecipe.swift" "$ROOT/RawLabMac/Sources/MacStraightenPreview.swift" \
  "$ROOT/RawLabMac/Sources/MacCropInteraction.swift" \
  "$ROOT/RawLabMac/Sources/RenderScheduling.swift" "$ROOT/RawLabMac/Sources/EditPersistence.swift" \
  "$ROOT/RawLabMac/Sources/BatchExport.swift" "$ROOT/RawLabMac/Sources/BatchExportModel.swift" \
  "$ROOT/RawLabMac/Sources/FileLibrary.swift" "$ROOT/RawLabMac/Sources/LookLibrary.swift" \
  "$ROOT/RawLabMac/Sources/EditorModel.swift" "$ROOT/RawLabMac/Sources/ExportSizePicker.swift" \
  "$ROOT/RawLabMac/tests/UsageModelTests.swift" "$BUILD/libsony2fuji_core.a" \
  $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$OUT/test"
"$OUT/test" "$@"
