#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-update-install.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -whole-module-optimization -swift-version 5 -sdk "$SDK" "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/tests/UpdateStateTests.swift" -o "$OUT/state"
"$OUT/state"
swiftc -whole-module-optimization -swift-version 5 -sdk "$SDK" "$ROOT/RawLabMac/Sources/System/Updates/UpdateInstallGate.swift" \
    "$ROOT/RawLabMac/tests/UpdateInstallGateTests.swift" -o "$OUT/gate"
"$OUT/gate"
swiftc -whole-module-optimization -swift-version 5 -sdk "$SDK" "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateStore.swift" \
    "$ROOT/RawLabMac/tests/UpdateStoreTests.swift" -o "$OUT/store"
"$OUT/store"
swiftc -whole-module-optimization -swift-version 5 -sdk "$SDK" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/HSLSettings.swift" \
    "$ROOT/Shared/AdjustmentTransfer.swift" "$ROOT/Shared/AdjustmentPresetStore.swift" \
    "$ROOT/Shared/DCPCompiler.swift" "$ROOT/Shared/LookLibrary.swift" \
    "$ROOT/RawLabMac/Sources/System/UpdateRelease.swift" "$ROOT/RawLabMac/Sources/System/UpdateChecker.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateStore.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateInstallGate.swift" "$ROOT/RawLabMac/Sources/System/Updates/DesktopUpdateController.swift" \
    "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Updates.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/SoftwareUpdateView.swift" \
    "$ROOT/RawLabMac/tests/DesktopUpdateControllerTests.swift" \
    -framework SwiftUI -framework AppKit -o "$OUT/controller"
"$OUT/controller"

swiftc -whole-module-optimization -swift-version 5 -sdk "$SDK" "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/MacUpdateTrust.swift" \
    "$ROOT/RawLabMac/tests/MacUpdateTrustTests.swift" -o "$OUT/trust"
"$OUT/trust"
