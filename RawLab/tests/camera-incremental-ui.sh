#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS_SIMULATOR_UDID:?Use the dedicated simulator UDID supplied for Sony incremental import}"
OUT="${RAWLAB_CAMERA_INCREMENTAL_OUTPUT:-$ROOT/.cache/tmp/sony-incremental-import-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

FIXTURE="$OUT/sony-incremental-fixture"
LOG="$OUT/responder.log"
READY="$OUT/responder.ready"
go build -o "$FIXTURE" "$ROOT/RawLab/tests/sony-incremental-fixture.go"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="${RAWLAB_CAMERA_BUILD_PRODUCTS:-}"
if [[ -z "$PRODUCTS" ]]; then
    BUILD_ROOT="$OUT/Build"
    xcodebuild -project "$ROOT/RawLab/RawLab.xcodeproj" -scheme RawLab -configuration Debug \
        -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$BUILD_ROOT" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build-for-testing \
        >"$OUT/build-for-testing.log" 2>&1
    PRODUCTS="$BUILD_ROOT/Build/Products"
fi

XCTESTRUN="$OUT/sony-incremental.xctestrun"
python3 - "$PRODUCTS" "$XCTESTRUN" <<'PY'
from pathlib import Path
import plistlib, sys

products = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2])
runs = list(products.glob("*.xctestrun"))
if len(runs) != 1:
    raise SystemExit(f"Expected one xctestrun in {products}, found {len(runs)}")

def resolve(value):
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(products))
    if isinstance(value, list):
        return [resolve(item) for item in value]
    if isinstance(value, dict):
        return {key: resolve(item) for key, item in value.items()}
    return value

config = resolve(plistlib.loads(runs[0].read_bytes()))
targets = [target for group in config.get("TestConfigurations", [])
           for target in group.get("TestTargets", [])]
if not targets:
    targets = [value for key, value in config.items()
               if not key.startswith("__") and isinstance(value, dict)]
if not targets:
    raise SystemExit("No test targets in xctestrun")
for target in targets:
    target.setdefault("EnvironmentVariables", {})["RAWLAB_SONY_INCREMENTAL_UI"] = "1"
    # Keep the app flag explicit as well; the test sets it before launch, and
    # this makes the xctestrun self-describing for manual diagnostics.
    target.setdefault("UITargetAppEnvironmentVariables", {})["RAWLAB_CAMERA_LOOPBACK_FIXTURE"] = "1"
output.write_bytes(plistlib.dumps(config))
PY

"$FIXTURE" --log "$LOG" --ready "$READY" >"$OUT/responder.stdout.log" 2>"$OUT/responder.stderr.log" &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 100); do
    if [[ -f "$READY" ]]; then break; fi
    sleep 0.05
done
test -f "$READY"

xcodebuild test-without-building -xctestrun "$XCTESTRUN" \
    -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
    -resultBundlePath "$OUT/SonyIncremental.xcresult" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:RawLabUITests/EditorV4UITests/testSonyIncrementalImportResumesOnlyPendingJPEG \
    >"$OUT/xcodebuild.log" 2>&1

xcrun xcresulttool get test-results summary --path "$OUT/SonyIncremental.xcresult" --format json >"$OUT/summary.json"
python3 - "$OUT/summary.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    summary = json.load(stream)
if summary.get("passedTests") != 1 or summary.get("skippedTests") != 0 or summary.get("failedTests") != 0:
    raise SystemExit(summary)
PY

test "$(grep -c 'file=1 name=DSC10001.ARW' "$LOG")" -eq 1
test "$(grep -c 'file=2 name=DSC10001.JPG' "$LOG")" -eq 2
printf 'PASS: iOS Sony incremental import resumed the pending JPEG; ARW request count=1, JPEG request count=2; artifacts: %s\n' "$OUT"
