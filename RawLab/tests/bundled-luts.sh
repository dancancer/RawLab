#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:-booted}"
rawlab_ios_make_temp_dir OUT rawlab-bundled-luts
xcrun --sdk iphonesimulator clang -target "$RAWLAB_IOS_SIM_TARGET" -isysroot "$RAWLAB_IOS_SIM_SDK" \
    -I "$ROOT/lutools/include" -F "$APP/Frameworks" -framework sony2fuji \
    -Wl,-rpath,"$APP/Frameworks" "$ROOT/RawLab/tests/BundledLUTTests.c" -o "$OUT/luts"
xcrun simctl spawn "$DEVICE" "$OUT/luts" "$APP"/*.cube "$APP"/BundledLooks/*.cube
