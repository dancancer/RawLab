#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-camera-protocol
rawlab_ios_host_swiftc -whole-module-optimization -module-cache-path "$OUT/modules" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraProtocol.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraPTPClient.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraNetwork.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/SonyCameraSession.swift" \
    "$ROOT/RawLab/tests/CameraProtocolTests.swift" -o "$OUT/tests"
"$OUT/tests"
