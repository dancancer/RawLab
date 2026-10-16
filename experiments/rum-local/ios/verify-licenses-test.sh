#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT/experiments/rum-local/ios/verify-licenses.sh"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-licenses.XXXXXX")"
trap 'rm -r "$OUT"' EXIT

populate() {
    mkdir -p "$1"
    cp "$ROOT/LICENSE" "$1/RawLab-GPL-3.0.txt"
    cp "$ROOT/LICENSE-ALIYUN-RUM-EXCEPTION" "$1/RawLab-Aliyun-RUM-Exception.txt"
    cp "$ROOT/docs/licensing.md" "$1/RawLab-Licensing.md"
}

expect_rejection() {
    if bash "$CHECK" "$1" > "$OUT/rejection.log" 2>&1; then
        echo "FAIL: accepted missing or stale license content" >&2
        exit 1
    fi
}

APP="$OUT/RawLab.app"
LICENSES="$APP/Frameworks/sony2fuji.framework/Licenses"
populate "$LICENSES"
bash "$CHECK" "$APP"
rm "$LICENSES/RawLab-Aliyun-RUM-Exception.txt"
expect_rejection "$APP"
populate "$LICENSES"
cp "$ROOT/LICENSE" "$LICENSES/RawLab-Aliyun-RUM-Exception.txt"
expect_rejection "$APP"
populate "$LICENSES"
cp "$ROOT/LICENSE" "$LICENSES/RawLab-Licensing.md"
expect_rejection "$APP"

FRAMEWORK="$OUT/sony2fuji.xcframework"
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    populate "$FRAMEWORK/$slice/sony2fuji.framework/Licenses"
done
bash "$CHECK" "$FRAMEWORK"
rm "$FRAMEWORK/ios-arm64/sony2fuji.framework/Licenses/RawLab-GPL-3.0.txt"
expect_rejection "$FRAMEWORK"
echo 'PASS: iOS app/framework license checks reject missing and stale notices'
