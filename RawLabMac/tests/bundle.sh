#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:-$ROOT/build/RawLab Mac.app}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
    minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
    test "$minimum" = "$MACOSX_DEPLOYMENT_TARGET" || {
        echo "FAIL: app minimum macOS is $minimum, expected $MACOSX_DEPLOYMENT_TARGET"; exit 1;
    }
fi
for binary in "$APP/Contents/MacOS/RawLabMac" "$APP"/Contents/Frameworks/*.dylib; do
    if [ -n "${RAWLAB_ARCH:-}" ]; then
        test "$(lipo -archs "$binary")" = "$RAWLAB_ARCH" || {
            echo "FAIL: unexpected architecture in $binary"; exit 1;
        }
    fi
    if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
        minimum=$(xcrun vtool -show-build "$binary" | awk '$1 == "minos" { print $2 }')
        awk -v actual="$minimum" -v target="$MACOSX_DEPLOYMENT_TARGET" 'BEGIN {
            if (actual == "") exit 1;
            split(actual, a, "."); split(target, t, ".");
            for (i = 1; i <= 3; i++) {
                if (a[i] + 0 < t[i] + 0) exit 0;
                if (a[i] + 0 > t[i] + 0) exit 1;
            }
        }' || { echo "FAIL: $binary requires macOS $minimum, expected <= $MACOSX_DEPLOYMENT_TARGET"; exit 1; }
    fi
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/*|/usr/lib/*) ;;
            @rpath/*)
                test -f "$APP/Contents/Frameworks/${dependency#@rpath/}" || {
                    echo "FAIL: missing bundled dependency $dependency"; exit 1;
                }
                ;;
            *) echo "FAIL: external dependency $dependency in $binary"; exit 1 ;;
        esac
    done < <(otool -L "$binary" | awk 'NR>1 {print $1}')
    codesign --verify --strict "$binary"
done
codesign --verify --deep --strict "$APP"
echo 'PASS: all non-system dynamic dependencies are bundled and signed'
