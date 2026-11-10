#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-camera-protocol.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -whole-module-optimization -module-cache-path "$OUT/modules" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraProtocol.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraPTPClient.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraNetwork.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/SonyCameraSession.swift" \
    "$ROOT/RawLab/tests/CameraProtocolTests.swift" -o "$OUT/tests"
"$OUT/tests"
