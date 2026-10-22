#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="${1:?Dedicated simulator UUID}"
OUT="${2:?New output directory}"
mkdir -p "$OUT/ViewingCanvas.app"
OUT="$(cd "$OUT" && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
python3 - "$OUT/ViewingCanvas.app" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]);plistlib.dump({'CFBundleExecutable':'viewing-canvas','CFBundleIdentifier':'com.rawlab.tests.viewing-canvas','CFBundlePackageType':'APPL','CFBundleVersion':'1','MinimumOSVersion':'18.0'},(app/'Info.plist').open('wb'))
PY
xcrun --sdk iphonesimulator swiftc -sdk "$SDK" -target arm64-apple-ios18.0-simulator -module-cache-path "$OUT/module-cache" "$ROOT/Shared/Localization.swift" "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" "$ROOT/RawLab/RawLab/UI/Preview/ZoomablePhoto.swift" "$ROOT/RawLab/tests/ViewingCanvasTests.swift" -o "$OUT/ViewingCanvas.app/viewing-canvas"
codesign --force --sign - "$OUT/ViewingCanvas.app" >/dev/null
xcrun simctl spawn "$DEVICE" "$OUT/ViewingCanvas.app/viewing-canvas"
