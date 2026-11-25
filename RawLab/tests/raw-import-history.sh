#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_sim_init
APP="${1:?Pass the current built arm64-simulator RawLab.app path}"
DEVICE="${2:?Pass the task-owned simulator UUID}"
RAW="${3:?Pass a private real RAW fixture path}"
if [ "$#" -ge 4 ]; then
    rawlab_ios_make_temp_dir OUT run "$4" keep
else
    rawlab_ios_make_temp_dir OUT rawlab-ios-raw-history
fi
HARNESS="$OUT/RawImportHistoryTests.app"
rawlab_ios_prepare_sim_app "$HARNESS" com.rawlab.tests.raw-import-history raw-import-history "$APP"
rawlab_ios_compile_metadata_bridge "$OUT/bridge.o" "" "$OUT/module-cache"
rawlab_ios_core_shared_sources SOURCES

cat > "$OUT/import_counter.cpp" <<'CPP'
#include <atomic>
#include <cstdint>
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
std::atomic<int32_t> g_core_decode{0};
std::atomic<int32_t> g_cancelled_status{0};
std::atomic<void (*)(void)> g_on_process{nullptr};
}

extern "C" {
void rawlab_import_counter_reset() {
    g_process_calls.store(0);
    g_core_decode.store(0);
    g_cancelled_status.store(0);
    g_on_process.store(nullptr);
}
int32_t rawlab_import_counter_process_calls() { return g_process_calls.load(); }
int32_t rawlab_import_counter_core_decode() { return g_core_decode.load(); }
int32_t rawlab_import_counter_cancelled_status() { return g_cancelled_status.load(); }
void rawlab_import_counter_set_on_process(void (*callback)(void)) {
    g_on_process.store(callback);
}
}

sony2fuji_status hook_process(sony2fuji_session* session, const sony2fuji_request* request, sony2fuji_buffer* output) {
    g_process_calls.fetch_add(1);
    if (auto cb = g_on_process.exchange(nullptr)) {
        cb();
    }
    const uint64_t before = sony2fuji_session_get_raw_decode_count(session);
    const sony2fuji_status status = sony2fuji_process(session, request, output);
    const uint64_t after = sony2fuji_session_get_raw_decode_count(session);
    if (after > before) {
        g_core_decode.fetch_add(static_cast<int32_t>(after - before));
    }
    if (status == SONY2FUJI_STATUS_CANCELLED) {
        g_cancelled_status.fetch_add(1);
    }
    return status;
}
DYLD_INTERPOSE_NAME(hook_process, sony2fuji_process, process)

sony2fuji_status hook_session_render(sony2fuji_session* session, const sony2fuji_render_options_v1* options,
                                     const char* edit_state_json, sony2fuji_buffer* output,
                                     sony2fuji_viewport_roi_result* out_roi) {
    g_process_calls.fetch_add(1);
    if (auto cb = g_on_process.exchange(nullptr)) {
        cb();
    }
    const uint64_t before = sony2fuji_session_get_raw_decode_count(session);
    const sony2fuji_status status = sony2fuji_session_render(session, options, edit_state_json, output, out_roi);
    const uint64_t after = sony2fuji_session_get_raw_decode_count(session);
    if (after > before) {
        g_core_decode.fetch_add(static_cast<int32_t>(after - before));
    }
    if (status == SONY2FUJI_STATUS_CANCELLED) {
        g_cancelled_status.fetch_add(1);
    }
    return status;
}
DYLD_INTERPOSE_NAME(hook_session_render, sony2fuji_session_render, session_render)
CPP

xcrun --sdk iphonesimulator clang++ -std=c++17 -shared -target "$TARGET" -isysroot "$SDK" \
    -install_name @rpath/libimport_counter.dylib \
    -I "$ROOT/lutools/include" "$OUT/import_counter.cpp" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    -o "$HARNESS/Frameworks/libimport_counter.dylib"

rawlabnative_flags link "$OUT/swiftpm" iphonesimulator 0 all
rawlab_ios_sim_swiftc "${RAWLABNATIVE_SWIFTC_FLAGS[@]}" -O \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" -Xcc -I"$ROOT/lutools/include" \
    "${SOURCES[@]}" "$ROOT/RawLab/tests/RawImportHistoryTests.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -L "$HARNESS/Frameworks" -framework sony2fuji -limport_counter -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/raw-import-history"
codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$HARNESS/Frameworks/libimport_counter.dylib" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/raw-import-history" "$RAW" "$OUT"
if [ "$#" -ge 4 ]; then
    echo "Artifacts: $OUT"
fi
