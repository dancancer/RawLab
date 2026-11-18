#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
OUT="$(mktemp -d /tmp/rawlab-ios-presentation.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
rawlabkit_flags link "$OUT/swiftpm" macos 0
swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -whole-module-optimization -swift-version 5 -sdk "$SDK" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/AdjustmentKind.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/FilmPresentation.swift" \
    "$ROOT/RawLab/tests/EditorPresentationTests.swift" \
    -o "$OUT/presentation"
"$OUT/presentation"

bash "$ROOT/RawLab/tests/viewing-state.sh"
