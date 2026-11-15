#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-recipe-probe-stages.XXXXXX")"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

CXX="${CXX:-clang++}"
"$CXX" -std=c++17 -O2 -Wall -Wextra \
  -I"$ROOT/RawLabAndroid/app/src/main/cpp" \
  -I"$ROOT/lutools/include" \
  "$ROOT/RawLabAndroid/tests/recipe_probe_stages_test.cpp" \
  -o "$TMP/recipe_probe_stages_test"

"$TMP/recipe_probe_stages_test"
