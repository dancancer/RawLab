#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-camera-protocol
rawlab_ios_compile_sony_ptpip host "$OUT/ptpip"
rawlab_ios_host_swiftc -whole-module-optimization -module-cache-path "$OUT/modules" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraProtocol.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraPTPClient.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraNetwork.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraAccessAuth.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/SonyCameraSession.swift" \
    "$ROOT/RawLab/tests/CameraProtocolTests.swift" \
    "$OUT/ptpip"/*.o -lc++ -o "$OUT/tests"
"$OUT/tests"
rawlab_ios_host_swiftc -whole-module-optimization -module-cache-path "$OUT/modules" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraProtocol.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraFocusController.swift" \
    "$ROOT/RawLab/tests/CameraFocusControllerTests.swift" \
    "$OUT/ptpip"/*.o -lc++ -o "$OUT/focus-tests"
"$OUT/focus-tests"

SSH_SCRATCH="$OUT/camera-ssh"
if [[ -n "${RAWLAB_CI_SWIFTPM_CACHE:-}" ]]; then
    _ci_cache="$RAWLAB_CI_SWIFTPM_CACHE"
    [[ "$_ci_cache" == /* ]] || _ci_cache="$ROOT/$_ci_cache"
    SSH_SCRATCH="$_ci_cache/camera-ssh"
fi
swift test --package-path "$ROOT/RawLab/Packages/RawLabCameraSSH" --scratch-path "$SSH_SCRATCH"
