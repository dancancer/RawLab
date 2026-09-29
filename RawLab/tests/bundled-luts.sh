#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:-booted}"
OUT="$(mktemp -d /tmp/rawlab-bundled-luts.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
xcrun --sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator \
    -I "$ROOT/lutools/include" -F "$APP/Frameworks" -framework sony2fuji \
    -Wl,-rpath,"$APP/Frameworks" "$ROOT/RawLab/tests/BundledLUTTests.c" -o "$OUT/luts"
xcrun simctl spawn "$DEVICE" "$OUT/luts" "$APP"/*.cube
