#!/bin/bash
# 由 build.sh 在开始下载或编译之前加载。
if [ "${RAWLAB_RELEASE:-0}" = 1 ]; then
    _rawlab_version="$("${PYTHON_EXECUTABLE:-python3}" "$ROOT/scripts/version/generate.py" --print version)"
    _rawlab_build="$("${PYTHON_EXECUTABLE:-python3}" "$ROOT/scripts/version/generate.py" --print build)"
    export RAWLAB_RELEASE_VERSION="${RAWLAB_RELEASE_VERSION:-$_rawlab_version}"
    export RAWLAB_RELEASE_BUILD="${RAWLAB_RELEASE_BUILD:-$_rawlab_build}"
    unset _rawlab_version _rawlab_build
    : "${RAWLAB_CODESIGN_IDENTITY:?Set RAWLAB_CODESIGN_IDENTITY to the fixed signing certificate}"
    : "${RAWLAB_SPARKLE_PUBLIC_KEY:?Set RAWLAB_SPARKLE_PUBLIC_KEY to the persistent EdDSA public key}"
    if [ "$ARCH" = arm64 ]; then
        # Apple Silicon 发布包只内置推理运行时，模型改为应用内按需下载，不再强制要求模型目录或 manifest 哈希。
        : "${RAWLAB_ONNXRUNTIME_ROOT:?Apple Silicon release builds require ONNX Runtime 1.23.2}"
        if [ "${RAWLAB_DUALDN:-1}" != 1 ]; then echo 'Apple Silicon release builds require GPU AI denoise.' >&2; exit 2; fi
        export RAWLAB_DUALDN=1
    else
        # Intel 没有 Core ML GPU 后端；发布包不编译 AI，也不带模型和 ONNX Runtime，避免显示无法使用的开关。
        if [ "${RAWLAB_DUALDN:-0}" != 0 ]; then echo 'Intel release builds do not include AI denoise.' >&2; exit 2; fi
        export RAWLAB_DUALDN=0
    fi
    "${PYTHON_EXECUTABLE:-python3}" "$ROOT/scripts/release/macos_config.py" validate "$ARCH"
fi
