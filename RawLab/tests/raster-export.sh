#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task-owned simulator UUID}"
RAW="${3:?Pass a private Sony RAW fixture path}"
OUTPUT="${4:?Pass the isolated output directory}"
MODE="${5:-tests}"
rawlab_ios_make_temp_dir OUT rawlab-ios-raster-export
HARNESS="$OUT/RasterExportTests.app"
mkdir -p "$OUTPUT"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.raster-export raster-export "$APP"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o" "" "$OUT/module-cache"
rawlab_ios_core_shared_sources _BASE_SOURCES

cat > "$OUT/raster_counter.cpp" <<'CPP'
#include <atomic>
#include <cstdint>
#include <ImageIO/ImageIO.h>
#include "sony2fuji/ffi/sony2fuji_c.h"

#define DYLD_INTERPOSE_NAME(_replacement, _replacee, _tag) \
    __attribute__((used)) static struct { \
        const void* replacement; \
        const void* replacee; \
    } _interpose_##_tag __attribute__((section("__DATA,__interpose"))) = { \
        reinterpret_cast<const void*>(_replacement), \
        reinterpret_cast<const void*>(&_replacee) \
    };

namespace {
std::atomic<int32_t> g_load_display_image{0};
std::atomic<int32_t> g_cg_full_image{0};
std::atomic<int32_t> g_cg_thumbnail{0};
}

extern "C" {
void rawlab_raster_counter_reset() {
    g_load_display_image.store(0);
    g_cg_full_image.store(0);
    g_cg_thumbnail.store(0);
}
int32_t rawlab_raster_counter_load_display_image() { return g_load_display_image.load(); }
int32_t rawlab_raster_counter_cg_full_image() { return g_cg_full_image.load(); }
int32_t rawlab_raster_counter_cg_thumbnail() { return g_cg_thumbnail.load(); }
}

sony2fuji_status hook_load_display_image(const char* path, sony2fuji_buffer* out_buffer) {
    g_load_display_image.fetch_add(1);
    return sony2fuji_load_display_image(path, out_buffer);
}
DYLD_INTERPOSE_NAME(hook_load_display_image, sony2fuji_load_display_image, load_display_image)

CGImageRef hook_cg_create_image(CGImageSourceRef isrc, size_t index, CFDictionaryRef options) {
    g_cg_full_image.fetch_add(1);
    return CGImageSourceCreateImageAtIndex(isrc, index, options);
}
DYLD_INTERPOSE_NAME(hook_cg_create_image, CGImageSourceCreateImageAtIndex, cg_create_image)

CGImageRef hook_cg_create_thumb(CGImageSourceRef isrc, size_t index, CFDictionaryRef options) {
    g_cg_thumbnail.fetch_add(1);
    return CGImageSourceCreateThumbnailAtIndex(isrc, index, options);
}
DYLD_INTERPOSE_NAME(hook_cg_create_thumb, CGImageSourceCreateThumbnailAtIndex, cg_create_thumb)
CPP

xcrun --sdk iphonesimulator clang++ -std=c++17 -shared -target "$TARGET" -isysroot "$SDK" \
    -install_name @rpath/libraster_counter.dylib \
    -I "$ROOT/lutools/include" "$OUT/raster_counter.cpp" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -framework ImageIO -framework CoreGraphics -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    -o "$HARNESS/Frameworks/libraster_counter.dylib"

SOURCES=()
for file in "${_BASE_SOURCES[@]}"; do
    if [[ "$file" == */RawEditorViewModel+PersistenceAndExport.swift && -n "${RAWLAB_EXPORT_SOURCE:-}" ]]; then
        SOURCES+=("$RAWLAB_EXPORT_SOURCE")
    else
        SOURCES+=("$file")
    fi
done
rawlabnative_flags link "$OUT/swiftpm" iphonesimulator 0 all
rawlab_ios_sim_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/RasterExport/"*.swift "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -L "$HARNESS/Frameworks" -framework sony2fuji -lraster_counter -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/raster-export"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$HARNESS/Frameworks/libraster_counter.dylib" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/raster-export" "$MODE" "$RAW" "$OUTPUT"
echo "Artifacts: $OUTPUT"
