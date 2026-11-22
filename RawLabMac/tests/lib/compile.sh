#!/bin/bash
# Shared compilation, SDK/target resolution, and temp-dir lifecycle helpers for Mac tests.
# Pure definitions at source time so cross-platform contract tests can resolve source lists
# without Xcode/xcrun.

_RAWLAB_MAC_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [ -z "${ROOT:-}" ]; then
    ROOT="$_RAWLAB_MAC_LIB_ROOT"
fi

_RAWLAB_MAC_TEMP_DIRS=()

rawlab_mac_cleanup_temp_dirs() {
    local dir
    for dir in ${_RAWLAB_MAC_TEMP_DIRS[@]+"${_RAWLAB_MAC_TEMP_DIRS[@]}"}; do
        rm -rf "$dir"
    done
}

_rawlab_mac_validate_ident() {
    case "${1:-}" in
        ''|[0-9]*|*[!A-Za-z0-9_]*)
            echo "Invalid shell variable name: ${1:-}" >&2
            return 2
            ;;
    esac
}

# Usage: rawlab_mac_make_temp_dir VAR_NAME [prefix] [base_dir]
rawlab_mac_make_temp_dir() {
    local var_name="${1:?Pass output variable name}"
    local prefix="${2:-rawlab-mac-test}"
    local base="${3:-${RAWLAB_TEST_TMP_DIR:-${TMPDIR:-/tmp}}}"
    local dir
    _rawlab_mac_validate_ident "$var_name"
    base="${base%/}"
    : "${base:=/}"
    mkdir -p "$base"
    dir="$(mktemp -d "$base/${prefix}.XXXXXX")"
    _RAWLAB_MAC_TEMP_DIRS+=("$dir")
    if [ -z "$(trap -p EXIT)" ]; then
        trap rawlab_mac_cleanup_temp_dirs EXIT
    fi
    printf -v "$var_name" '%s' "$dir"
}

rawlab_mac_test_init() {
    source "$ROOT/RawLabMac/build-env.sh"
    if [ -z "${DEVELOPER_DIR:-}" ] && command -v xcode-select >/dev/null 2>&1; then
        DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
        if [ -n "$DEVELOPER_DIR" ]; then
            export DEVELOPER_DIR
        fi
    fi
    RAWLAB_MAC_SDK="$(rawlab_mac_sdk_path)"
    SDK="$RAWLAB_MAC_SDK"
    RAWLAB_MAC_TARGET="$(rawlab_mac_target)"
    export RAWLAB_MAC_SDK RAWLAB_MAC_TARGET
    source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
}

rawlab_mac_native_env() {
    rawlab_mac_test_init
    source "$ROOT/RawLabMac/tests/native-env.sh"
}

rawlab_mac_native_link_flags() {
    local out_var="${1:?Pass output array variable name}"
    _rawlab_mac_validate_ident "$out_var"
    local _flags=(${CORE_LINK[@]+"${CORE_LINK[@]}"}
        $(pkg-config --libs libraw_r rawlab-dng-sdk opencv4 wavelib lensfun libtiff-4)
        -lc++ -lz -framework SwiftUI -framework AppKit -framework ImageIO -framework Metal)
    eval "$out_var=(\"\${_flags[@]}\")"
}

_rawlab_mac_assign_array() {
    local out_var="$1"
    shift
    _rawlab_mac_validate_ident "$out_var"
    if [ "$#" -eq 0 ]; then
        echo "Source resolver produced empty list for $out_var" >&2
        return 1
    fi
    local _items=("$@")
    eval "$out_var=(\"\${_items[@]}\")"
}

rawlab_mac_full_app_sources() {
    local out_var="${1:?Pass output array variable name}"
    _rawlab_mac_validate_ident "$out_var"
    source "$ROOT/Shared/tests/mac-native-sources.sh"
    local _sources=()
    local _src
    while IFS= read -r -d '' _src; do
        _sources+=("$_src")
    done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' ! -name 'RawLabMacApp.swift' -print0 | LC_ALL=C sort -z)
    _sources+=("${MAC_SHARED_SWIFT_SOURCES[@]}")
    RAWLAB_MAC_BRIDGING_HEADER="$MAC_NATIVE_BRIDGING_HEADER"
    _rawlab_mac_assign_array "$out_var" "${_sources[@]}"
}

rawlab_mac_editor_model_sources() {
    local out_var="${1:?Pass output array variable name}"
    _rawlab_mac_validate_ident "$out_var"
    source "$ROOT/Shared/tests/hdr-native-sources.sh"
    local _sources=(
        "$ROOT/RawLabMac/Sources/Rendering/Engine.swift"
        "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift"
        "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift"
        "$ROOT/Shared/Native/ProcessingMigrationNative.swift"
        "${HDR_SWIFT_SOURCES[@]}"
        "$ROOT/Shared/HSLNative.swift"
        "$ROOT/Shared/HSLTargetNative.swift"
        "$ROOT/Shared/ToneControlsNative.swift"
        "$ROOT/Shared/AtmosphereNative.swift"
        "$ROOT/Shared/ColorGradingNative.swift"
        "$ROOT/Shared/ToneCurveNative.swift"
        "$ROOT/RawLabMac/Sources/Export/BatchExportModel.swift"
        "$ROOT/RawLabMac/Sources/Export/BatchSelection.swift"
        "$ROOT/RawLabMac/Sources/Export/ExportSizePicker.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+BatchSelection.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+ProcessingMigration.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+HDR.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Geometry.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+Rendering.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+HSLTarget.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+WBProbe.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentHistory.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentTransfer.swift"
        "$ROOT/RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentPresets.swift"
        "$ROOT/Shared/DCPCompiler.swift"
        "$ROOT/Shared/LookLibrary.swift"
        "$ROOT/RawLabMac/Sources/Library/FileLibrary.swift"
        "$ROOT/RawLabMac/Sources/Library/FileBrowser.swift"
        "$ROOT/RawLabMac/Sources/Looks/LUTCompatibilityDialog.swift"
        "$ROOT/Shared/LUTCompatibilityView.swift"
        "$ROOT/Shared/LUTCompatibilityPreview.swift"
        "$ROOT/RawLabMac/Sources/Presentation/MacNeutralReference.swift"
        "$ROOT/RawLabMac/Sources/Lens/MacStraightenPreview.swift"
        "$ROOT/RawLabMac/Sources/Geometry/MacCropInteraction.swift"
        "$ROOT/RawLabMac/Sources/Inputs/ParameterValueField.swift"
    )
    RAWLAB_MAC_BRIDGING_HEADER="$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h"
    _rawlab_mac_assign_array "$out_var" "${_sources[@]}"
}

rawlab_mac_render_engine_sources() {
    local out_var="${1:?Pass output array variable name}"
    _rawlab_mac_validate_ident "$out_var"
    source "$ROOT/Shared/tests/hdr-native-sources.sh"
    local _sources=(
        "$ROOT/RawLabMac/Sources/Rendering/Engine.swift"
        "$ROOT/RawLabMac/Sources/Rendering/RenderError.swift"
        "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift"
        "$ROOT/Shared/Native/ProcessingMigrationNative.swift"
        "${HDR_SWIFT_SOURCES[@]}"
        "$ROOT/Shared/HSLNative.swift"
        "$ROOT/Shared/HSLTargetNative.swift"
        "$ROOT/Shared/ToneControlsNative.swift"
        "$ROOT/Shared/AtmosphereNative.swift"
        "$ROOT/Shared/ColorGradingNative.swift"
        "$ROOT/Shared/ToneCurveNative.swift"
    )
    RAWLAB_MAC_BRIDGING_HEADER="$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h"
    _rawlab_mac_assign_array "$out_var" "${_sources[@]}"
}

rawlab_mac_adjustment_native_sources() {
    local out_var="${1:?Pass output array variable name}"
    _rawlab_mac_validate_ident "$out_var"
    local _sources=(
        "$ROOT/RawLabMac/Sources/Adjustments/Adjustments+Native.swift"
        "$ROOT/Shared/HSLNative.swift"
        "$ROOT/Shared/ToneControlsNative.swift"
        "$ROOT/Shared/AtmosphereNative.swift"
        "$ROOT/Shared/ColorGradingNative.swift"
        "$ROOT/Shared/ToneCurveNative.swift"
    )
    RAWLAB_MAC_BRIDGING_HEADER="$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h"
    _rawlab_mac_assign_array "$out_var" "${_sources[@]}"
}

rawlab_mac_swiftc() {
    local has_cache=0 arg
    for arg in "$@"; do
        if [ "$arg" = "-module-cache-path" ]; then
            has_cache=1
            break
        fi
    done
    local cache_flags=()
    local cache_dir="${RAWLAB_TRANSFER_MODULE_CACHE:-${RAWLAB_MAC_MODULE_CACHE:-}}"
    if [ "$has_cache" = 0 ] && [ -n "$cache_dir" ]; then
        mkdir -p "$cache_dir"
        cache_flags=(-module-cache-path "$cache_dir")
    fi
    swiftc -swift-version 5 -sdk "$RAWLAB_MAC_SDK" -target "$RAWLAB_MAC_TARGET" \
        ${cache_flags[@]+"${cache_flags[@]}"} "$@"
}

rawlab_mac_clang() {
    xcrun clang -isysroot "$RAWLAB_MAC_SDK" -target "$RAWLAB_MAC_TARGET" "$@"
}

rawlab_mac_clangxx() {
    xcrun clang++ -isysroot "$RAWLAB_MAC_SDK" -target "$RAWLAB_MAC_TARGET" "$@"
}

# Usage: rawlab_mac_compile_native <full-app|editor-model|render-engine|adjustment-native> <scratch_dir> <output_bin> [--] <extra_args...>
rawlab_mac_compile_native() {
    local profile="${1:?Pass compile profile}"
    local scratch_dir="${2:?Pass SwiftPM scratch directory}"
    local output_bin="${3:?Pass output binary path}"
    shift 3
    if [ "${1:-}" = "--" ]; then
        shift
    fi
    rawlab_mac_native_env
    local _profile_sources=()
    case "$profile" in
        full-app) rawlab_mac_full_app_sources _profile_sources ;;
        editor-model) rawlab_mac_editor_model_sources _profile_sources ;;
        render-engine) rawlab_mac_render_engine_sources _profile_sources ;;
        adjustment-native) rawlab_mac_adjustment_native_sources _profile_sources ;;
        *)
            echo "Unknown compile profile: $profile" >&2
            return 2
            ;;
    esac
    rawlabkit_flags link "$scratch_dir" macos 0
    local _native_link=()
    rawlab_mac_native_link_flags _native_link
    rawlab_mac_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" \
        -import-objc-header "$RAWLAB_MAC_BRIDGING_HEADER" \
        "${_profile_sources[@]}" "$@" "${_native_link[@]}" -o "$output_bin"
}
