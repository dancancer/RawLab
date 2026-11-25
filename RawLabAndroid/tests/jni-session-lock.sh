#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JDK="${JAVA_HOME:-}"
if [ -z "$JDK" ] && command -v /usr/libexec/java_home >/dev/null 2>&1; then
  JDK="$(/usr/libexec/java_home -v 17 2>/dev/null || /usr/libexec/java_home)"
fi
if [ -z "$JDK" ] && command -v javac >/dev/null 2>&1; then
  JDK="$(cd "$(dirname "$(command -v javac)")/.." && pwd)"
fi
: "${JDK:?Set JAVA_HOME to a JDK installation containing jni.h}"

case "$(uname -s)" in
  Darwin) JNI_MD="darwin" ;;
  Linux) JNI_MD="linux" ;;
  *) printf 'Unsupported host OS: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac

TMP="$(mktemp -d /tmp/rawlab-jni-session-lock.XXXXXX)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

LCMS_DIR="$(python3 "$ROOT/lutools/cmake/hdr_sources.py" --portable | tr ';' '\n' | tail -n 1)"
SPNG_DIR="$(python3 "$ROOT/lutools/cmake/hdr_sources.py" --png)"
CC="${CC:-clang}"
"$CC" -O2 -DSPNG_STATIC -I"$SPNG_DIR/spng" -c "$SPNG_DIR/spng/spng.c" -o "$TMP/spng.o"
mkdir -p "$TMP/lcms"
for src in "$LCMS_DIR"/src/*.c; do
  "$CC" -O2 -I"$LCMS_DIR/include" -c "$src" -o "$TMP/lcms/$(basename "$src" .c).o"
done
ar rcs "$TMP/liblcms2.a" "$TMP/lcms"/*.o

CXX="${CXX:-clang++}"
CXXFLAGS=(
  -std=c++17 -O2 -pthread -Wall -Wextra -DSPNG_STATIC
  -I"$SPNG_DIR/spng"
  -I"$ROOT/RawLabAndroid/tests/host_jni"
  -I"$ROOT/RawLabAndroid/app/src/main/cpp"
  -I"$ROOT/lutools/include"
  -I"$LCMS_DIR/include"
  -I"$JDK/include"
  -I"$JDK/include/$JNI_MD"
)
CORE_CXXFLAGS=(
  -std=c++17 -O2 -pthread -Wall -Wextra
  -I"$ROOT/lutools/include"
  -I"$ROOT/lutools/src"
)
"$CXX" "${CORE_CXXFLAGS[@]}" -c "$ROOT/lutools/src/core/photo_geometry.cpp" -o "$TMP/photo_geometry.o"
"$CXX" "${CORE_CXXFLAGS[@]}" -c "$ROOT/lutools/src/core/inspection_overlay.cpp" -o "$TMP/inspection_overlay.o"
"$CXX" "${CORE_CXXFLAGS[@]}" -c "$ROOT/lutools/src/ffi/inspection_c.cpp" -o "$TMP/inspection_c.o"
"$CXX" "${CORE_CXXFLAGS[@]}" -c "$ROOT/lutools/src/core/viewport_pyramid.cpp" -o "$TMP/viewport_pyramid.o"
"$CXX" "${CORE_CXXFLAGS[@]}" -c "$ROOT/lutools/src/ffi/viewport_pyramid_c.cpp" -o "$TMP/viewport_pyramid_c.o"
"$CXX" "${CORE_CXXFLAGS[@]}" -c "$ROOT/lutools/src/core/sony_ptpip.cpp" -o "$TMP/sony_ptpip.o"
"$CXX" "${CORE_CXXFLAGS[@]}" -c "$ROOT/lutools/src/ffi/sony_ptpip_c.cpp" -o "$TMP/sony_ptpip_c.o"
"$CXX" "${CXXFLAGS[@]}" -c "$ROOT/RawLabAndroid/app/src/main/cpp/jni_sdr.cpp" -o "$TMP/jni_sdr.o"
"$CXX" "${CXXFLAGS[@]}" -c "$ROOT/RawLabAndroid/app/src/main/cpp/jni_hdr.cpp" -o "$TMP/jni_hdr.o"
"$CXX" "${CXXFLAGS[@]}" -c "$ROOT/RawLabAndroid/app/src/main/cpp/jni_lens_lut.cpp" -o "$TMP/jni_lens_lut.o"
"$CXX" "${CXXFLAGS[@]}" -c "$ROOT/RawLabAndroid/app/src/main/cpp/jni_inspection.cpp" -o "$TMP/jni_inspection.o"
"$CXX" "${CXXFLAGS[@]}" -c "$ROOT/RawLabAndroid/app/src/main/cpp/jni_viewport.cpp" -o "$TMP/jni_viewport.o"
"$CXX" "${CXXFLAGS[@]}" -c "$ROOT/RawLabAndroid/app/src/main/cpp/jni_camera.cpp" -o "$TMP/jni_camera.o"
"$CXX" "${CXXFLAGS[@]}" -c "$ROOT/RawLabAndroid/tests/jni_session_lock_test.cpp" -o "$TMP/jni_session_lock_test.o"
"$CXX" -std=c++17 -O2 -pthread \
  "$TMP/photo_geometry.o" "$TMP/inspection_overlay.o" "$TMP/inspection_c.o" \
  "$TMP/viewport_pyramid.o" "$TMP/viewport_pyramid_c.o" \
  "$TMP/sony_ptpip.o" "$TMP/sony_ptpip_c.o" \
  "$TMP/jni_sdr.o" "$TMP/jni_hdr.o" "$TMP/jni_lens_lut.o" "$TMP/jni_inspection.o" "$TMP/jni_viewport.o" "$TMP/jni_camera.o" \
  "$TMP/jni_session_lock_test.o" \
  "$TMP/liblcms2.a" "$TMP/spng.o" \
  -lm -lz \
  -o "$TMP/jni_session_lock_test"

"$TMP/jni_session_lock_test"
