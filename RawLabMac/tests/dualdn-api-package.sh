#!/bin/bash
# Mac 真包 dualdn_api 门禁：以 ORT osx + 正式 DualDn 模型包重新配置专用构建目录，
# 只跑 ctest 的 dualdn_api（RAWLAB_TEST_AI 断言：CoreML 真推理与 SceneRGB 完备缓存
# 渲染路径）。快速 CPU 门未配置 RAWLAB_DUALDN_TEST_PACKAGE，注册的是 dualdn_api_disabled，
# 该断言块被编译掉——在此长期假绿。可传构建目录复用已有 AI-ON 配置（如 CI 的 build-macos）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ -z "${RAWLAB_ONNXRUNTIME_ROOT:-}" ] || [ -z "${RAWLAB_DUALDN_MODEL_DIR:-}" ]; then
    AI_ARCH="${RAWLAB_ARCH:-$(uname -m)}"
    eval "$(python3 scripts/ci/ai-inputs.py --platform macos --arch "$AI_ARCH" |
        python3 -c 'import json,sys; [print(f"export {k}={v!r}") for k,v in json.load(sys.stdin).items() if k.startswith("RAWLAB_")]')"
    export RAWLAB_ONNXRUNTIME_ROOT RAWLAB_DUALDN_MODEL_DIR
fi
: "${RAWLAB_ONNXRUNTIME_ROOT:?ONNX Runtime 1.23.2 root is required for the real-package DualDn gate}"
: "${RAWLAB_DUALDN_MODEL_DIR:?the validated DualDn model package directory is required for the real-package gate}"
source "$ROOT/RawLabMac/build-env.sh"
BUILD="${1:-$ROOT/lutools/build-ai-package}"
cmake -S "$ROOT/lutools" -B "$BUILD" -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Debug \
    -DSONY2FUJI_ENABLE_OPENMP=OFF -DSONY2FUJI_ENABLE_CHROMA_DENOISE=ON \
    -DSONY2FUJI_ENABLE_AI_DENOISE=ON -DONNXRUNTIME_ROOT="$RAWLAB_ONNXRUNTIME_ROOT" \
    -DRAWLAB_DUALDN_TEST_PACKAGE="$RAWLAB_DUALDN_MODEL_DIR" \
    -DOpenCV_DIR="$RAWLAB_DEPENDENCY_PREFIX/lib/cmake/opencv4"
cmake --build "$BUILD" --target dualdn_api_tests -j "${CMAKE_BUILD_PARALLEL_LEVEL:-6}"
ctest --test-dir "$BUILD" -R '^dualdn_api$' --output-on-failure --no-tests=error
