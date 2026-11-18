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
"$CXX" -std=c++17 -O2 -pthread -Wall -Wextra -DSPNG_STATIC \
  -I"$SPNG_DIR/spng" \
  -I"$ROOT/RawLabAndroid/tests/host_jni" \
  -I"$ROOT/RawLabAndroid/app/src/main/cpp" \
  -I"$ROOT/lutools/include" \
  -I"$ROOT/lutools/src" \
  -I"$LCMS_DIR/include" \
  -I"$JDK/include" \
  -I"$JDK/include/$JNI_MD" \
  "$ROOT/RawLabAndroid/tests/jni_session_lock_test.cpp" \
  "$ROOT/lutools/src/core/jpeg_mpf.cpp" \
  "$TMP/liblcms2.a" "$TMP/spng.o" \
  -lm -lz \
  -o "$TMP/jni_session_lock_test"

"$TMP/jni_session_lock_test"
