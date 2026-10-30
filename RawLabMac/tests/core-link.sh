#!/bin/bash
# 核心静态库的链接参数。发布包和完整 CI 在 Apple 芯片上以 AI 降噪构建核心，C ABI 会引用
# DualDn 静态库、ONNX Runtime 与 Core ML；按构建配置一起链接，不另建无 AI 的核心。
CORE_BUILD="${RAWLAB_BUILD_DIR:-$ROOT/lutools/build-macos}"
CORE_LINK=("$CORE_BUILD/libsony2fuji_core.a")
if grep -qs '^SONY2FUJI_ENABLE_X3F:BOOL=ON$' "$CORE_BUILD/CMakeCache.txt"; then
    case "${ARCH:-$(uname -m)}" in arm64) X3F_TARGET=aarch64-apple-darwin ;; x86_64) X3F_TARGET=x86_64-apple-darwin ;; esac
    CORE_LINK+=("$CORE_BUILD/x3f-rust/$X3F_TARGET/release/librawlab_x3f.a" -liconv)
fi
CORE_LINK+=("$CORE_BUILD/hdr-codec/lib/libuhdr.a" "$CORE_BUILD/raw-jpeg/install/lib/libjpeg.a"
    -framework CoreImage -framework ImageIO -framework CoreGraphics)
if grep -qs '^SONY2FUJI_ENABLE_AI_DENOISE:BOOL=ON$' "$CORE_BUILD/CMakeCache.txt"; then
    CORE_ORT_LIB="$(sed -n 's/^ONNXRUNTIME_ROOT:PATH=//p' "$CORE_BUILD/CMakeCache.txt")/lib"
    CORE_LINK+=("$CORE_BUILD/librawlab_dualdn_runtime.a" "$CORE_BUILD/librawlab_dualdn_core.a"
        -L "$CORE_ORT_LIB" -lonnxruntime -Xlinker -rpath -Xlinker "$CORE_ORT_LIB" -framework CoreML)
fi
