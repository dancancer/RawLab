#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-camera-skip-limit.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

ln -s "$ROOT/RawLab/RawLab/Resources/zh-Hans.lproj" "$OUT/zh-Hans.lproj"
ln -s "$ROOT/RawLab/RawLab/Resources/en.lproj" "$OUT/en.lproj"

swiftc -swift-version 5 -whole-module-optimization -module-cache-path "$OUT/modules" \
    "$ROOT/Shared/Localization.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraProtocol.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraPTPClient.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraNetwork.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/SonyCameraSession.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraIncrementalImport.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraJPEGProcessing.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraOriginalStore.swift" \
    "$ROOT/RawLab/RawLab/Core/Camera/CameraWorkspaceBackend.swift" \
    "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraController.swift" \
    "$ROOT/RawLab/tests/CameraSkipAndLimitTests.swift" \
    -o "$OUT/tests"

mkdir -p "$OUT/profile"
CFFIXED_USER_HOME="$OUT/profile" "$OUT/tests"

if SIM_SDK="$(env -u SDKROOT xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)" && [[ -n "$SIM_SDK" ]]; then
    swiftc -typecheck -swift-version 5 -sdk "$SIM_SDK" -target arm64-apple-ios18.0-simulator \
        -module-cache-path "$OUT/sim-modules" \
        "$ROOT/Shared/Localization.swift" \
        "$ROOT/RawLab/RawLab/Core/Models/ExportSize.swift" \
        "$ROOT/RawLab/RawLab/UI/Export/ExportSizePicker.swift" \
        "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" \
        "$ROOT/RawLab/RawLab/Core/Camera/CameraProtocol.swift" \
        "$ROOT/RawLab/RawLab/Core/Camera/CameraPTPClient.swift" \
        "$ROOT/RawLab/RawLab/Core/Camera/CameraNetwork.swift" \
        "$ROOT/RawLab/RawLab/Core/Camera/SonyCameraSession.swift" \
        "$ROOT/RawLab/RawLab/Core/Camera/CameraIncrementalImport.swift" \
        "$ROOT/RawLab/RawLab/Core/Camera/CameraJPEGProcessing.swift" \
        "$ROOT/RawLab/RawLab/Core/Camera/CameraOriginalStore.swift" \
        "$ROOT/RawLab/RawLab/Core/Camera/CameraWorkspaceBackend.swift" \
        "$ROOT/RawLab/RawLab/Core/Camera/IOSCameraConnection.swift" \
        "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraController.swift" \
        "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraIncrementalImport.swift" \
        "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraBrowser.swift" \
        "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraTether.swift" \
        "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraWorkspace.swift" \
        "$ROOT/RawLab/tests/CameraSkipAndLimitTests.swift"
    echo "PASS: iOS Simulator SDK typecheck for Camera Core + UI"
fi
