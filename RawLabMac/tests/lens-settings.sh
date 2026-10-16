#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
mkdir -p "$ROOT/build/mac-tests"
swiftc "$ROOT/Shared/Localization.swift" -swift-version 5 -sdk "$SDK" -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/Shared/BundledLook.swift" \
    "$ROOT/RawLabMac/Sources/Adjustments.swift" "$ROOT/RawLabMac/Sources/MasterRecipe.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" "$ROOT/Shared/HSLNative.swift" "$ROOT/RawLabMac/Sources/Engine.swift" \
    "$ROOT/Shared/ExportMetadata.swift" "$ROOT/RawLabMac/tests/LensSettingsTests.swift" \
    "$ROOT/lutools/build-macos/libsony2fuji_core.a" $(pkg-config --libs libraw opencv4 wavelib rawlab-dng-sdk lensfun libtiff-4) \
    -lc++ -lz -framework AppKit -framework ImageIO -framework Metal -o "$ROOT/build/mac-tests/lens-settings"
"$ROOT/build/mac-tests/lens-settings"
