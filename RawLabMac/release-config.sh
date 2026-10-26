#!/bin/bash
# 由 build.sh 在开始下载或编译之前加载。
if [ "${RAWLAB_RELEASE:-0}" = 1 ]; then
    : "${RAWLAB_RELEASE_VERSION:?Set RAWLAB_RELEASE_VERSION to the authorized release version}"
    : "${RAWLAB_RELEASE_BUILD:?Set RAWLAB_RELEASE_BUILD to the authorized build number}"
    : "${RAWLAB_CODESIGN_IDENTITY:?Set RAWLAB_CODESIGN_IDENTITY to the fixed signing certificate}"
    : "${RAWLAB_SPARKLE_PUBLIC_KEY:?Set RAWLAB_SPARKLE_PUBLIC_KEY to the persistent EdDSA public key}"
    : "${RAWLAB_DUALDN_MODEL_DIR:?Release builds require the complete DualDn model package}"
    : "${RAWLAB_DUALDN_MANIFEST_SHA256:?Pin RAWLAB_DUALDN_MANIFEST_SHA256 for this model package}"
    : "${RAWLAB_ONNXRUNTIME_ROOT:?Release builds require ONNX Runtime 1.23.2}"
    if [ "${RAWLAB_DUALDN:-1}" != 1 ]; then echo 'Release builds require GPU AI denoise.' >&2; exit 2; fi
    export RAWLAB_DUALDN=1
    python3 "$ROOT/scripts/release/macos_config.py" validate
fi
