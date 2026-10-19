#!/bin/bash
# Isolate dependency binaries by minimum OS and architecture; share verified archives only.
ARCH="${RAWLAB_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported Mac architecture: $ARCH" >&2; return 2 ;; esac
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
if [[ ! "$MACOSX_DEPLOYMENT_TARGET" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Invalid macOS deployment target: $MACOSX_DEPLOYMENT_TARGET" >&2
    return 2
fi
RAWLAB_DEPS_BASE="$ROOT/build/macos-deps/$MACOSX_DEPLOYMENT_TARGET"
RAWLAB_DEPENDENCY_PREFIX="${RAWLAB_DEPENDENCY_PREFIX:-$RAWLAB_DEPS_BASE/$ARCH/install}"
RAWLAB_LENS_BASE="$ROOT/build/lensfun/$MACOSX_DEPLOYMENT_TARGET"
RAWLAB_LENS_PREFIX="$RAWLAB_LENS_BASE/$ARCH/install"
if [ -z "${RAWLAB_SOURCE_CACHE:-}" ]; then
    COMMON_GIT_DIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    SHARED_ROOT="$ROOT"
    if [ -n "$COMMON_GIT_DIR" ]; then SHARED_ROOT="$(dirname "$COMMON_GIT_DIR")"; fi
    RAWLAB_SOURCE_CACHE="$SHARED_ROOT/.cache/shared/macos-sources"
fi
export ARCH MACOSX_DEPLOYMENT_TARGET RAWLAB_DEPS_BASE RAWLAB_DEPENDENCY_PREFIX
export RAWLAB_LENS_BASE RAWLAB_LENS_PREFIX RAWLAB_SOURCE_CACHE
export PKG_CONFIG_PATH="$RAWLAB_LENS_PREFIX/lib/pkgconfig:$RAWLAB_DEPENDENCY_PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

rawlab_libraw_patch_fingerprint() {
    (
        cd "$ROOT"
        shasum -a 256 RawLabMac/build-env.sh RawLabMac/build-dependencies.sh \
            lutools/cmake/libraw/CMakeLists.txt lutools/cmake/patch-libraw.cmake \
            lutools/third_party/rawspeed-camera-calibration.inc \
            lutools/third_party/nikon_he/* | shasum -a 256 | awk '{print $1}'
    )
}

rawlab_libraw_patch_current() {
    local stamp="$RAWLAB_DEPENDENCY_PREFIX/share/rawlab/libraw-patch.sha256"
    [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(rawlab_libraw_patch_fingerprint)" ]
}

rawlab_macos_version_at_most() {
    local actual="${1:-}" required="${2:-}" index actual_part required_part
    local -a actual_parts required_parts
    [[ "$actual" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || return 1
    [[ "$required" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || return 1
    IFS=. read -r -a actual_parts <<< "$actual"
    IFS=. read -r -a required_parts <<< "$required"
    for index in 0 1 2; do
        actual_part="${actual_parts[index]:-0}"
        required_part="${required_parts[index]:-0}"
        if ((10#$actual_part < 10#$required_part)); then return 0; fi
        if ((10#$actual_part > 10#$required_part)); then return 1; fi
    done
    return 0
}

rawlab_fetch() {
    local archive="$1" checksum="$2" url="$3" directory="$4"
    local cached="$RAWLAB_SOURCE_CACHE/$archive" temporary
    mkdir -p "$RAWLAB_SOURCE_CACHE" "$SOURCES"
    if [ ! -f "$cached" ]; then
        temporary="$cached.part.$$"
        if ! curl -fL --retry 2 "$url" -o "$temporary"; then rm -f "$temporary"; return 1; fi
        if ! printf '%s  %s\n' "$checksum" "$temporary" | shasum -a 256 -c -; then
            rm -f "$temporary"
            return 1
        fi
        mv "$temporary" "$cached"
    fi
    printf '%s  %s\n' "$checksum" "$cached" | shasum -a 256 -c - || return 1
    if [ ! -e "$SOURCES/$archive" ]; then ln -s "$cached" "$SOURCES/$archive"; fi
    if [ ! -d "$SOURCES/$directory" ]; then tar -xf "$cached" -C "$SOURCES"; fi
}
