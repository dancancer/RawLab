#!/bin/bash

# Sony2Fuji 构建脚本
# 支持: Linux, macOS, iOS, Android

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}========================================${NC}"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查依赖
check_dependencies() {
    print_info "检查依赖..."

    if ! command -v cmake &> /dev/null; then
        print_error "CMake 未安装"
        exit 1
    fi

    if ! command -v pkg-config &> /dev/null; then
        print_error "pkg-config 未安装"
        exit 1
    fi

    if ! pkg-config --exists libraw; then
        print_error "libraw 未安装"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            print_info "请运行: brew install libraw"
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            print_info "请运行: sudo apt-get install libraw-dev"
        fi
        exit 1
    fi

    print_info "依赖检查通过"
}

# 构建桌面版本
build_desktop() {
    print_header "构建桌面版本"

    BUILD_DIR="build"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_CLI=ON \
        -DBUILD_SHARED_LIB=ON \
        -DBUILD_EXAMPLES=OFF

    cmake --build . --config Release -j$(nproc 2>/dev/null || sysctl -n hw.ncpu)

    cd ..

    print_info "构建完成!"
    print_info "可执行文件: $BUILD_DIR/sony2fuji"
    print_info "共享库: $BUILD_DIR/libsony2fuji.so (或 .dylib)"
}

# 构建 iOS
build_ios() {
    print_header "构建 iOS Framework"

    if [[ "$OSTYPE" != "darwin"* ]]; then
        print_error "iOS 构建仅支持 macOS"
        exit 1
    fi

    bash platform/ios/build-framework.sh
}

# 构建 Android
build_android() {
    print_header "构建 Android 库"

    if [ -z "$ANDROID_NDK" ]; then
        print_error "请设置 ANDROID_NDK 环境变量"
        print_info "例如: export ANDROID_NDK=\$HOME/Android/Sdk/ndk/25.2.9519653"
        exit 1
    fi

    for ABI in arm64-v8a armeabi-v7a x86 x86_64; do
        print_info "构建架构: $ABI"

        BUILD_DIR="build-android-$ABI"
        rm -rf "$BUILD_DIR"
        mkdir -p "$BUILD_DIR"
        cd "$BUILD_DIR"

        cmake .. \
            -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
            -DANDROID_ABI=$ABI \
            -DANDROID_PLATFORM=android-24 \
            -DANDROID_STL=c++_shared \
            -DBUILD_SHARED_LIB=ON \
            -DBUILD_CLI=OFF

        cmake --build . --config Release -j$(nproc)

        cd ..

        # 复制到 jniLibs
        mkdir -p platform/android/jniLibs/$ABI
        cp $BUILD_DIR/libsony2fuji.so platform/android/jniLibs/$ABI/
    done

    print_info "Android 库构建完成"
    print_info "位置: platform/android/jniLibs/"
}

# 清理
clean() {
    print_header "清理构建文件"

    rm -rf build build-*
    rm -rf platform/android/jniLibs

    print_info "清理完成"
}

# 运行测试
run_tests() {
    print_header "运行测试"

    if [ ! -f "build/core_tests" ]; then
        print_error "请先构建项目"
        exit 1
    fi

    if [ ! -f "F-Log2/X100VI_FLog2_FGamut_to_ETERNA_BT.709_33grid_V.1.00.cube" ]; then
        print_error "找不到测试 LUT 文件"
        exit 1
    fi

    ctest --test-dir build --output-on-failure
}

# 显示帮助
show_help() {
    echo "Sony2Fuji 构建脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  desktop     构建桌面版本 (默认)"
    echo "  ios         构建 iOS Framework"
    echo "  android     构建 Android 库"
    echo "  all         构建所有平台"
    echo "  clean       清理构建文件"
    echo "  test        运行测试"
    echo "  help        显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0              # 构建桌面版本"
    echo "  $0 ios          # 构建 iOS"
    echo "  $0 android      # 构建 Android"
    echo "  $0 all          # 构建所有平台"
}

# 主函数
main() {
    cd "$(dirname "$0")"

    case "${1:-desktop}" in
        desktop)
            check_dependencies
            build_desktop
            ;;
        ios)
            build_ios
            ;;
        android)
            check_dependencies
            build_android
            ;;
        all)
            check_dependencies
            build_desktop
            if [[ "$OSTYPE" == "darwin"* ]]; then
                build_ios
            fi
            if [ -n "$ANDROID_NDK" ]; then
                build_android
            fi
            ;;
        clean)
            clean
            ;;
        test)
            run_tests
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
