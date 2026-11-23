#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir OUT rawlab-update-install
rawlab_mac_swiftc -whole-module-optimization "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/tests/UpdateStateTests.swift" -o "$OUT/state"
"$OUT/state"
rawlab_mac_swiftc -whole-module-optimization "$ROOT/RawLabMac/Sources/System/Updates/UpdateInstallGate.swift" \
    "$ROOT/RawLabMac/tests/UpdateInstallGateTests.swift" -o "$OUT/gate"
"$OUT/gate"
rawlab_mac_swiftc -whole-module-optimization "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateStore.swift" \
    "$ROOT/RawLabMac/tests/UpdateStoreTests.swift" -o "$OUT/store"
"$OUT/store"
rawlabnative_flags link "$OUT/swiftpm" macos 0 all
rawlab_mac_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -whole-module-optimization \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateStore.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateInstallGate.swift" "$ROOT/RawLabMac/Sources/System/Updates/DesktopUpdateController.swift" \
    "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Updates.swift" \
    "$ROOT/RawLabMac/Sources/Presentation/SoftwareUpdateView.swift" \
    "$ROOT/RawLabMac/tests/DesktopUpdateControllerTests.swift" \
    -framework SwiftUI -framework AppKit -o "$OUT/controller"
"$OUT/controller"

rawlab_mac_swiftc -whole-module-optimization "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/MacUpdateTrust.swift" \
    "$ROOT/RawLabMac/tests/MacUpdateTrustTests.swift" -o "$OUT/trust"
"$OUT/trust"
