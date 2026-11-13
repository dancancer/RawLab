#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-camera-originals.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -whole-module-optimization -module-cache-path "$OUT/modules" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraProtocol.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraIncrementalImport.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraJPEGProcessing.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraOriginalStore.swift" \
    "$ROOT/RawLab/tests/CameraOriginalStoreTests.swift" -o "$OUT/tests"
"$OUT/tests"
bash "$ROOT/RawLab/tests/camera-skip-and-limit.sh"
