#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
DEVICE="${1:?Dedicated simulator UUID}"
OUT="${2:?New output directory}"
mkdir -p "$OUT/ViewingCanvas.app" "$OUT/cpps"
OUT="$(cd "$OUT" && pwd)"
python3 - "$OUT/ViewingCanvas.app" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]);plistlib.dump({'CFBundleExecutable':'viewing-canvas','CFBundleIdentifier':'com.rawlab.tests.viewing-canvas','CFBundlePackageType':'APPL','CFBundleVersion':'1','MinimumOSVersion':'18.0'},(app/'Info.plist').open('wb'))
PY
for source in core/photo_geometry core/inspection_overlay ffi/inspection_c; do
    xcrun --sdk iphonesimulator clang++ -std=c++17 -O2 \
        -target "$RAWLAB_IOS_SIM_TARGET" -isysroot "$RAWLAB_IOS_SIM_SDK" \
        -I "$ROOT/lutools/include" -I "$ROOT/lutools/src" \
        -c "$ROOT/lutools/src/$source.cpp" -o "$OUT/cpps/$(basename "$source").o"
done
rawlabnative_flags link "$OUT/swiftpm" iphonesimulator 0 inspection
rawlab_ios_sim_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -DRAWLAB_INSPECTION_NATIVE_ONLY -module-cache-path "$OUT/module-cache" \
    "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" \
    "$ROOT/RawLab/RawLab/UI/Preview/ZoomablePhoto.swift" \
    "$ROOT/RawLab/RawLab/UI/Preview/PhotoHSLTargetInput.swift" \
    "$ROOT/Shared/Native/HDRCanvas.swift" \
    "$ROOT/RawLab/tests/ViewingCanvasTests.swift" \
    "$OUT"/cpps/*.o -lc++ \
    -o "$OUT/ViewingCanvas.app/viewing-canvas"
codesign --force --sign - "$OUT/ViewingCanvas.app" >/dev/null
xcrun simctl spawn "$DEVICE" "$OUT/ViewingCanvas.app/viewing-canvas"
