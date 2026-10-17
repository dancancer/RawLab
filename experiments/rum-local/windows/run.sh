#!/bin/bash
# ============================================================================
#  Windows 实网验证探针：在 macOS 上编译检查，或打出 win-x64 独立运行包
#  用法：run.sh --build             只编译，不调用 SDK、不联网发事件
#        run.sh --publish [目录]     独立运行包（目标机器不需要 .NET），
#                                     默认放在主工作区 .cache/tmp/rum-probe-windows
#  发送只在 Windows 上通过包内的 validate.ps1 进行。
#  SDK 归档放主工作区共享缓存，缺失时从供应商固定地址下载，SHA-256 不符即停止。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$ROOT/scripts/rum/shared-cache.sh"
MAIN="$(cd "$RUM_CACHE_ROOT/../../.." 2>/dev/null && pwd || echo "$ROOT")"
PROJECT="$ROOT/experiments/rum-local/windows/WindowsRumLocalProbe.csproj"
SDK_ZIP="$RUM_CACHE_ROOT/windows/0.4.4/sdk.zip"
SDK_URL=https://rum-sdk.oss-cn-hangzhou.aliyuncs.com/native/AlibabaCloud_RUM_Windows_0.4.4.zip
SDK_SHA256=bfa05c0718a57eb7e94c9494499bd3c84305a3cc39b76d6a9096667553928994
DOTNET="${DOTNET:-$MAIN/build/tools/dotnet/dotnet}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-rum-windows.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [[ "${1:-}" != "--build" && "${1:-}" != "--publish" ]]; then
    echo "usage: $0 --build | --publish [output-directory]" >&2
    exit 2
fi
[[ -x "$DOTNET" ]] || { echo "dotnet is missing: $DOTNET (set DOTNET=...)" >&2; exit 2; }
if [[ ! -f "$SDK_ZIP" ]]; then
    mkdir -p "$(dirname "$SDK_ZIP")"
    curl --fail --location --proto '=https' --max-time 180 --retry 2 "$SDK_URL" -o "$SDK_ZIP.download"
    mv "$SDK_ZIP.download" "$SDK_ZIP"
fi
actual_sha256="$(shasum -a 256 "$SDK_ZIP" | awk '{print $1}')"
[[ "$actual_sha256" == "$SDK_SHA256" ]] || { echo "unexpected Windows RUM SDK SHA-256: $actual_sha256" >&2; exit 2; }

# 中间产物放临时目录，源码目录保持干净
BUILD_PATHS=(-p:BaseIntermediateOutputPath="$WORK/obj/" -p:BaseOutputPath="$WORK/bin/" -p:RawLabRumSdkZip="$SDK_ZIP")
if [[ "$1" == "--build" ]]; then
    "$DOTNET" build "$PROJECT" -c Release "${BUILD_PATHS[@]}" --nologo
    echo "PASS: Windows production RUM probe compiled; no SDK calls were made."
    exit 0
fi

OUT="${2:-$MAIN/.cache/tmp/rum-probe-windows}"
rm -rf "$OUT"
"$DOTNET" publish "$PROJECT" -c Release -r win-x64 --self-contained true -o "$OUT" "${BUILD_PATHS[@]}" --nologo
cp "$ROOT/experiments/rum-local/windows/validate.ps1" "$OUT/"
echo "PUBLISHED: $OUT"
echo "Copy the whole folder to the Windows PC, then in Windows PowerShell:"
echo "  \$env:RAWLAB_RUM_LIMIT_VERIFIED='1'; \$env:RAWLAB_RUM_NETWORK='china-telecom'"
echo "  .\\validate.ps1 -ValidationRun ([guid]::NewGuid())"
