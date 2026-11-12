#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS_SIMULATOR_UDID:?Use the dedicated simulator UDID supplied for Sony incremental import}"
OUT="${RAWLAB_CAMERA_INCREMENTAL_OUTPUT:-$ROOT/.cache/tmp/sony-incremental-import-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

FIXTURE="$OUT/sony-incremental-fixture"
LOG="$OUT/responder.log"
READY="$OUT/responder.ready"
SCENARIO="${RAWLAB_CAMERA_INCREMENTAL_SCENARIO:-resume}"
FIXTURE_ARGS=(--log "$LOG" --ready "$READY")
case "$SCENARIO" in
    resume) TEST_CASE=testSonyIncrementalImportRequiresReselectionAfterInterruptedJPEG ;;
    dismiss)
        TEST_CASE=testSonyIncrementalDismissalSurvivesReconnect
        FIXTURE_ARGS+=(--interrupt-jpeg=false --jpeg-file "$ROOT/lutools/tests/fixtures/hdr/apple-legacy-macos26.jpg")
        ;;
    tether-swap)
        TEST_CASE=testSonyTetherReconnectRejectsReplacedOriginal
        FIXTURE_ARGS+=(--tether-scenario swap --interrupt-jpeg=false)
        ;;
    tether-missing)
        TEST_CASE=testSonyTetherUnavailableOriginalOffersManualImport
        FIXTURE_ARGS+=(--tether-scenario missing --interrupt-jpeg=false)
        ;;
    tether-empty)
        TEST_CASE=testSonyTetherWithoutRegisteredOriginalsHasNoResumeAction
        FIXTURE_ARGS+=(--tether-scenario empty --interrupt-jpeg=false)
        ;;
    *) printf 'Unknown Sony incremental test scenario: %s\n' "$SCENARIO" >&2; exit 2 ;;
esac
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
python3 - "$PRODUCTS" "$XCTESTRUN" "$SCENARIO" <<'PY'
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
    target["EnvironmentVariables"]["RAWLAB_SONY_INCREMENTAL_SCENARIO"] = sys.argv[3]
    # Keep the app flag explicit as well; the test sets it before launch, and
    # this makes the xctestrun self-describing for manual diagnostics.
    target.setdefault("UITargetAppEnvironmentVariables", {})["RAWLAB_CAMERA_LOOPBACK_FIXTURE"] = "1"
output.write_bytes(plistlib.dumps(config))
PY

"$FIXTURE" "${FIXTURE_ARGS[@]}" >"$OUT/responder.stdout.log" 2>"$OUT/responder.stderr.log" &
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
    -only-testing:"RawLabUITests/EditorV4UITests/$TEST_CASE" \
    >"$OUT/xcodebuild.log" 2>&1

xcrun xcresulttool get test-results summary --path "$OUT/SonyIncremental.xcresult" --format json >"$OUT/summary.json"
python3 - "$OUT/summary.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    summary = json.load(stream)
if summary.get("passedTests") != 1 or summary.get("skippedTests") != 0 or summary.get("failedTests") != 0:
    raise SystemExit(summary)
PY

if [[ "$SCENARIO" == resume ]]; then
    test "$(grep -c 'file=1 name=DSC10001.ARW' "$LOG")" -eq 1
    test "$(grep -c 'file=11 name=DSC10001.ARW' "$LOG")" -eq 1
    test "$(grep -c 'file=2 name=DSC10001.JPG' "$LOG")" -eq 1
    test "$(grep -c 'file=12 name=DSC10001.JPG' "$LOG")" -eq 1
elif [[ "$SCENARIO" == dismiss ]]; then
    test "$(grep -c 'name=DSC10001.JPG' "$LOG")" -eq 2
elif [[ "$SCENARIO" == tether-empty ]]; then
    grep -q 'op=0x923c' "$LOG"
    if grep -q 'op=0x923d' "$LOG"; then
        printf 'An empty tether session requested an original\n' >&2
        exit 1
    fi
else
    test "$(grep -c 'file=1 name=DSC10001.ARW' "$LOG")" -eq 2
    if grep -q 'name=DSC10001.JPG' "$LOG"; then
        printf 'Tether resume requested an unregistered file\n' >&2
        exit 1
    fi
    if [[ "$SCENARIO" == tether-missing ]]; then
        test "$(grep -c 'recovery original unavailable: response=0x2009' "$LOG")" -eq 1
    fi
fi
printf 'PASS: iOS Sony incremental %s scenario; artifacts: %s\n' "$SCENARIO" "$OUT"
