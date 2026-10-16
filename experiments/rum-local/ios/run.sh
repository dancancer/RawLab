#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MODE="${1:---build}"
if [[ "$MODE" != "--build" && "$MODE" != "--probe" ]]; then
    echo "Usage: bash experiments/rum-local/ios/run.sh [--build|--probe]" >&2
    exit 2
fi

if [[ "$MODE" == "--probe" ]]; then
    [[ "${RAWLAB_RUM_VALIDATE:-}" == "1" ]] || {
        echo "RAWLAB_RUM_VALIDATE=1 is required for the synthetic iOS probe." >&2
        exit 2
    }
    [[ -n "${RAWLAB_RUM_VALIDATION_RUN:-}" ]] || {
        echo "RAWLAB_RUM_VALIDATION_RUN must be an explicit UUID for the synthetic iOS probe." >&2
        exit 2
    }
    [[ "${RAWLAB_RUM_LIMIT_VERIFIED:-}" == "1" ]] || {
        echo "RAWLAB_RUM_LIMIT_VERIFIED=1 is required after the operator verifies the cloud daily limit." >&2
        exit 2
    }
    [[ "${RAWLAB_RUM_NETWORK:-}" == "china-telecom" ]] || {
        echo "RAWLAB_RUM_NETWORK=china-telecom is required for the confirmed direct route." >&2
        exit 2
    }
    [[ "${RAWLAB_RUM_CONFIG_VERIFIED:-}" == "1" ]] || {
        echo "RAWLAB_RUM_CONFIG_VERIFIED=1 is required after the operator verifies the Shanghai mobile app configuration." >&2
        exit 2
    }
    SYSTEM_PROXY="$(/usr/sbin/scutil --proxy 2>/dev/null || true)"
    if /usr/bin/grep -Eq '(HTTPEnable|HTTPSEnable|SOCKSEnable|ProxyAutoConfigEnable|ProxyAutoDiscoveryEnable) : 1' <<< "$SYSTEM_PROXY"; then
        echo "Refusing iOS probe with an enabled host system proxy." >&2
        exit 2
    fi
    for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
        if [[ -n "${!name:-}" ]]; then
            echo "Refusing iOS probe with proxy environment variable $name." >&2
            exit 2
        fi
    done
fi

PROBE_LOG_DIR="${RAWLAB_RUM_PROBE_LOG_DIR:-$ROOT/.cache/tmp/rum-local}"
PROBE_STDOUT="$PROBE_LOG_DIR/ios-probe-stdout.log"
PROBE_STDERR="$PROBE_LOG_DIR/ios-probe-stderr.log"
if [[ "$MODE" == "--probe" ]]; then
    mkdir -p "$PROBE_LOG_DIR"
    : > "$PROBE_STDOUT"
    : > "$PROBE_STDERR"
fi

OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-rum-local.XXXXXX")"
SDK_OUT="$ROOT/.cache/shared/aliyun-rum/ios/2.4.2/build/local"
SIMULATOR_UDID=""
SIMULATOR_BOOTED_BY_PROBE=0
cleanup() {
    local status=$?
    if [[ -n "$SIMULATOR_UDID" ]]; then
        xcrun simctl terminate "$SIMULATOR_UDID" com.example.RawLab.rumlocal 2>/dev/null || true
        xcrun simctl uninstall "$SIMULATOR_UDID" com.example.RawLab.rumlocal 2>/dev/null || true
        if [[ "$SIMULATOR_BOOTED_BY_PROBE" == "1" ]]; then
            xcrun simctl shutdown "$SIMULATOR_UDID" 2>/dev/null || true
        fi
    fi
    if ! rm -rf "$OUT"; then
        echo "CLEANUP FAILED: inspect temporary directory $OUT" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT

bash "$ROOT/experiments/rum-pilot/prepare-ios.sh" "$SDK_OUT"
DERIVED_DATA="$OUT/DerivedData"
SIM_SLICE="$SDK_OUT/AlibabaCloudRUM.xcframework/ios-arm64_x86_64-simulator"
CORE_SLICE="$SDK_OUT/AlibabaCloudRUMSDK.xcframework/ios-arm64_x86_64-simulator"

xcodebuild \
    -project "$ROOT/RawLab/RawLab.xcodeproj" \
    -scheme RawLab \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA" \
    -sdk iphonesimulator \
    PRODUCT_BUNDLE_IDENTIFIER=com.example.RawLab.rumlocal \
    PRODUCT_NAME=RawLabRumLocal \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG RAWLAB_RUM_LOCAL' \
    OTHER_SWIFT_FLAGS='$(inherited) -D RAWLAB_RUM_LOCAL' \
    FRAMEWORK_SEARCH_PATHS='$(inherited) '"$SIM_SLICE $CORE_SLICE" \
    OTHER_LDFLAGS='$(inherited) -ObjC -framework AlibabaCloudRUM -framework AlibabaCloudRUMSDK' \
    CODE_SIGNING_ALLOWED=NO

APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/RawLabRumLocal.app"
[[ -d "$APP" ]] || { echo "local iOS app was not built: $APP" >&2; exit 1; }
mkdir -p "$APP/Frameworks"
cp -R "$CORE_SLICE/AlibabaCloudRUMSDK.framework" "$APP/Frameworks/"
codesign --force --sign - --timestamp=none "$APP/Frameworks/AlibabaCloudRUMSDK.framework"
codesign --force --sign - --timestamp=none "$APP"
printf 'PASS: RawLabRumLocal Debug simulator app built with -D RAWLAB_RUM_LOCAL and iOS SDK 2.4.2\n'

if [[ "$MODE" == "--probe" ]]; then
    SERVICE_ID="${RAWLAB_RUM_SERVICE_ID:-chrtja4hrt@fbde0daa498a0e32c909f}"
    ENDPOINT="${RAWLAB_RUM_ENDPOINT:-https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com}"
    WORKSPACE="${RAWLAB_RUM_WORKSPACE:-default-cms-1268858473429241-cn-shanghai}"
    SIMULATOR_UDID="${RAWLAB_IOS_SIMULATOR_UDID:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')}"
    [[ -n "$SIMULATOR_UDID" ]] || { echo "No available iPhone simulator found." >&2; exit 2; }
    STATE="$(xcrun simctl list devices | awk -F '[()]' -v id="$SIMULATOR_UDID" '$2 == id { print $3 }')"
    if [[ "$STATE" != *Booted* ]]; then
        if xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null; then
            SIMULATOR_BOOTED_BY_PROBE=1
        fi
        xcrun simctl bootstatus "$SIMULATOR_UDID" -b
    fi
    xcrun simctl install "$SIMULATOR_UDID" "$APP"
    SIMCTL_CHILD_RAWLAB_RUM_VALIDATE=1 \
    SIMCTL_CHILD_RAWLAB_RUM_VALIDATION_RUN="$RAWLAB_RUM_VALIDATION_RUN" \
    SIMCTL_CHILD_RAWLAB_RUM_SERVICE_ID="$SERVICE_ID" \
    SIMCTL_CHILD_RAWLAB_RUM_ENDPOINT="$ENDPOINT" \
    SIMCTL_CHILD_RAWLAB_RUM_WORKSPACE="$WORKSPACE" \
        xcrun simctl launch \
            --stdout="$PROBE_STDOUT" \
            --stderr="$PROBE_STDERR" \
            "$SIMULATOR_UDID" com.example.RawLab.rumlocal
    sleep 35
    xcrun simctl terminate "$SIMULATOR_UDID" com.example.RawLab.rumlocal 2>/dev/null || true
    xcrun simctl uninstall "$SIMULATOR_UDID" com.example.RawLab.rumlocal 2>/dev/null || true
    if ! /usr/bin/grep -Fqx 'SUBMITTED: five synthetic iOS usage events through the local adapter; cloud readback required' "$PROBE_STDOUT"; then
        echo "PROBE FAILED: no successful SDK submission/stop status; inspect the private probe logs." >&2
        exit 1
    fi
    printf 'PROBE WINDOW COMPLETE: 35s bounded window for startup, five events and SDK stop; cloud readback required; stdout=%s stderr=%s\n' "$PROBE_STDOUT" "$PROBE_STDERR"
fi
