#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <vector>

namespace {
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
template<class T> T init() { T value{}; value.version = 1; value.struct_size = sizeof(T); return value; }

sony2fuji_hdr_request_v1 request() {
    auto value = init<sony2fuji_hdr_request_v1>();
    value.hdr_processing_version = 1;
    value.temperature = 6500;
    value.crop_width = value.crop_height = 1;
    value.intent = SONY2FUJI_INTENT_FINAL;
    return value;
}

struct Source {
    std::vector<float> hdr{-.1f,.18f,1,2,4,8};
    std::vector<float> sdr{-.1f,.18f,1,1.25f,.4f,.8f};
    sony2fuji_hdr_image_pair_v1 pair = init<sony2fuji_hdr_image_pair_v1>();
    Source() {
        for (auto* buffer : {&pair.hdr, &pair.sdr}) {
            *buffer = init<sony2fuji_hdr_buffer_v1>();
            buffer->width = 2; buffer->height = 1; buffer->stride_bytes = 24;
            buffer->size_bytes = 24;
            buffer->pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
            buffer->color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
        }
        pair.hdr.data = hdr.data(); pair.sdr.data = sdr.data();
        pair.native_width = 2; pair.native_height = 1;
        pair.orientation_applied = 1;
        pair.source_intent = pair.render_intent = SONY2FUJI_INTENT_FINAL;
        pair.decode_revision = 99;
        pair.source_headroom = 8; pair.source_headroom_kind = SONY2FUJI_HDR_HEADROOM_DECLARED;
    }
};
}

int main() {
    try {
        static_assert(std::is_standard_layout<sony2fuji_hdr_image_pair_v1>::value);
        static_assert(SONY2FUJI_REQUEST_VERSION == 2);
        static_assert(SONY2FUJI_PIXEL_RGB8 == 0 && SONY2FUJI_INPUT_DISPLAY_BUFFER == 2);
        static_assert(SONY2FUJI_HDR_RGB32F_LINEAR == 1 && SONY2FUJI_HDR_RGB8_SRGB == 2);
        sony2fuji_session* session = nullptr;
        check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK && session, "session creation failed");
        Source source;
        auto output = init<sony2fuji_hdr_image_pair_v1>();
        auto settings = request();
        auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
        auto render = [&] { return sony2fuji_hdr_render(session, &source.pair, &settings, &output, &diagnostic); };
        check(render() == SONY2FUJI_STATUS_OK, "float identity render failed");
        check(output.hdr.data != source.pair.hdr.data && output.sdr.data != source.pair.sdr.data && output.owner_token,
            "output did not get independent ownership");
        check(reinterpret_cast<uintptr_t>(output.hdr.data) % 16 == 0, "output is not 16-byte aligned");
        check(std::memcmp(output.hdr.data, source.hdr.data(), 24) == 0 &&
            std::memcmp(output.sdr.data, source.sdr.data(), 24) == 0, "float identity clipped or quantized");
        check(output.decode_revision == 99 && output.source_headroom == 8 && output.hdr.content_headroom > 1,
            "headroom or provenance was lost");
        auto chained = init<sony2fuji_hdr_image_pair_v1>();
        check(sony2fuji_hdr_render(session,&output,&settings,&chained,&diagnostic)==SONY2FUJI_STATUS_OK,
            "owned output could not be borrowed as a new source");
        sony2fuji_hdr_release_pair(&chained);
        auto copy = output;
        sony2fuji_hdr_release_pair(&copy);
        chained = init<sony2fuji_hdr_image_pair_v1>();
        check(sony2fuji_hdr_render(session,&output,&settings,&chained,&diagnostic)==SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "released copied owner was read again");
        sony2fuji_hdr_release_pair(&output); sony2fuji_hdr_release_pair(&output);
        check(output.version == 0 && !output.hdr.data && !output.owner_token, "release did not clear the pair");
        auto reset = [&] { output = init<sony2fuji_hdr_image_pair_v1>(); };
        reset(); settings.version = 2;
        check(render() == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION,
            "unknown request version not diagnosed");
        check(!output.hdr.data && output.version == 1, "failure output was not empty");
        settings = request(); reset(); source.pair.hdr.stride_bytes = 23;
        check(render() == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.field == SONY2FUJI_HDR_FIELD_HDR_BUFFER,
            "invalid stride not diagnosed");
        source.pair.hdr.stride_bytes = 24;
        reset(); source.hdr[0] = std::numeric_limits<float>::quiet_NaN();
        check(render() == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_NONFINITE,
            "NaN input accepted");
        source.hdr[0] = -.1f;
        reset(); source.pair.is_proxy = 1;
        check(render() == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_PREVIEW_SOURCE,
            "FINAL accepted a proxy source");
        source.pair.is_proxy = 0;
        check(sony2fuji_hdr_render(session, &source.pair, &settings, &source.pair, &diagnostic) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "source/result alias accepted");
        check(source.pair.hdr.data == source.hdr.data(), "alias error mutated input");
        reset(); source.pair.hdr.data=output.source_sha256;
        check(render()==SONY2FUJI_STATUS_INVALID_ARGUMENT,"result structure overlapped borrowed input pixels");
        source.pair.hdr.data=source.hdr.data();
        reset();
        check(sony2fuji_hdr_render(nullptr, &source.pair, &settings, &output, &diagnostic) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "NULL session accepted");
        auto gpu = init<sony2fuji_gpu_config>(); gpu.mode = SONY2FUJI_GPU_FORCE;
        check(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK, "GPU setup failed");
        reset(); check(render() == SONY2FUJI_STATUS_UNSUPPORTED, "GPU Force silently ran CPU");
        gpu.mode = SONY2FUJI_GPU_AUTO; sony2fuji_session_set_gpu_config(session, &gpu);
        reset(); check(render() == SONY2FUJI_STATUS_OK, "GPU Auto did not use CPU fallback");
        sony2fuji_hdr_release_pair(&output);
        struct Extended { sony2fuji_hdr_request_v1 prefix; uint64_t tail = 0x123456789abcdef0; } extended;
        extended.prefix = request(); extended.prefix.struct_size = sizeof(extended);
        reset(); check(sony2fuji_hdr_render(session, &source.pair, &extended.prefix, &output, &diagnostic) == SONY2FUJI_STATUS_OK,
            "larger v1 prefix was rejected");
        check(extended.tail == 0x123456789abcdef0, "extension tail changed");
        sony2fuji_hdr_release_pair(&output);
        source.pair.source_headroom=0; source.pair.source_headroom_kind=SONY2FUJI_HDR_HEADROOM_UNKNOWN;
        reset(); check(render()==SONY2FUJI_STATUS_OK && output.source_headroom==0 &&
            output.source_headroom_kind==SONY2FUJI_HDR_HEADROOM_UNKNOWN,"unknown source headroom was invented");
        sony2fuji_hdr_release_pair(&output);
        source.pair.source_headroom=2;
        reset(); check(render()==SONY2FUJI_STATUS_INVALID_ARGUMENT,"unknown headroom accepted a declared value");
        source.pair.source_headroom=8; source.pair.source_headroom_kind=SONY2FUJI_HDR_HEADROOM_DECLARED;
        std::vector<uint8_t> encoded{0,128,255,255,64,0};
        source.pair.sdr.data=encoded.data(); source.pair.sdr.pixel_format=SONY2FUJI_HDR_RGB8_SRGB;
        source.pair.sdr.color_encoding=SONY2FUJI_HDR_DISPLAY_SRGB; source.pair.sdr.stride_bytes=6; source.pair.sdr.size_bytes=6;
        reset(); check(render()==SONY2FUJI_STATUS_OK,"tagged SDR RGB8 buffer rejected");
        const auto* linear=static_cast<const float*>(output.sdr.data);
        check(linear[0]==0 && std::abs(linear[1]-.2158605f)<1e-6f && linear[2]==1 &&
            linear[3]==1 && std::abs(linear[4]-.05126946f)<1e-6f,"SDR RGB8 transfer was reinterpreted as linear");
        sony2fuji_hdr_release_pair(&output);
        source.pair.sdr.data=source.sdr.data(); source.pair.sdr.pixel_format=SONY2FUJI_HDR_RGB32F_LINEAR;
        source.pair.sdr.color_encoding=SONY2FUJI_HDR_LINEAR_SRGB; source.pair.sdr.stride_bytes=24; source.pair.sdr.size_bytes=24;
        struct ExtendedPair { sony2fuji_hdr_image_pair_v1 prefix; uint64_t tail=0x123456789abcdef0; } extra;
        extra.prefix=init<sony2fuji_hdr_image_pair_v1>(); extra.prefix.struct_size=sizeof(extra);
        check(sony2fuji_hdr_render(session,&source.pair,&settings,&extra.prefix,&diagnostic)==SONY2FUJI_STATUS_OK &&
            extra.prefix.struct_size==sizeof(extra) && extra.tail==0x123456789abcdef0,"larger output prefix or tail was changed");
        sony2fuji_hdr_release_pair(&extra.prefix);
        check(extra.tail==0,"release retained caller extension storage");
        reset(); settings.long_edge=1;
        check(render()==SONY2FUJI_STATUS_OK && output.hdr.width==1,"FINAL resize failed");
        auto resized=output; output=init<sony2fuji_hdr_image_pair_v1>(); settings.long_edge=0;
        check(sony2fuji_hdr_render(session,&resized,&settings,&output,&diagnostic)==SONY2FUJI_STATUS_INVALID_ARGUMENT &&
            diagnostic.reason==SONY2FUJI_HDR_REASON_PREVIEW_SOURCE,"reduced result became a complete FINAL source");
        sony2fuji_hdr_release_pair(&resized);
        // Padding is legal; size_bytes only needs to reach the final row's pixels.
        std::vector<float> padded{-.1f,.18f,1,100,100,100,2,4,8};
        source.pair.hdr.width = source.pair.sdr.width = 1;
        source.pair.hdr.height = source.pair.sdr.height = 2;
        source.pair.native_width=1; source.pair.native_height=2;
        source.pair.hdr.stride_bytes = source.pair.sdr.stride_bytes = 24;
        source.pair.hdr.size_bytes = source.pair.sdr.size_bytes = 36;
        source.pair.hdr.data = source.pair.sdr.data = padded.data();
        reset(); check(render() == SONY2FUJI_STATUS_OK, "row padding was not supported");
        check(static_cast<float*>(output.hdr.data)[3] == 2, "row padding was read as pixels");
        sony2fuji_hdr_release_pair(&output);
        sony2fuji_session_destroy(session);
        std::cout << "PASS hdr_api_validation\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
