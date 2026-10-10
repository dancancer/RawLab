#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
OUT="$(mktemp -d /tmp/rawlab-ai-workflow.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
SOURCES=()
for source in "$ROOT"/RawLabMac/Sources/*.swift; do
    case "$source" in */RawLabMacApp.swift) continue ;; esac
    SOURCES+=("$source")
done
swiftc -parse-as-library -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "${SOURCES[@]}" "$ROOT/Shared/ExportMetadata.swift" "$ROOT/Shared/PhotoInformation.swift" \
    "$ROOT/RawLabMac/tests/AIWorkflowTests.swift" \
    "$ROOT/lutools/build-macos/libsony2fuji_core.a" -L "$(pkg-config --variable=libdir libraw)" \
    -lraw $(pkg-config --libs opencv4 wavelib) -lc++ -lz -framework SwiftUI -framework AppKit \
    -framework ImageIO -framework Metal -framework Security -o "$OUT/test"
if [ "${RAWLAB_AI_UI:-0}" = "1" ]; then
    APP="$OUT/RawLab AI Fixture.app"
    mkdir -p "$APP/Contents/MacOS"
    cp "$ROOT/RawLabMac/tests/AIWorkflowFixture.plist" "$APP/Contents/Info.plist"
    mv "$OUT/test" "$APP/Contents/MacOS/test"
    "$APP/Contents/MacOS/test" "$@"
else
    "$OUT/test" "$@"
fi
