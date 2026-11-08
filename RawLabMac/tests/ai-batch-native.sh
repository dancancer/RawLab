#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUT="$(mktemp -d "${RAWLAB_TEST_TMP_DIR:-${TMPDIR:-/tmp}}/rawlab-ai-batch.XXXXXX")"
MODEL="${1:?Complete AI model package is required}"
RAW="${2:?RAW input is required}"
APP="$OUT/RawLab.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/AI" "$OUT/home"
ln -s "$MODEL" "$APP/Contents/Resources/AI/DualDn"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.rawlab.tests.ai-batch</string><key>CFBundleExecutable</key><string>test</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' > "$APP/Contents/Info.plist"
trap 'rm -rf "$OUT"' EXIT
SOURCES=()
while IFS= read -r -d '' source; do
    case "$source" in */RawLabMacApp.swift) ;; *) SOURCES+=("$source") ;; esac
done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
swiftc -swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
    "${SOURCES[@]}" "$ROOT"/Shared/*.swift "$ROOT"/Shared/Native/*.swift "$ROOT/RawLabMac/tests/AIBatchNativeTests.swift" \
    "${CORE_LINK[@]}" \
    $(pkg-config --libs libraw rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4) -lc++ -lz \
    -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal -o "$APP/Contents/MacOS/test"
CFFIXED_USER_HOME="$OUT/home" "$APP/Contents/MacOS/test" "$RAW" "$OUT" "${3:-$OUT}"
