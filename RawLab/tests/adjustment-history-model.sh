#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the current built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task-owned simulator UUID}"
if [ "$#" -ge 3 ]; then
    rawlab_ios_make_temp_dir OUT run "$3" keep
    CACHE="$3/module-cache"
else
    rawlab_ios_make_temp_dir OUT rawlab-ios-adjustment-history
    CACHE="$OUT/module-cache"
fi
mkdir -p "$CACHE"
HARNESS="$OUT/AdjustmentHistoryModelTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.adjustment-history-model adjustment-history-model "$APP"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o" "" "$CACHE"
rawlab_ios_core_shared_sources SOURCES

cat > "$OUT/preflight_counter.cpp" <<'CPP'
#include <atomic>
#include <cstdint>
#include <cstring>
#include <unistd.h>
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
std::atomic<int32_t> g_process_calls{0};
std::atomic<int32_t> g_load_display_image{0};
std::atomic<int32_t> g_cg_full_image{0};
std::atomic<int32_t> g_inspect_lens_v2{0};
std::atomic<int32_t> g_inspect_lens_metadata_v2{0};
std::atomic<int32_t> g_look_access_calls{0};
}

extern "C" {
void rawlab_preflight_counter_reset() {
    g_process_calls.store(0);
    g_load_display_image.store(0);
    g_cg_full_image.store(0);
    g_inspect_lens_v2.store(0);
    g_inspect_lens_metadata_v2.store(0);
    g_look_access_calls.store(0);
}
int32_t rawlab_preflight_counter_process() { return g_process_calls.load(); }
int32_t rawlab_preflight_counter_load_display_image() { return g_load_display_image.load(); }
int32_t rawlab_preflight_counter_cg_full_image() { return g_cg_full_image.load(); }
int32_t rawlab_preflight_counter_inspect_lens() { return g_inspect_lens_v2.load(); }
int32_t rawlab_preflight_counter_inspect_lens_metadata() { return g_inspect_lens_metadata_v2.load(); }
int32_t rawlab_preflight_counter_look_access() { return g_look_access_calls.load(); }
}

sony2fuji_status hook_process(sony2fuji_session* session, const sony2fuji_request* request, sony2fuji_buffer* output) {
    g_process_calls.fetch_add(1);
    return sony2fuji_process(session, request, output);
}
DYLD_INTERPOSE_NAME(hook_process, sony2fuji_process, process)

sony2fuji_status hook_session_render(sony2fuji_session* session, const sony2fuji_render_options_v1* options,
                                     const char* edit_state_json, sony2fuji_buffer* output,
                                     sony2fuji_viewport_roi_result* out_roi) {
    g_process_calls.fetch_add(1);
    return sony2fuji_session_render(session, options, edit_state_json, output, out_roi);
}
DYLD_INTERPOSE_NAME(hook_session_render, sony2fuji_session_render, session_render)

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

sony2fuji_status hook_inspect_lens_v2(sony2fuji_session* session, const char* input_path,
                                       sony2fuji_lens_report_v2* report, sony2fuji_lens_profile_v2* profiles,
                                       uint32_t capacity, uint32_t* count) {
    g_inspect_lens_v2.fetch_add(1);
    return sony2fuji_session_inspect_lens_v2(session, input_path, report, profiles, capacity, count);
}
DYLD_INTERPOSE_NAME(hook_inspect_lens_v2, sony2fuji_session_inspect_lens_v2, inspect_lens_v2)

sony2fuji_status hook_inspect_lens_metadata_v2(sony2fuji_session* session, const sony2fuji_lens_metadata* metadata,
                                                sony2fuji_lens_report_v2* report, sony2fuji_lens_profile_v2* profiles,
                                                uint32_t capacity, uint32_t* count) {
    g_inspect_lens_metadata_v2.fetch_add(1);
    return sony2fuji_session_inspect_lens_metadata_v2(session, metadata, report, profiles, capacity, count);
}
DYLD_INTERPOSE_NAME(hook_inspect_lens_metadata_v2, sony2fuji_session_inspect_lens_metadata_v2, inspect_lens_metadata_v2)

int hook_access(const char* path, int amode) {
    if (path && std::strstr(path, "preflight-look-") != nullptr) {
        g_look_access_calls.fetch_add(1);
    }
    return access(path, amode);
}
DYLD_INTERPOSE_NAME(hook_access, access, access)
CPP

xcrun --sdk iphonesimulator clang++ -std=c++17 -shared -target "$TARGET" -isysroot "$SDK" \
    -install_name @rpath/libpreflight_counter.dylib \
    -I "$ROOT/lutools/include" "$OUT/preflight_counter.cpp" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -framework ImageIO -framework CoreGraphics -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    -o "$HARNESS/Frameworks/libpreflight_counter.dylib"
rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
rawlab_ios_sim_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$CACHE" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/AdjustmentHistoryModelTests.swift" "$ROOT/RawLab/tests/IOSQuickPresetModelChecks.swift" "$ROOT/RawLab/tests/IOSBatchFlowModelChecks.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -L "$HARNESS/Frameworks" -framework sony2fuji -lpreflight_counter -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/adjustment-history-model"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_RAWLAB_MASTER_RECIPE_CATALOG="$ROOT/Shared/master-recipes.json" \
SIMCTL_CHILD_RAWLAB_TEST_RAW="${RAWLAB_TEST_RAW:-}" \
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$HARNESS/Frameworks/libpreflight_counter.dylib" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/adjustment-history-model" "$OUT"
if [ "$#" -ge 3 ]; then
    echo "Artifacts: $OUT"
fi
