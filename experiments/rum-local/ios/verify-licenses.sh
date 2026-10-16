#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ARTIFACT="${1:?Pass a built .app or .xcframework path}"
ARTIFACT="${ARTIFACT%/}"

check_notices() {
    local directory="$1"
    cmp "$ROOT/LICENSE" "$directory/RawLab-GPL-3.0.txt"
    cmp "$ROOT/LICENSE-ALIYUN-RUM-EXCEPTION" "$directory/RawLab-Aliyun-RUM-Exception.txt"
    cmp "$ROOT/docs/licensing.md" "$directory/RawLab-Licensing.md"
}

case "$ARTIFACT" in
    *.app)
        check_notices "$ARTIFACT/Frameworks/sony2fuji.framework/Licenses"
        ;;
    *.xcframework)
        for slice in ios-arm64 ios-arm64_x86_64-simulator; do
            check_notices "$ARTIFACT/$slice/sony2fuji.framework/Licenses"
        done
        ;;
    *)
        echo 'Expected a built .app or .xcframework directory.' >&2
        exit 2
        ;;
esac
echo 'PASS: packaged GPL, RUM exception and licensing notice match current source'
