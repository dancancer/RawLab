#!/bin/bash
# Shared SwiftPM RawLabKit build helper for Apple shell test harnesses.
# Usage:
#   source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
#   rawlabkit_flags [link|typecheck] <scratch_base> [macos|iphonesimulator] [rum_local:0|1]
# Sets RAWLABKIT_BIN and RAWLABKIT_SWIFTC_FLAGS=(...).

rawlabkit_flags() {
    local mode="${1:-link}"
    local scratch_base="${2:-${TMPDIR:-/tmp}/rawlabkit-swiftpm}"
    local platform="${3:-macos}"
    local rum_local="${4:-${RAWLAB_RUM_LOCAL:-0}}"
    local arch="${RAWLAB_ARCH:-$(uname -m)}"
    local sdk target triple suffix=""
    local build_args=(--package-path "$ROOT" -c release)

    case "$platform" in
        iphonesimulator)
            sdk="${SIM_SDK:-${SDK:-$(env -u SDKROOT xcrun --sdk iphonesimulator --show-sdk-path)}}"
            triple="${arch}-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-18.0}-simulator"
            build_args+=(--triple "$triple" -Xswiftc -sdk -Xswiftc "$sdk")
            ;;
        macos)
            sdk="${SDK:-${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}}"
            target="${arch}-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}"
            build_args+=(--arch "$arch" -Xswiftc -sdk -Xswiftc "$sdk" -Xswiftc -target -Xswiftc "$target")
            ;;
        *)
            echo "Unknown RawLabKit platform: $platform" >&2
            return 2
            ;;
    esac

    if [ "$rum_local" = 1 ]; then
        build_args+=(-Xswiftc -DRAWLAB_RUM_LOCAL)
        suffix="-rumlocal"
    fi

    local sdk_key
    sdk_key="$(basename "$sdk" .sdk)"
    local scratch_root="${RAWLAB_SWIFTPM_CACHE:-$scratch_base}"
    local scratch="$scratch_root/${platform}-${arch}-${sdk_key}${suffix}"
    mkdir -p "$scratch"

    if [ "$platform" = macos ]; then
        SDKROOT="$sdk" swift build "${build_args[@]}" --scratch-path "$scratch" >&2
        RAWLABKIT_BIN="$(SDKROOT="$sdk" swift build "${build_args[@]}" --scratch-path "$scratch" --show-bin-path)"
    else
        env -u SDKROOT swift build "${build_args[@]}" --scratch-path "$scratch" >&2
        RAWLABKIT_BIN="$(env -u SDKROOT swift build "${build_args[@]}" --scratch-path "$scratch" --show-bin-path)"
    fi
    if [ ! -e "$RAWLABKIT_BIN/RawLabKit.swiftmodule" ] && [ ! -e "$RAWLABKIT_BIN/Modules/RawLabKit.swiftmodule" ]; then
        if [ "$platform" = macos ]; then
            SDKROOT="$sdk" swift build "${build_args[@]}" --scratch-path "$scratch" --target RawLabKit >&2
        else
            env -u SDKROOT swift build "${build_args[@]}" --scratch-path "$scratch" --target RawLabKit >&2
        fi
    fi
    if [ ! -e "$RAWLABKIT_BIN/RawLabKit.swiftmodule" ] && [ ! -e "$RAWLABKIT_BIN/Modules/RawLabKit.swiftmodule" ]; then
        echo "error: RawLabKit.swiftmodule not found under $RAWLABKIT_BIN" >&2
        return 1
    fi
    RAWLABKIT_SWIFTC_FLAGS=(-I "$RAWLABKIT_BIN")
    if [ -d "$RAWLABKIT_BIN/Modules" ]; then
        RAWLABKIT_SWIFTC_FLAGS+=(-I "$RAWLABKIT_BIN/Modules")
    fi
    if [ "$mode" != typecheck ]; then
        if [ ! -f "$RAWLABKIT_BIN/libRawLabKit.a" ]; then
            echo "error: libRawLabKit.a not found under $RAWLABKIT_BIN" >&2
            return 1
        fi
        RAWLABKIT_SWIFTC_FLAGS+=("$RAWLABKIT_BIN/libRawLabKit.a")
    fi
}
