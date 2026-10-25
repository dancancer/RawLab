#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/rawlab-update-install.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -swift-version 5 -sdk "$SDK" "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/tests/UpdateStateTests.swift" -o "$OUT/state"
"$OUT/state"
swiftc -swift-version 5 -sdk "$SDK" "$ROOT/RawLabMac/Sources/System/Updates/UpdateInstallGate.swift" \
    "$ROOT/RawLabMac/tests/UpdateInstallGateTests.swift" -o "$OUT/gate"
"$OUT/gate"
swiftc -swift-version 5 -sdk "$SDK" "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateStore.swift" \
    "$ROOT/RawLabMac/tests/UpdateStoreTests.swift" -o "$OUT/store"
"$OUT/store"
swiftc -swift-version 5 -sdk "$SDK" "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateStore.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateInstallGate.swift" "$ROOT/RawLabMac/Sources/System/Updates/DesktopUpdateController.swift" \
    "$ROOT/RawLabMac/tests/DesktopUpdateControllerTests.swift" -o "$OUT/controller"
"$OUT/controller"
