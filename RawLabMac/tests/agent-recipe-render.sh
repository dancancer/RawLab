#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
INPUT="${1:?Pass a real RAW fixture}"
CLI="${2:?Pass the sony2fuji CLI executable}"
LENS_DATABASE="${3:-$ROOT/lutools/tests/fixtures/lenses.xml}"
LENS_RAW="${4:-$ROOT/lutools/tests/fixtures/linear-lens.dng}"
MODE="${5:-}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d /tmp/rawlab-agent-recipe.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -sdk "$SDK" \
  "$ROOT/Shared/BundledLook.swift" \
  -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
  -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
  "$ROOT/RawLabMac/Sources/Rendering/Engine.swift" "$ROOT/RawLabMac/Sources/Looks/Film.swift" "$ROOT/RawLabMac/Sources/Rendering/AgentRecipe.swift" \
  "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLabMac/Sources/Adjustments/Adjustments.swift" "$ROOT/RawLabMac/Sources/Adjustments/AdjustmentTypes.swift" \
  "$ROOT/RawLabMac/Sources/Looks/MasterRecipe.swift" "$ROOT/Shared/HSLSettings.swift" \
  "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" \
  "$ROOT/RawLabMac/Sources/Editor/Storage/EditPersistence.swift" "$ROOT/RawLabMac/Sources/Export/BatchExport.swift" \
  "$ROOT/RawLabMac/tests/AgentRecipeRenderTests.swift" \
  "$ROOT/lutools/build-macos/libsony2fuji_core.a" \
  -L "$(pkg-config --variable=libdir libraw)" \
  -lraw $(pkg-config --libs opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) -lc++ -lz \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal \
  -o "$OUT/agent-recipe-render"

ARGS=("$INPUT" "$CLI")
if [ -n "$MODE" ]; then ARGS+=("$MODE"); fi
RAWLAB_TEST_ROOT="$ROOT" RAWLAB_LENS_DATABASE="$LENS_DATABASE" RAWLAB_LENS_RAW="$LENS_RAW" \
  "$OUT/agent-recipe-render" "${ARGS[@]}"
