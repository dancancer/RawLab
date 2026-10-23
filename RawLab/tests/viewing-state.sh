#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-viewing-state.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for TEST in PhotoViewingTests PhotoZoomTests; do
    swiftc -sdk "$SDK" "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" "$ROOT/RawLab/tests/$TEST.swift" -o "$OUT/$TEST"
    "$OUT/$TEST"
done
