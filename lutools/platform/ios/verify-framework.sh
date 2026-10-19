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
    test -f "$(dirname "$binary")/Lensfun/mil-sony.xml"
    lens_xml=("$(dirname "$binary")/Lensfun/"*.xml)
    if [ "$(find "$(dirname "$binary")/Lensfun" -type f -name '*.xml' | wc -l)" -ne "${#lens_xml[@]}" ]; then
        echo "FAIL: $slice Lensfun database must be a flat XML snapshot" >&2
        exit 1
    fi
    for notice in lgpl-3.0.txt database-CC-BY-SA-3.0.txt GLib-COPYING PCRE2-LICENCE proxy-libintl-COPYING; do
        test -f "$(dirname "$binary")/Licenses/lensfun/$notice"
    done
    nm -gU "$binary" | grep -F '_sony2fuji_session_set_lens_correction' >/dev/null
    dependencies="$(otool -L "$binary")"
    if printf '%s\n' "$dependencies" | sed -n '/^[[:space:]]/p' | grep -Ev '(@rpath/sony2fuji.framework/sony2fuji|/usr/lib/|/System/Library/)' | grep .; then
        echo "FAIL: $slice has a non-system runtime dependency" >&2
        exit 1
    fi
    for notice in LibRaw-COPYRIGHT LibRaw-LICENSE.CDDL LibRaw-LICENSE.LGPL \
        rawspeed-camera-calibration.inc Adobe-DNG-SDK-LICENSE.txt stb-MIT-LICENSE.txt nlohmann-JSON-MIT.txt libtiff-LICENSE.md ThirdPartyNotices.md \
        RawLab-GPL-3.0.txt RawLab-Aliyun-RUM-Exception.txt RawLab-Licensing.md; do
        test -f "$(dirname "$binary")/Licenses/$notice"
    done
    cmp "$ROOT/../LICENSE-ALIYUN-RUM-EXCEPTION" "$(dirname "$binary")/Licenses/RawLab-Aliyun-RUM-Exception.txt"
    cmp "$ROOT/third_party/nlohmann/LICENSE.MIT" "$(dirname "$binary")/Licenses/nlohmann-JSON-MIT.txt"
    for name in README.md LICENSE.LGPL-2.1; do
        cmp "$ROOT/third_party/nikon_he/$name" "$(dirname "$binary")/Licenses/nikon-he/$name"
    done
    nm -gU "$binary" | grep -F '_sony2fuji_compile_dcp' >/dev/null
    nm -gU "$binary" | grep -F '_sony2fuji_release_blob' >/dev/null
    dng_licenses="$(dirname "$binary")/Licenses/dng-sdk"
    test -d "$dng_licenses"
    for notice in Adobe-DNG-SDK-LICENSE.txt JPEG-XL-LICENSE.txt Brotli-LICENSE.txt \
        Highway-LICENSE.txt Highway-LICENSE-BSD3.txt skcms-LICENSE.txt; do
        test -f "$dng_licenses/$notice"
    done
done
lipo "$FRAMEWORK/ios-arm64/sony2fuji.framework/sony2fuji" -verify_arch arm64
for arch in arm64 x86_64; do
    lipo "$FRAMEWORK/ios-arm64_x86_64-simulator/sony2fuji.framework/sony2fuji" -verify_arch "$arch"
done
echo "PASS: patched LibRaw, device/simulator slices, licenses and runtime dependencies"
