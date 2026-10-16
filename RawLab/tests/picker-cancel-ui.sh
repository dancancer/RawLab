#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the dedicated simulator UDID}"
ORIGINAL_XCTESTRUN="${3:?Pass the original build-for-testing .xctestrun path}"
OUT="${4:?Pass a new output directory for the harness and results}"
CASE="${5:-}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
GENERATED_XCTESTRUN="$OUT/picker-cancel.xctestrun"

bash "$ROOT/RawLab/tests/picker-cancel-harness.sh" "$APP" "$DEVICE" "$OUT/harness" \
    > "$OUT/harness-build.log" 2>&1

python3 - "$ORIGINAL_XCTESTRUN" "$GENERATED_XCTESTRUN" <<'PY'
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
    raise SystemExit("Expected a version-1 xctestrun with RawLabUITests; no tests requested.")
for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
    target.setdefault(key, {})["RAWLAB_PICKER_CANCEL_HARNESS"] = "1"
with destination.open("wb") as output:
    plistlib.dump(configuration, output)
PY

TEST_SCOPE="RawLabUITests/PickerAcquisitionCancelUITests"
if [[ -n "$CASE" ]]; then TEST_SCOPE="$TEST_SCOPE/$CASE"; fi
if xcodebuild -xctestrun "$GENERATED_XCTESTRUN" \
    -destination "platform=iOS Simulator,id=$DEVICE" -parallel-testing-enabled NO \
    -only-testing:"$TEST_SCOPE" -collect-test-diagnostics never \
    -resultBundlePath "$OUT/picker-cancel-ui.xcresult" test-without-building \
    > "$OUT/picker-cancel-ui.log" 2>&1; then
    PICKER_UI_STATUS=0
else
    PICKER_UI_STATUS=$?
fi
echo "Harness source/build evidence: $OUT/harness"
echo "UI test log: $OUT/picker-cancel-ui.log"
echo "UI test result: $OUT/picker-cancel-ui.xcresult"
exit "$PICKER_UI_STATUS"
