#!/bin/bash
# Shared SwiftPM RawLabKit build helper for Apple shell test harnesses.
# Usage:
#   source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
#   rawlabkit_flags [link|typecheck] <scratch_base> [macos|iphonesimulator] [rum_local:0|1]
# Sets RAWLABKIT_BIN and RAWLABKIT_SWIFTC_FLAGS=(...).

_rawlab_swiftpm_write_bin_path() {
    local scratch="$1"
    local bin_path="$2"
    local tmp="$scratch/.rawlab-bin-path.tmp.$$"
    printf '%s\n' "$bin_path" > "$tmp"
    mv -f "$tmp" "$scratch/.rawlab-bin-path"
}

_rawlab_swiftpm_has_module() {
    local bin_dir="$1"
    local target="$2"
    [ -e "$bin_dir/$target.swiftmodule" ] || [ -e "$bin_dir/Modules/$target.swiftmodule" ]
}

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

    local use_prebuilt=0
    if [ "$rum_local" = 0 ]; then
        if [ "${RAWLAB_SWIFTPM_PREBUILT:-0}" = 1 ] || { [ "$platform" = macos ] && [ "${RAWLAB_SWIFTPM_PREBUILT_MACOS:-0}" = 1 ]; }; then
            use_prebuilt=1
        fi
    fi
    if [ "$use_prebuilt" = 1 ] && [ -s "$scratch/.rawlab-bin-path" ]; then
        local cached_bin
        cached_bin="$(cat "$scratch/.rawlab-bin-path")"
        if [ -d "$cached_bin" ] && _rawlab_swiftpm_has_module "$cached_bin" RawLabKit; then
            if [ "$mode" = typecheck ] || [ -f "$cached_bin/libRawLabKit.a" ]; then
                RAWLABKIT_BIN="$cached_bin"
                RAWLABKIT_SWIFTC_FLAGS=(-I "$RAWLABKIT_BIN")
                if [ -d "$RAWLABKIT_BIN/Modules" ]; then
                    RAWLABKIT_SWIFTC_FLAGS+=(-I "$RAWLABKIT_BIN/Modules")
                fi
                RAWLABKIT_SWIFTC_FLAGS+=(-Xcc "-fmodule-map-file=$ROOT/lutools/include/sony2fuji/ffi/module.modulemap")
                if [ "$mode" != typecheck ]; then
                    RAWLABKIT_SWIFTC_FLAGS+=("$RAWLABKIT_BIN/libRawLabKit.a")
                fi
                return 0
            fi
        fi
    fi

    local lock_dir="$scratch.lock"
    (
        lock_owned=0
        cleanup_lock() {
            [ "$lock_owned" -eq 1 ] && rmdir "$lock_dir" 2>/dev/null || true
        }
        trap 'cleanup_lock' EXIT
        trap 'cleanup_lock; exit 130' INT
        trap 'cleanup_lock; exit 143' TERM
        while ! mkdir "$lock_dir" 2>/dev/null; do
            sleep 0.05
        done
        lock_owned=1
        local bin_dir
        if [ "$platform" = macos ]; then
            SDKROOT="$sdk" swift build "${build_args[@]}" --scratch-path "$scratch" >&2
            bin_dir="$(SDKROOT="$sdk" swift build "${build_args[@]}" --scratch-path "$scratch" --show-bin-path)"
        else
            env -u SDKROOT swift build "${build_args[@]}" --scratch-path "$scratch" >&2
            bin_dir="$(env -u SDKROOT swift build "${build_args[@]}" --scratch-path "$scratch" --show-bin-path)"
        fi
        if ! _rawlab_swiftpm_has_module "$bin_dir" RawLabKit; then
            if [ "$platform" = macos ]; then
                SDKROOT="$sdk" swift build "${build_args[@]}" --scratch-path "$scratch" --target RawLabKit >&2
            else
                env -u SDKROOT swift build "${build_args[@]}" --scratch-path "$scratch" --target RawLabKit >&2
            fi
        fi
        if ! _rawlab_swiftpm_has_module "$bin_dir" RawLabKit; then
            echo "error: RawLabKit.swiftmodule not found under $bin_dir" >&2
            exit 1
        fi
        _rawlab_swiftpm_write_bin_path "$scratch" "$bin_dir"
    ) || return $?

    RAWLABKIT_BIN="$(cat "$scratch/.rawlab-bin-path")"
    RAWLABKIT_SWIFTC_FLAGS=(-I "$RAWLABKIT_BIN")
    if [ -d "$RAWLABKIT_BIN/Modules" ]; then
        RAWLABKIT_SWIFTC_FLAGS+=(-I "$RAWLABKIT_BIN/Modules")
    fi
    RAWLABKIT_SWIFTC_FLAGS+=(-Xcc "-fmodule-map-file=$ROOT/lutools/include/sony2fuji/ffi/module.modulemap")
    if [ "$mode" != typecheck ]; then
        if [ ! -f "$RAWLABKIT_BIN/libRawLabKit.a" ]; then
            echo "error: libRawLabKit.a not found under $RAWLABKIT_BIN" >&2
            return 1
        fi
        RAWLABKIT_SWIFTC_FLAGS+=("$RAWLABKIT_BIN/libRawLabKit.a")
    fi
}

# Usage:
#   rawlabnative_flags [link|typecheck] <scratch_base> [macos|iphonesimulator] [rum_local:0|1] [all|types_only]
# Sets RAWLABNATIVE_BIN and RAWLABNATIVE_SWIFTC_FLAGS=(...).
rawlabnative_flags() {
    local mode="${1:-link}"
    local scratch_base="${2:-${TMPDIR:-/tmp}/rawlabkit-swiftpm}"
    local platform="${3:-macos}"
    local rum_local="${4:-${RAWLAB_RUM_LOCAL:-0}}"
    local target_mode="${5:-all}"
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
            echo "Unknown RawLabNative platform: $platform" >&2
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

    local targets=(RawLabKit RawLabNativeTypes)
    if [ "$target_mode" = all ]; then
        targets+=(RawLabNative)
    elif [ "$target_mode" = inspection ]; then
        targets+=(RawLabInspectionNative)
    elif [ "$target_mode" != types_only ]; then
        echo "Unknown RawLabNative target mode: $target_mode" >&2
        return 2
    fi

    local use_prebuilt=0
    if [ "$rum_local" = 0 ]; then
        if [ "${RAWLAB_SWIFTPM_PREBUILT:-0}" = 1 ] || { [ "$platform" = macos ] && [ "${RAWLAB_SWIFTPM_PREBUILT_MACOS:-0}" = 1 ]; }; then
            use_prebuilt=1
        fi
    fi
    if [ "$use_prebuilt" = 1 ] && [ -s "$scratch/.rawlab-bin-path" ]; then
        local cached_bin prebuilt_ok=1 t
        cached_bin="$(cat "$scratch/.rawlab-bin-path")"
        if [ -d "$cached_bin" ]; then
            for t in "${targets[@]}"; do
                if ! _rawlab_swiftpm_has_module "$cached_bin" "$t"; then
                    prebuilt_ok=0
                    break
                fi
                if [ "$mode" != typecheck ] && [ ! -f "$cached_bin/lib$t.a" ]; then
                    prebuilt_ok=0
                    break
                fi
            done
        else
            prebuilt_ok=0
        fi
        if [ "$prebuilt_ok" = 1 ]; then
            RAWLABNATIVE_BIN="$cached_bin"
            RAWLABNATIVE_SWIFTC_FLAGS=(-I "$RAWLABNATIVE_BIN")
            if [ -d "$RAWLABNATIVE_BIN/Modules" ]; then
                RAWLABNATIVE_SWIFTC_FLAGS+=(-I "$RAWLABNATIVE_BIN/Modules")
            fi
            RAWLABNATIVE_SWIFTC_FLAGS+=(-Xcc "-fmodule-map-file=$ROOT/lutools/include/sony2fuji/ffi/module.modulemap")
            if [ "$mode" != typecheck ]; then
                if [ "$target_mode" = all ]; then
                    RAWLABNATIVE_SWIFTC_FLAGS+=("$RAWLABNATIVE_BIN/libRawLabNative.a")
                    if [ -f "$RAWLABNATIVE_BIN/libRawLabInspectionNative.a" ]; then
                        RAWLABNATIVE_SWIFTC_FLAGS+=("$RAWLABNATIVE_BIN/libRawLabInspectionNative.a")
                    fi
                elif [ "$target_mode" = inspection ]; then
                    RAWLABNATIVE_SWIFTC_FLAGS+=("$RAWLABNATIVE_BIN/libRawLabInspectionNative.a")
                fi
                RAWLABNATIVE_SWIFTC_FLAGS+=("$RAWLABNATIVE_BIN/libRawLabNativeTypes.a" "$RAWLABNATIVE_BIN/libRawLabKit.a")
            fi
            return 0
        fi
    fi

    local lock_dir="$scratch.lock"
    (
        lock_owned=0
        cleanup_lock() {
            [ "$lock_owned" -eq 1 ] && rmdir "$lock_dir" 2>/dev/null || true
        }
        trap 'cleanup_lock' EXIT
        trap 'cleanup_lock; exit 130' INT
        trap 'cleanup_lock; exit 143' TERM
        while ! mkdir "$lock_dir" 2>/dev/null; do
            sleep 0.05
        done
        lock_owned=1
        local bin_dir t
        if [ "$platform" = macos ]; then
            SDKROOT="$sdk" swift build "${build_args[@]}" --scratch-path "$scratch" >&2
            bin_dir="$(SDKROOT="$sdk" swift build "${build_args[@]}" --scratch-path "$scratch" --show-bin-path)"
        else
            env -u SDKROOT swift build "${build_args[@]}" --scratch-path "$scratch" >&2
            bin_dir="$(env -u SDKROOT swift build "${build_args[@]}" --scratch-path "$scratch" --show-bin-path)"
        fi

        for t in "${targets[@]}"; do
            if ! _rawlab_swiftpm_has_module "$bin_dir" "$t"; then
                if [ "$platform" = macos ]; then
                    SDKROOT="$sdk" swift build "${build_args[@]}" --scratch-path "$scratch" --target "$t" >&2
                else
                    env -u SDKROOT swift build "${build_args[@]}" --scratch-path "$scratch" --target "$t" >&2
                fi
            fi
            if ! _rawlab_swiftpm_has_module "$bin_dir" "$t"; then
                echo "error: $t.swiftmodule not found under $bin_dir" >&2
                exit 1
            fi
        done
        _rawlab_swiftpm_write_bin_path "$scratch" "$bin_dir"
    ) || return $?

    RAWLABNATIVE_BIN="$(cat "$scratch/.rawlab-bin-path")"
    RAWLABNATIVE_SWIFTC_FLAGS=(-I "$RAWLABNATIVE_BIN")
    if [ -d "$RAWLABNATIVE_BIN/Modules" ]; then
        RAWLABNATIVE_SWIFTC_FLAGS+=(-I "$RAWLABNATIVE_BIN/Modules")
    fi
    RAWLABNATIVE_SWIFTC_FLAGS+=(-Xcc "-fmodule-map-file=$ROOT/lutools/include/sony2fuji/ffi/module.modulemap")

    if [ "$mode" != typecheck ]; then
        if [ "$target_mode" = all ]; then
            [ -f "$RAWLABNATIVE_BIN/libRawLabNative.a" ] || { echo "error: libRawLabNative.a not found under $RAWLABNATIVE_BIN" >&2; return 1; }
            RAWLABNATIVE_SWIFTC_FLAGS+=("$RAWLABNATIVE_BIN/libRawLabNative.a")
            if [ -f "$RAWLABNATIVE_BIN/libRawLabInspectionNative.a" ]; then
                RAWLABNATIVE_SWIFTC_FLAGS+=("$RAWLABNATIVE_BIN/libRawLabInspectionNative.a")
            fi
        elif [ "$target_mode" = inspection ]; then
            [ -f "$RAWLABNATIVE_BIN/libRawLabInspectionNative.a" ] || { echo "error: libRawLabInspectionNative.a not found under $RAWLABNATIVE_BIN" >&2; return 1; }
            RAWLABNATIVE_SWIFTC_FLAGS+=("$RAWLABNATIVE_BIN/libRawLabInspectionNative.a")
        fi
        [ -f "$RAWLABNATIVE_BIN/libRawLabNativeTypes.a" ] || { echo "error: libRawLabNativeTypes.a not found under $RAWLABNATIVE_BIN" >&2; return 1; }
        [ -f "$RAWLABNATIVE_BIN/libRawLabKit.a" ] || { echo "error: libRawLabKit.a not found under $RAWLABNATIVE_BIN" >&2; return 1; }
        RAWLABNATIVE_SWIFTC_FLAGS+=("$RAWLABNATIVE_BIN/libRawLabNativeTypes.a" "$RAWLABNATIVE_BIN/libRawLabKit.a")
    fi
}
