#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-ios-presentation.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -sdk "$SDK" \
    "$ROOT/Shared/BundledLook.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/ToneControlsSettings.swift" "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/AdjustmentKind.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/FilmPresentation.swift" \
    "$ROOT/RawLab/tests/EditorPresentationTests.swift" \
    -o "$OUT/presentation"
"$OUT/presentation"

bash "$ROOT/RawLab/tests/viewing-state.sh"
