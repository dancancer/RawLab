#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
FRAMEWORK_DIR="${1:?Usage: preview-performance.sh framework-dir simulator-uuid raw-path output-dir}"
DEVICE="${2:?Pass an already booted simulator UUID}"
RAW="${3:?Pass an external RAW fixture}"
OUT="${4:?Pass a git-ignored output directory inside this checkout}"
test -f "$RAW" || { echo "Missing RAW fixture: $RAW" >&2; exit 1; }
RAW="$(cd "$(dirname "$RAW")" && pwd)/$(basename "$RAW")"
if [[ "$(basename "$FRAMEWORK_DIR")" == sony2fuji.framework ]]; then
    FRAMEWORK="$FRAMEWORK_DIR"
else
    FRAMEWORK="$FRAMEWORK_DIR/sony2fuji.framework"
fi
test -f "$FRAMEWORK/sony2fuji" || { echo "Missing simulator framework: $FRAMEWORK" >&2; exit 1; }
if [[ -d "$OUT" ]]; then
    shopt -s nullglob dotglob
    CONTENTS=("$OUT"/*)
    shopt -u nullglob dotglob
    if (( ${#CONTENTS[@]} != 0 )); then
        echo "Output directory must be empty; select a new path to preserve earlier measurements." >&2
        exit 1
    fi
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
git -C "$ROOT" check-ignore -q "$OUT/" || {
    echo "Output must be git-ignored in this checkout (for example build/performance/baseline)." >&2
    exit 1
}
PROCESSOR_ROOT="${RAWLAB_PROCESSOR_SOURCE_ROOT:-$ROOT/RawLab/RawLab/Core/RawProcessing}"
PROCESSOR_ROOT="$(cd "$PROCESSOR_ROOT" && pwd)"
PROCESSOR_SOURCES=("$PROCESSOR_ROOT/Sony2FujiProcessor.swift" "$PROCESSOR_ROOT/Errors/ProcessorError.swift" "$PROCESSOR_ROOT/Sony2FujiProcessor+Helpers.swift"
                   "$PROCESSOR_ROOT/Sony2FujiProcessor+Lens.swift")
DEFINES=()
rawlab_ios_make_temp_dir TEMP rawlab-preview-performance
HARNESS="$TEMP/PreviewPerformanceTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.preview-performance preview-performance "$FRAMEWORK"
rawlab_ios_compile_metadata_bridge "$TEMP/bridge.o"
rawlabnative_flags link "$OUT/swiftpm" iphonesimulator 0 types_only
rawlab_ios_sim_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -parse-as-library -O \
    ${DEFINES[@]+"${DEFINES[@]}"} -module-cache-path "$TEMP/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" \
    "$ROOT/Shared/Native/ProcessingMigrationNative.swift" "$ROOT/Shared/HSLTargetNative.swift" \
    "${PROCESSOR_SOURCES[@]}" "$ROOT/RawLab/tests/PreviewPerformanceTests.swift" "$TEMP/bridge.o" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/preview-performance"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
SIMCTL_CHILD_RAWLAB_PERFORMANCE_REFERENCE="${RAWLAB_PERFORMANCE_REFERENCE:-}" \
SIMCTL_CHILD_RAWLAB_PROCESSOR_SOURCE_ROOT="$PROCESSOR_ROOT" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/preview-performance" "$ROOT" "$RAW" "$OUT"
echo "Artifacts: $OUT"
