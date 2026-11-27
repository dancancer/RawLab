#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
unset SDKROOT || true
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
rawlab_ios_make_temp_dir OUT rawlab-ios-hdr-canvas
mkdir -p "$OUT/HDRCanvasTests.app"
python3 - "$OUT/HDRCanvasTests.app" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
plistlib.dump({
    'CFBundleExecutable': 'hdr-canvas-tests',
    'CFBundleIdentifier': 'com.rawlab.tests.hdr-canvas',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'MinimumOSVersion': '18.0',
}, (app / 'Info.plist').open('wb'))
PY
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/Shared/Native/HDRCanvas.swift" \
    "$ROOT/Shared/tests/HDRDisplayGoldens.swift" \
    "$ROOT/RawLab/tests/HDRCanvasTests.swift" \
    -framework SwiftUI -framework UIKit -framework Metal -framework MetalKit -framework Combine \
    -o "$OUT/HDRCanvasTests.app/hdr-canvas-tests"
codesign --force --sign - "$OUT/HDRCanvasTests.app" >/dev/null
echo "PASS: iOS HDRCanvasTests compiled and linked for iphonesimulator"

DEVICE="${1:-${RAWLAB_SIMULATOR_UDID:-}}"
if [[ -z "$DEVICE" ]]; then
    DEVICE="$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin).get("devices",{}); print(next((x["udid"] for r in d.values() for x in r if x.get("state")=="Booted"), ""))' || true)"
fi
if [[ -n "$DEVICE" ]]; then
    xcrun simctl spawn "$DEVICE" "$OUT/HDRCanvasTests.app/hdr-canvas-tests"
fi
