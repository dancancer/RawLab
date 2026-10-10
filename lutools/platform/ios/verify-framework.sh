#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FRAMEWORK="${1:-$ROOT/build-ios/sony2fuji.xcframework}"

for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    binary="$FRAMEWORK/$slice/sony2fuji.framework/sony2fuji"
    test -f "$binary"
    for marker in 0.22.2-Release GFX100RF 'EOS R6 Mark III'; do
        if ! strings "$binary" | grep -F "$marker" >/dev/null; then
            echo "FAIL: $slice is missing patched LibRaw marker: $marker" >&2
            exit 1
        fi
    done
    dependencies="$(otool -L "$binary")"
    if printf '%s\n' "$dependencies" | sed -n '/^[[:space:]]/p' | grep -Ev '(@rpath/sony2fuji.framework/sony2fuji|/usr/lib/|/System/Library/)' | grep .; then
        echo "FAIL: $slice has a non-system runtime dependency" >&2
        exit 1
    fi
    for notice in LibRaw-COPYRIGHT LibRaw-LICENSE.CDDL LibRaw-LICENSE.LGPL \
        rawspeed-camera-calibration.inc Adobe-DNG-SDK-LICENSE.txt stb-MIT-LICENSE.txt ThirdPartyNotices.md \
        RawLab-GPL-3.0.txt RawLab-Licensing.md; do
        test -f "$(dirname "$binary")/Licenses/$notice"
    done
done
lipo "$FRAMEWORK/ios-arm64/sony2fuji.framework/sony2fuji" -verify_arch arm64
for arch in arm64 x86_64; do
    lipo "$FRAMEWORK/ios-arm64_x86_64-simulator/sony2fuji.framework/sony2fuji" -verify_arch "$arch"
done
echo "PASS: patched LibRaw, device/simulator slices, licenses and runtime dependencies"
