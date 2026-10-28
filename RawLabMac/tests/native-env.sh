#!/bin/bash
# 与原生 Swift 测试目标使用同一架构的已构建依赖。
source "$ROOT/RawLabMac/build-env.sh"
DEPENDENCY_PREFIX="$RAWLAB_DEPENDENCY_PREFIX"
if ! pkg-config --exists libraw opencv4 wavelib rawlab-dng-sdk lensfun 'libtiff-4 >= 4.7.1'; then
    echo "Build the Mac app and dependencies first: bash RawLabMac/build.sh" >&2
    exit 1
fi
source "$ROOT/RawLabMac/tests/core-link.sh"
