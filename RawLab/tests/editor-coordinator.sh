#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-editor-coordinator.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/RawLab/RawLab/UI/EditorState/EditorCoordinator.swift" \
    "$ROOT/RawLab/RawLab/Core/ViewModel/EditorResetTransaction.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/PhotoImportTypes.swift" \
    "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" \
    "$ROOT/RawLab/tests/EditorCoordinatorTests.swift" \
    -framework SwiftUI -framework PhotosUI -framework UniformTypeIdentifiers -o "$OUT/editor-coordinator-tests"
"$OUT/editor-coordinator-tests"
