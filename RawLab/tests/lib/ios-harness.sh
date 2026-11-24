#!/bin/bash
# Shared host/simulator SDK, target, source-set, bridge, bundle, and temp-dir helpers for iOS tests.
# Pure definitions at source time so cross-platform contract tests can resolve source lists
# without Xcode/xcrun.

_RAWLAB_IOS_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [ -z "${ROOT:-}" ]; then
    ROOT="$_RAWLAB_IOS_LIB_ROOT"
fi

_RAWLAB_IOS_TEMP_DIRS=()

rawlab_ios_cleanup_temp_dirs() {
    local dir
    for dir in ${_RAWLAB_IOS_TEMP_DIRS[@]+"${_RAWLAB_IOS_TEMP_DIRS[@]}"}; do
        rm -rf "$dir"
    done
}

_rawlab_ios_validate_ident() {
    case "${1:-}" in
        ''|[0-9]*|*[!A-Za-z0-9_]*)
            echo "Invalid shell variable name: ${1:-}" >&2
            return 2
            ;;
    esac
}

# Usage: rawlab_ios_make_temp_dir VAR_NAME [prefix] [base_dir] [keep]
rawlab_ios_make_temp_dir() {
    local var_name="${1:?Pass output variable name}"
    local prefix="${2:-rawlab-ios-test}"
    local base="${3:-${RAWLAB_TEST_TMP_DIR:-${TMPDIR:-/tmp}}}"
    local keep="${4:-}"
    local dir
    _rawlab_ios_validate_ident "$var_name"
    base="${base%/}"
    : "${base:=/}"
    mkdir -p "$base"
    dir="$(mktemp -d "$base/${prefix}.XXXXXX")"
    if [ "$keep" != "keep" ]; then
        _RAWLAB_IOS_TEMP_DIRS+=("$dir")
        if [ -z "$(trap -p EXIT)" ]; then
            trap rawlab_ios_cleanup_temp_dirs EXIT
        fi
    fi
    printf -v "$var_name" '%s' "$dir"
}

rawlab_ios_host_init() {
    source "$ROOT/scripts/ci/apple-sdk-env.sh"
    if [ -z "${DEVELOPER_DIR:-}" ] && command -v xcode-select >/dev/null 2>&1; then
        DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
        if [ -n "$DEVELOPER_DIR" ]; then
            export DEVELOPER_DIR
        fi
    fi
    RAWLAB_IOS_HOST_SDK="$(rawlab_mac_sdk_path)"
    SDK="$RAWLAB_IOS_HOST_SDK"
    RAWLAB_IOS_HOST_TARGET="$(rawlab_mac_target)"
    export RAWLAB_IOS_HOST_SDK RAWLAB_IOS_HOST_TARGET
    source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
}

rawlab_ios_sim_init() {
    if [ -z "${DEVELOPER_DIR:-}" ] && command -v xcode-select >/dev/null 2>&1; then
        DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
        if [ -n "$DEVELOPER_DIR" ]; then
            export DEVELOPER_DIR
        fi
    fi
    RAWLAB_IOS_SIM_SDK="${SIM_SDK:-$(env -u SDKROOT xcrun --sdk iphonesimulator --show-sdk-path)}"
    [ -n "$RAWLAB_IOS_SIM_SDK" ] || return 1
    SDK="$RAWLAB_IOS_SIM_SDK"
    SIM_SDK="$RAWLAB_IOS_SIM_SDK"
    RAWLAB_IOS_SIM_TARGET="${RAWLAB_SIMULATOR_ARCH:-$(uname -m)}-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-18.0}-simulator"
    TARGET="$RAWLAB_IOS_SIM_TARGET"
    export RAWLAB_IOS_SIM_SDK RAWLAB_IOS_SIM_TARGET
    source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
}

_rawlab_ios_assign_array() {
    local out_var="$1"
    shift
    _rawlab_ios_validate_ident "$out_var"
    if [ "$#" -eq 0 ]; then
        echo "Source resolver produced empty list for $out_var" >&2
        return 1
    fi
    local _items=("$@")
    eval "$out_var=(\"\${_items[@]}\")"
}

# Usage: rawlab_ios_core_shared_sources VAR_NAME [dir1 dir2 ...]
rawlab_ios_core_shared_sources() {
    local out_var="${1:?Pass output array variable name}"
    shift
    _rawlab_ios_validate_ident "$out_var"
    local _dirs=("$@")
    if [ "${#_dirs[@]}" -eq 0 ]; then
        _dirs=("$ROOT/RawLab/RawLab/Core" "$ROOT/Shared")
    fi
    local _sources=()
    local _src
    while IFS= read -r -d '' _src; do
        _sources+=("$_src")
    done < <(find "${_dirs[@]}" -type f -name '*.swift' ! -path '*/tests/*' ! -path '*/RawLabKit/*' ! -path '*/RawLabInspectionNative/*' ! -path '*/RawLabNative/*' ! -path '*/RawLabNativeTypes/*' -print0 | LC_ALL=C sort -z)
    _rawlab_ios_assign_array "$out_var" "${_sources[@]}"
}

# Usage: rawlab_ios_processor_export_sources VAR_NAME [core|hdr|full]
rawlab_ios_processor_export_sources() {
    local out_var="${1:?Pass output array variable name}"
    local mode="${2:-full}"
    _rawlab_ios_validate_ident "$out_var"
    source "$ROOT/Shared/tests/hdr-native-sources.sh"
    local _sources=(
        "$ROOT/Shared/Native/ProcessingMigrationNative.swift"
        "$ROOT/Shared/HSLTargetNative.swift"
        "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift"
        "$ROOT/RawLab/RawLab/Core/RawProcessing/Errors/ProcessorError.swift"
        "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift"
        "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Lens.swift"
    )
    case "$mode" in
        core) ;;
        hdr)
            _sources+=("${HDR_SWIFT_SOURCES[@]}")
            ;;
        full)
            _sources+=(
                "${HDR_SWIFT_SOURCES[@]}"
                "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift"
                "$ROOT/RawLab/RawLab/UI/Preview/ZoomablePhoto.swift"
                "$ROOT/RawLab/RawLab/UI/Preview/PhotoHSLTargetInput.swift"
            )
            ;;
        *)
            echo "Unknown processor export source mode: $mode" >&2
            return 2
            ;;
    esac
    _rawlab_ios_assign_array "$out_var" "${_sources[@]}"
}

# Usage: rawlab_ios_camera_sources VAR_NAME [core_only|full]
rawlab_ios_camera_sources() {
    local out_var="${1:?Pass output array variable name}"
    local mode="${2:-full}"
    _rawlab_ios_validate_ident "$out_var"
    local _core=(
        "$ROOT/RawLab/RawLab/Core/Camera/CameraProtocol.swift"
        "$ROOT/RawLab/RawLab/Core/Camera/CameraPTPClient.swift"
        "$ROOT/RawLab/RawLab/Core/Camera/CameraNetwork.swift"
        "$ROOT/RawLab/RawLab/Core/Camera/SonyCameraSession.swift"
        "$ROOT/RawLab/RawLab/Core/Camera/CameraIncrementalImport.swift"
        "$ROOT/RawLab/RawLab/Core/Camera/CameraJPEGProcessing.swift"
        "$ROOT/RawLab/RawLab/Core/Camera/CameraOriginalStore.swift"
        "$ROOT/RawLab/RawLab/Core/Batch/Storage/ExportEvidenceStore.swift"
        "$ROOT/RawLab/RawLab/Core/Camera/CameraWorkspaceBackend.swift"
        "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraController.swift"
    )
    local _sources=()
    case "$mode" in
        core_only)
            _sources=("${_core[@]}")
            ;;
        full)
            _sources=(
                "$ROOT/RawLab/RawLab/UI/Export/ExportSizePicker.swift"
                "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift"
                "${_core[@]}"
                "$ROOT/RawLab/RawLab/Core/Camera/IOSCameraConnection.swift"
                "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraIncrementalImport.swift"
                "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraBrowser.swift"
                "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraTether.swift"
                "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraWorkspace.swift"
            )
            ;;
        *)
            echo "Unknown camera source mode: $mode" >&2
            return 2
            ;;
    esac
    _rawlab_ios_assign_array "$out_var" "${_sources[@]}"
}

# Usage: rawlab_ios_compile_metadata_bridge OUT_OBJ [bridge_mm] [module_cache_dir]
rawlab_ios_compile_metadata_bridge() {
    local out_obj="${1:?Pass output .o path}"
    local bridge_mm="${2:-$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm}"
    local cache_dir="${3:-}"
    local cache_flags=()
    if [ -n "$cache_dir" ]; then
        mkdir -p "$cache_dir"
        cache_flags=("-fmodules-cache-path=$cache_dir")
    fi
    xcrun --sdk iphonesimulator clang++ -std=c++17 \
        -target "$RAWLAB_IOS_SIM_TARGET" -isysroot "$RAWLAB_IOS_SIM_SDK" \
        ${cache_flags[@]+"${cache_flags[@]}"} \
        -I "$ROOT/lutools/include" -c "$bridge_mm" -o "$out_obj"
}

# Usage: rawlab_ios_prepare_sim_app HARNESS_DIR BUNDLE_ID EXEC_NAME APP_OR_FRAMEWORK
rawlab_ios_prepare_sim_app() {
    local harness_dir="${1:?Pass harness .app directory}"
    local bundle_id="${2:?Pass bundle identifier}"
    local exec_name="${3:?Pass executable name}"
    local source_bundle="${4:?Pass RawLab.app or sony2fuji.framework}"
    mkdir -p "$harness_dir/Frameworks"
    if [[ "$(basename "$source_bundle")" == *.framework ]]; then
        cp -R "$source_bundle" "$harness_dir/Frameworks/"
        python3 - "$harness_dir" "$bundle_id" "$exec_name" <<'PY'
import pathlib, plistlib, sys
app, bundle_id, exec_name = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
plistlib.dump({
    "CFBundleIdentifier": bundle_id,
    "CFBundleExecutable": exec_name,
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "MinimumOSVersion": "18.0",
    "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
    "UIDeviceFamily": [1, 2],
}, (app / "Info.plist").open("wb"))
PY
    else
        cp "$source_bundle/Info.plist" "$harness_dir/Info.plist"
        /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $bundle_id" \
            -c "Set CFBundleExecutable $exec_name" "$harness_dir/Info.plist"
        cp -R "${RAWLAB_TEST_FRAMEWORK:-$source_bundle/Frameworks/sony2fuji.framework}" "$harness_dir/Frameworks/"
    fi
}

rawlab_ios_sim_swiftc() {
    local has_cache=0 arg
    for arg in "$@"; do
        if [ "$arg" = "-module-cache-path" ]; then
            has_cache=1
            break
        fi
    done
    local cache_flags=()
    local cache_dir="${RAWLAB_TRANSFER_MODULE_CACHE:-${RAWLAB_IOS_MODULE_CACHE:-}}"
    if [ "$has_cache" = 0 ] && [ -n "$cache_dir" ]; then
        mkdir -p "$cache_dir"
        cache_flags=(-module-cache-path "$cache_dir")
    fi
    xcrun --sdk iphonesimulator swiftc -swift-version 5 \
        -sdk "$RAWLAB_IOS_SIM_SDK" -target "$RAWLAB_IOS_SIM_TARGET" \
        ${cache_flags[@]+"${cache_flags[@]}"} "$@"
}

rawlab_ios_host_swiftc() {
    local has_cache=0 arg
    for arg in "$@"; do
        if [ "$arg" = "-module-cache-path" ]; then
            has_cache=1
            break
        fi
    done
    local cache_flags=()
    local cache_dir="${RAWLAB_TRANSFER_MODULE_CACHE:-${RAWLAB_IOS_MODULE_CACHE:-}}"
    if [ "$has_cache" = 0 ] && [ -n "$cache_dir" ]; then
        mkdir -p "$cache_dir"
        cache_flags=(-module-cache-path "$cache_dir")
    fi
    swiftc -swift-version 5 \
        -sdk "$RAWLAB_IOS_HOST_SDK" -target "$RAWLAB_IOS_HOST_TARGET" \
        ${cache_flags[@]+"${cache_flags[@]}"} "$@"
}
