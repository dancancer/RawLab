#!/bin/bash
set -euo pipefail
case "${1:-}" in
    ''|--models-only) ;;
    *) echo "Usage: $0 [--models-only]" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_make_temp_dir OUT rawlab-presentation
rawlab_mac_compile_native render-engine "$OUT/swiftpm" "$OUT/presentation" -- \
    -O "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/MacPhotoViewport.swift" \
    "$ROOT/RawLabMac/Sources/Library/FilmArtwork.swift" \
    "$ROOT/RawLabMac/Sources/Editor/View/AdjustmentPanelLayout.swift" \
    "$ROOT/RawLabMac/tests/PresentationTests.swift"
"$OUT/presentation" "${RAWLAB_FILM_ASSETS:-$ROOT/RawLabMac/Resources/FilmIcons}"

bash "$ROOT/RawLabMac/tests/mac-viewing.sh"
if [[ "${1:-}" != --models-only ]]; then
    bash "$ROOT/RawLabMac/tests/mac-canvas-input.sh"
fi
