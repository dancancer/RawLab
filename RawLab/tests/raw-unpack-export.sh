#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/ci/swiftpm-rawlabkit.sh"
source "$ROOT/Shared/tests/hdr-native-sources.sh"
APP="${1:?Pass the built arm64-simulator RawLab.app absolute path}"
DEVICE="${2:?Pass the dedicated simulator UDID}"
RAW="${3:?Pass a real RAW fixture path}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-unpack-export.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
HARNESS="$OUT/RawUnpackExportTests.app"
mkdir -p "$HARNESS/Frameworks"
cp "$APP/Info.plist" "$HARNESS/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.rawlab.tests.raw-unpack-export' \
    -c 'Set CFBundleExecutable raw-unpack-export' "$HARNESS/Info.plist"
cp -R "$APP/Frameworks/sony2fuji.framework" "$HARNESS/Frameworks/"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="${RAWLAB_SIMULATOR_ARCH:-$(uname -m)}-apple-ios18.0-simulator"

cat > "$OUT/unpack_counter.cpp" <<'CPP'
#include <atomic>
#include <cstdint>
#include <string>
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/raw_processor.h"

#define DYLD_INTERPOSE_NAME(_replacement, _replacee, _tag) \
    __attribute__((used)) static struct { \
        const void* replacement; \
        const void* replacee; \
    } _interpose_##_tag __attribute__((section("__DATA,__interpose"))) = { \
        reinterpret_cast<const void*>(_replacement), \
        reinterpret_cast<const void*>(&_replacee) \
    };

namespace {
std::atomic<int32_t> g_bridge_load{0};
std::atomic<int32_t> g_bridge_inspect{0};
std::atomic<int32_t> g_bridge_lens_cpp{0};
std::atomic<int32_t> g_c_inspect_lens{0};
std::atomic<int32_t> g_core_decode{0};
}

extern "C" {
void _ZN9sony2fuji12RAWProcessor8loadFileERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE();
void _ZN9sony2fuji12RAWProcessor8loadFileERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEENS_7X3fModeE();
void _ZN9sony2fuji12RAWProcessor11inspectFileERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE();
void _ZN9sony2fuji12RAWProcessor16readLensMetadataERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEERNS_12LensMetadataE();

void rawlab_counter_reset() {
    g_bridge_load.store(0);
    g_bridge_inspect.store(0);
    g_bridge_lens_cpp.store(0);
    g_c_inspect_lens.store(0);
    g_core_decode.store(0);
}
int32_t rawlab_counter_bridge_load() { return g_bridge_load.load(); }
int32_t rawlab_counter_bridge_inspect() { return g_bridge_inspect.load(); }
int32_t rawlab_counter_bridge_lens_cpp() { return g_bridge_lens_cpp.load(); }
int32_t rawlab_counter_c_inspect_lens() { return g_c_inspect_lens.load(); }
int32_t rawlab_counter_core_decode() { return g_core_decode.load(); }
}

sony2fuji::ErrorCode hook_loadFile(sony2fuji::RAWProcessor* self, const std::string& path) {
    g_bridge_load.fetch_add(1);
    return self->loadFile(path);
}
DYLD_INTERPOSE_NAME(hook_loadFile, _ZN9sony2fuji12RAWProcessor8loadFileERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE, loadFile1)

sony2fuji::ErrorCode hook_loadFileX3f(sony2fuji::RAWProcessor* self, const std::string& path, sony2fuji::X3fMode mode) {
    g_bridge_load.fetch_add(1);
    return self->loadFile(path, mode);
}
DYLD_INTERPOSE_NAME(hook_loadFileX3f, _ZN9sony2fuji12RAWProcessor8loadFileERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEENS_7X3fModeE, loadFile2)

sony2fuji::ErrorCode hook_inspectFile(sony2fuji::RAWProcessor* self, const std::string& path) {
    g_bridge_inspect.fetch_add(1);
    return self->inspectFile(path);
}
DYLD_INTERPOSE_NAME(hook_inspectFile, _ZN9sony2fuji12RAWProcessor11inspectFileERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE, inspectFile)

sony2fuji::ErrorCode hook_readLensMetadata(const std::string& path, sony2fuji::LensMetadata& metadata) {
    g_bridge_lens_cpp.fetch_add(1);
    return sony2fuji::RAWProcessor::readLensMetadata(path, metadata);
}
DYLD_INTERPOSE_NAME(hook_readLensMetadata, _ZN9sony2fuji12RAWProcessor16readLensMetadataERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEERNS_12LensMetadataE, readLensMetadata)

sony2fuji_status hook_inspect_lens(sony2fuji_session* session, const char* input_path,
                                   sony2fuji_lens_report* report, sony2fuji_lens_profile* profiles,
                                   uint32_t capacity, uint32_t* count) {
    g_c_inspect_lens.fetch_add(1);
    return sony2fuji_session_inspect_lens(session, input_path, report, profiles, capacity, count);
}
DYLD_INTERPOSE_NAME(hook_inspect_lens, sony2fuji_session_inspect_lens, inspect_lens)

sony2fuji_status hook_process(sony2fuji_session* session, const sony2fuji_request* request, sony2fuji_buffer* output) {
    const uint64_t before = sony2fuji_session_get_raw_decode_count(session);
    const sony2fuji_status status = sony2fuji_process(session, request, output);
    const uint64_t after = sony2fuji_session_get_raw_decode_count(session);
    if (after > before) {
        g_core_decode.fetch_add(static_cast<int32_t>(after - before));
    }
    return status;
}
DYLD_INTERPOSE_NAME(hook_process, sony2fuji_process, process)

sony2fuji_status hook_create_hsl_probe(sony2fuji_session* session, const sony2fuji_request* request,
                                       uint64_t source_revision, uint64_t request_revision,
                                       sony2fuji_hsl_probe** out_probe) {
    const uint64_t before = sony2fuji_session_get_raw_decode_count(session);
    const sony2fuji_status status = sony2fuji_session_create_hsl_probe(
        session, request, source_revision, request_revision, out_probe);
    const uint64_t after = sony2fuji_session_get_raw_decode_count(session);
    if (after > before) {
        g_core_decode.fetch_add(static_cast<int32_t>(after - before));
    }
    return status;
}
DYLD_INTERPOSE_NAME(hook_create_hsl_probe, sony2fuji_session_create_hsl_probe, create_hsl_probe)
CPP

xcrun --sdk iphonesimulator clang++ -std=c++17 -shared -target "$TARGET" -isysroot "$SDK" \
    -install_name @rpath/libunpack_counter.dylib \
    -I "$ROOT/lutools/include" "$OUT/unpack_counter.cpp" \
    -F "$HARNESS/Frameworks" -framework sony2fuji -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    -o "$HARNESS/Frameworks/libunpack_counter.dylib"

xcrun --sdk iphonesimulator clang++ -std=c++17 -target "$TARGET" -isysroot "$SDK" \
    -I "$ROOT/lutools/include" -c "$ROOT/RawLab/RawLab/Support/RawMetadataBridge.mm" -o "$OUT/bridge.o"

rawlabkit_flags link "$OUT/swiftpm" iphonesimulator 0
xcrun --sdk iphonesimulator swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$OUT/module-cache" \
    -import-objc-header "$ROOT/RawLab/RawLab/Support/RawLab-Bridging-Header.h" \
    -Xcc -I"$ROOT/lutools/include" \
 "$ROOT/Shared/Native/ProcessingMigrationNative.swift" "${HDR_SWIFT_SOURCES[@]}" "$ROOT/Shared/HSLNative.swift" "$ROOT/Shared/HSLTargetNative.swift" "$ROOT/Shared/ToneControlsNative.swift" "$ROOT/Shared/AtmosphereNative.swift" "$ROOT/Shared/ColorGradingNative.swift" "$ROOT/Shared/ToneCurveNative.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift" "$ROOT/RawLab/RawLab/Core/RawProcessing/Errors/ProcessorError.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/RecipeWhiteBalanceCache.swift" \
    "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Lens.swift" \
    "$ROOT/RawLab/RawLab/UI/Preview/PhotoZoomGeometry.swift" "$ROOT/RawLab/RawLab/UI/Preview/ZoomablePhoto.swift" "$ROOT/RawLab/RawLab/UI/Preview/PhotoHSLTargetInput.swift" \
     "$ROOT/RawLab/tests/RawUnpackExportTests.swift" "$OUT/bridge.o" \
    -F "$HARNESS/Frameworks" -L "$HARNESS/Frameworks" -framework sony2fuji -lunpack_counter -lc++ \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$HARNESS/raw-unpack-export"

codesign --force --deep --sign - "$HARNESS" >/dev/null
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$HARNESS/Frameworks/libunpack_counter.dylib" \
    xcrun simctl spawn "$DEVICE" "$HARNESS/raw-unpack-export" "$RAW" "$OUT/work"
