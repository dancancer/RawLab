#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the dedicated simulator UDID}"
ORIGINAL_XCTESTRUN="${3:?Pass the original build-for-testing .xctestrun path}"
OUT="${4:?Pass a new output directory for harness, logs, and test results}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
GENERATED_XCTESTRUN="$OUT/crop-lock.xctestrun"

bash "$ROOT/RawLab/tests/crop-lock-harness.sh" "$APP" "$DEVICE" "$OUT/harness" \
    > "$OUT/harness-build.log" 2>&1

# A copied xctestrun must retain paths relative to its original build-products
# folder. Existing runner environment and other substitutions are preserved.
/usr/bin/python3 - "$ORIGINAL_XCTESTRUN" "$GENERATED_XCTESTRUN" <<'PY'
import pathlib
import plistlib
import sys

original = pathlib.Path(sys.argv[1]).resolve(strict=True)
destination = pathlib.Path(sys.argv[2])
with original.open("rb") as source:
    configuration = plistlib.load(source)

def relocate(value):
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(original.parent))
    if isinstance(value, dict):
        return {key: relocate(item) for key, item in value.items()}
    if isinstance(value, list):
        return [relocate(item) for item in value]
    return value

configuration = relocate(configuration)
target = configuration.get("RawLabUITests")
if not isinstance(target, dict):
    raise SystemExit("Expected version-1 xctestrun with a RawLabUITests target; no test run requested.")
for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
    environment = target.setdefault(key, {})
    if not isinstance(environment, dict):
        raise SystemExit(f"Unexpected {key} format; no test run requested.")
    environment["RAWLAB_CROP_LOCK_HARNESS"] = "1"
with destination.open("wb") as output:
    plistlib.dump(configuration, output)
PY

if xcodebuild -xctestrun "$GENERATED_XCTESTRUN" \
    -destination "platform=iOS Simulator,id=$DEVICE" \
    -only-testing:RawLabUITests/CropLockUITests \
    -parallel-testing-enabled NO -collect-test-diagnostics never \
    -resultBundlePath "$OUT/crop-lock-ui.xcresult" test-without-building \
    > "$OUT/crop-lock-ui.log" 2>&1; then
    CROP_UI_STATUS=0
else
    CROP_UI_STATUS=$?
fi
echo "Harness build log: $OUT/harness-build.log"
echo "UI test log: $OUT/crop-lock-ui.log"
echo "UI test results: $OUT/crop-lock-ui.xcresult"
exit "$CROP_UI_STATUS"
