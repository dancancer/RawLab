#!/bin/bash
# Apple Silicon 真实硬件 Core ML AI 门禁（发布前必跑）：以 ORT osx + 正式 DualDn 模型包
# 配置 AI-ON 构建目录，运行托管 macOS VM 上不适用的三项 Core ML 硬件测试
# （ai_session_memory、dualdn_native、dualdn_api）。拒绝在非 arm64、虚拟机或缺少
# 物理 GPU 推理的情况下（含 exit 77 跳过或未触达硬件分支）记为通过。
# 可传构建目录复用已有 AI-ON 配置（如 lutools/build-macos）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "arm64" ]; then
    echo "error: Core ML AI hardware gate requires a physical Apple Silicon (arm64) Mac; got $HOST_ARCH" >&2
    exit 1
fi
if [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = "1" ]; then
    echo "error: Core ML AI hardware gate refuses virtualized macOS runners (kern.hv_vmm_present=1); run on a physical Apple Silicon Mac" >&2
    exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
# 输入优先用显式注入；缺失时剥掉 GITHUB_ENV 交给 ai-inputs 自解析。
if [ -z "${RAWLAB_ONNXRUNTIME_ROOT:-}" ] || [ -z "${RAWLAB_DUALDN_MODEL_DIR:-}" ]; then
    AI_ARCH="${RAWLAB_ARCH:-$HOST_ARCH}"
    AI_INPUTS="$(env -u GITHUB_ENV python3 scripts/ci/ai-inputs.py --platform macos --arch "$AI_ARCH")"
    eval "$(printf '%s' "$AI_INPUTS" | python3 -c 'import json,sys
for key, value in json.load(sys.stdin).items():
    if key.startswith("RAWLAB_"):
        print(f"export {key}={value!r}")')"
fi
: "${RAWLAB_ONNXRUNTIME_ROOT:?RAWLAB_ONNXRUNTIME_ROOT (ONNX Runtime 1.23.2 root) is required; export it or let scripts/ci/ai-inputs.py resolve it}"
: "${RAWLAB_DUALDN_MODEL_DIR:?RAWLAB_DUALDN_MODEL_DIR (validated DualDn package directory) is required; export it or let scripts/ci/ai-inputs.py resolve it}"
[ -d "$RAWLAB_ONNXRUNTIME_ROOT" ] || { echo "error: RAWLAB_ONNXRUNTIME_ROOT does not exist: $RAWLAB_ONNXRUNTIME_ROOT" >&2; exit 1; }
[ -f "$RAWLAB_DUALDN_MODEL_DIR/manifest.json" ] || { echo "error: RAWLAB_DUALDN_MODEL_DIR has no manifest.json: $RAWLAB_DUALDN_MODEL_DIR" >&2; exit 1; }
source "$ROOT/RawLabMac/build-env.sh"
source "$ROOT/RawLabMac/tests/lib/compile.sh"

BUILD="${1:-$ROOT/lutools/build-ai-package}"
cmake -S "$ROOT/lutools" -B "$BUILD" -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Debug \
    -DSONY2FUJI_ENABLE_OPENMP=OFF -DSONY2FUJI_ENABLE_CHROMA_DENOISE=ON \
    -DSONY2FUJI_ENABLE_AI_DENOISE=ON -DONNXRUNTIME_ROOT="$RAWLAB_ONNXRUNTIME_ROOT" \
    -DRAWLAB_DUALDN_TEST_PACKAGE="$RAWLAB_DUALDN_MODEL_DIR" \
    -DOpenCV_DIR="$RAWLAB_DEPENDENCY_PREFIX/lib/cmake/opencv4"
cmake --build "$BUILD" \
    --target ai_session_memory_tests dualdn_native_tests dualdn_api_tests \
    -j "${CMAKE_BUILD_PARALLEL_LEVEL:-6}"

rawlab_mac_make_temp_dir GATE_TMP rawlab-mac-ai-hw-gate
JUNIT_XML="$GATE_TMP/ctest.xml"
CTEST_LOG="$GATE_TMP/ctest.log"

# 串行执行：ai_session_memory 含 16.77MP 峰值 RSS/堆预算门禁，避免并发叠加内存或争用 GPU。
ctest --test-dir "$BUILD" \
    -R '^(ai_session_memory|dualdn_native|dualdn_api)$' \
    --output-on-failure --verbose --no-tests=error \
    --output-junit "$JUNIT_XML" 2>&1 | tee "$CTEST_LOG"

python3 - "$JUNIT_XML" "$CTEST_LOG" ai_session_memory dualdn_native dualdn_api <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

junit_path = Path(sys.argv[1])
log_path = Path(sys.argv[2])
expected = sys.argv[3:]

if not junit_path.is_file():
    sys.exit(f"FAIL: missing CTest JUnit report: {junit_path}")

root = ET.parse(junit_path).getroot()
cases = {tc.attrib.get("name"): tc for tc in root.findall(".//testcase")}
missing = [name for name in expected if name not in cases]
unexpected = sorted(set(cases) - set(expected))
if missing or unexpected:
    sys.exit(f"FAIL: Core ML hardware gate test mismatch (missing={missing}, unexpected={unexpected})")

for name in expected:
    tc = cases[name]
    status = tc.attrib.get("status", "")
    if status != "run":
        sys.exit(f"FAIL: hardware gate test {name} did not run (status={status!r})")
    if tc.find("skipped") is not None:
        sys.exit(f"FAIL: hardware gate test {name} was skipped; a physical Apple Silicon GPU pass is required")
    if tc.find("failure") is not None or tc.find("error") is not None:
        sys.exit(f"FAIL: hardware gate test {name} failed")

log_text = log_path.read_text(encoding="utf-8", errors="replace")
if "hardware inference NOT REACHED" in log_text:
    sys.exit("FAIL: dualdn_api reported 'hardware inference NOT REACHED'; physical Core ML GPU is required")
if "PASS Saving-phase cancellation publishes no final AI cache" not in log_text:
    sys.exit("FAIL: dualdn_api did not complete the hardware Core ML GPU Saving-phase cancellation path")
if "PASS native float32 Core ML" not in log_text:
    sys.exit("FAIL: dualdn_native did not complete native Core ML GPU verification")
if "PASS AI session residency release" not in log_text:
    sys.exit("FAIL: ai_session_memory did not complete")

print(f"PASS: Apple Silicon Core ML hardware gate ({len(expected)}/{len(expected)}: {', '.join(expected)})")
PY
