#!/bin/bash
# Mac 真包 dualdn_api 门禁：以 ORT osx + 正式 DualDn 模型包重新配置专用构建目录，
# 只跑 ctest 的 dualdn_api（RAWLAB_TEST_AI 断言：CoreML 真推理与 SceneRGB 完备缓存
# 渲染路径）。快速 CPU 门未配置 RAWLAB_DUALDN_TEST_PACKAGE，注册的是 dualdn_api_disabled，
# 该断言块被编译掉——在此长期假绿。可传构建目录复用已有 AI-ON 配置（如 CI 的 build-macos）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
# 输入优先用显式注入（full 门已由 ai-inputs 步骤注入 env，手工亦可传入）；缺失时剥掉
# GITHUB_ENV 交给 ai-inputs 自解析——GHA 下 ai-inputs 只追加 $GITHUB_ENV，当前进程看不到，
# stdout 为空会把本脚本的 json 解析崩成假失败；拆成两段并保留 set -e，让真失败原样报错。
if [ -z "${RAWLAB_ONNXRUNTIME_ROOT:-}" ] || [ -z "${RAWLAB_DUALDN_MODEL_DIR:-}" ]; then
    AI_ARCH="${RAWLAB_ARCH:-$(uname -m)}"
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
BUILD="${1:-$ROOT/lutools/build-ai-package}"
cmake -S "$ROOT/lutools" -B "$BUILD" -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Debug \
    -DSONY2FUJI_ENABLE_OPENMP=OFF -DSONY2FUJI_ENABLE_CHROMA_DENOISE=ON \
    -DSONY2FUJI_ENABLE_AI_DENOISE=ON -DONNXRUNTIME_ROOT="$RAWLAB_ONNXRUNTIME_ROOT" \
    -DRAWLAB_DUALDN_TEST_PACKAGE="$RAWLAB_DUALDN_MODEL_DIR" \
    -DOpenCV_DIR="$RAWLAB_DEPENDENCY_PREFIX/lib/cmake/opencv4"
cmake --build "$BUILD" --target dualdn_api_tests -j "${CMAKE_BUILD_PARALLEL_LEVEL:-6}"
ctest --test-dir "$BUILD" -R '^dualdn_api$' --output-on-failure --no-tests=error
