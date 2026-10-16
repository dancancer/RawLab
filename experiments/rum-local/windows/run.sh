#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SDK_ZIP="$ROOT/.cache/shared/aliyun-rum/windows/0.4.4/sdk.zip"
SDK_SHA256="bfa05c0718a57eb7e94c9494499bd3c84305a3cc39b76d6a9096667553928994"
DOTNET="$ROOT/build/tools/dotnet/dotnet"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-rum-windows.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

if [[ "${1:-}" != "--build" && "${1:-}" != "--send" ]]; then
    echo "usage: $0 --build|--send" >&2
    exit 2
fi
[[ -x "$DOTNET" ]] || { echo "bundled dotnet is missing: $DOTNET" >&2; exit 2; }
[[ -f "$SDK_ZIP" ]] || { echo "SDK cache is missing: $SDK_ZIP" >&2; exit 2; }
actual_sha256="$(shasum -a 256 "$SDK_ZIP" | awk '{print $1}')"
[[ "$actual_sha256" == "$SDK_SHA256" ]] || { echo "unexpected Windows SDK SHA-256: $actual_sha256" >&2; exit 2; }

unzip -q "$SDK_ZIP" -d "$OUT/sdk"
SDK_ROOT="$OUT/sdk/AlibabaCloud_RUM_Windows_0.4.4"
"$DOTNET" build "$ROOT/experiments/rum-local/windows/WindowsRumLocalProbe.csproj" \
    -c Release -p:RawLabRumSdkRoot="$SDK_ROOT" -o "$OUT/app" --nologo

if [[ "$1" == "--send" ]]; then
    [[ -n "${RAWLAB_RUM_APP_ID:-}" && -n "${RAWLAB_RUM_CONFIG_ADDRESS:-}" ]] || {
        echo "RAWLAB_RUM_APP_ID and RAWLAB_RUM_CONFIG_ADDRESS are required for --send" >&2
        exit 2
    }
    [[ -n "${RAWLAB_RUM_VALIDATION_RUN:-}" ]] || {
        echo "RAWLAB_RUM_VALIDATION_RUN is required for --send" >&2
        exit 2
    }
    [[ "${RAWLAB_RUM_LIMIT_VERIFIED:-}" == "1" && "${RAWLAB_RUM_NETWORK:-}" == "china-telecom" ]] || {
        echo "--send requires RAWLAB_RUM_LIMIT_VERIFIED=1 and RAWLAB_RUM_NETWORK=china-telecom" >&2
        exit 2
    }
    RUM_TEMP="$OUT/temp"
    mkdir -p "$RUM_TEMP"
    (
        cd "$OUT/app"
        TMPDIR="$RUM_TEMP" TEMP="$RUM_TEMP" TMP="$RUM_TEMP" \
            "$DOTNET" WindowsRumLocalProbe.dll
    ) >"$OUT/probe.log" 2>&1 &
    probe_pid=$!
    (
        sleep 60
        if kill -0 "$probe_pid" 2>/dev/null; then
            echo "WATCHDOG: probe exceeded 60 seconds; terminating it." >&2
            kill -TERM "$probe_pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$probe_pid" 2>/dev/null || true
        fi
    ) >>"$OUT/probe.log" 2>&1 &
    watchdog_pid=$!
    set +e
    wait "$probe_pid"
    probe_status=$?
    set -e
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    cat "$OUT/probe.log"
    exit "$probe_status"
else
    echo "PASS: Windows local RUM probe compiled; no SDK calls were made."
fi
