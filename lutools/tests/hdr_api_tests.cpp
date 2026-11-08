#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
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

void autoExposure() {
    Source source;
    source.hdr.assign(256 * 3, .09225f);
    source.sdr.assign(256 * 3, .6f);
    for (auto* buffer : {&source.pair.hdr, &source.pair.sdr}) {
        buffer->width = buffer->height = 16;
        buffer->stride_bytes = 16 * 12;
        buffer->size_bytes = 256 * 12;
    }
    source.pair.hdr.data = source.hdr.data();
    source.pair.sdr.data = source.sdr.data();
    source.pair.native_width = source.pair.native_height = 64;
    source.pair.source_intent = source.pair.render_intent = SONY2FUJI_INTENT_PREVIEW;
    source.pair.is_proxy = 1;
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    float exposure = 9;
    auto meter = [&](float temperature = 6500, float tint = 0) {
        return sony2fuji_hdr_estimate_auto_exposure(&source.pair, temperature, tint, &exposure, &diagnostic);
    };
    check(meter() == SONY2FUJI_STATUS_OK && std::abs(exposure - 1) < 1e-5f,
        "HDR auto exposure did not lift the dark HDR midtones by one stop");
    std::fill(source.hdr.end() - 9, source.hdr.end(), 8);
    check(meter() == SONY2FUJI_STATUS_OK && std::abs(exposure) < 1e-5f,
        "HDR auto exposure darkened a dark image just because it already contains bright highlights");
    std::fill(source.hdr.begin(), source.hdr.end(), .1845f);
    check(meter() == SONY2FUJI_STATUS_OK && exposure == 0,
        "HDR auto exposure changed reference mid-gray");
    std::fill(source.hdr.begin(), source.hdr.end(), .369f);
    check(meter() == SONY2FUJI_STATUS_OK && std::abs(exposure + 1) < 1e-5f,
        "HDR auto exposure did not lower bright midtones by one stop");
    std::fill(source.hdr.begin(), source.hdr.end(), 0);
    check(meter() == SONY2FUJI_STATUS_UNSUPPORTED && std::abs(exposure + 1) < 1e-5f,
        "HDR auto exposure changed the edit when no measurable light exists");
    check(meter(std::numeric_limits<float>::quiet_NaN()) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
        std::abs(exposure + 1) < 1e-5f, "HDR auto exposure accepted invalid white balance");
    check(sony2fuji_hdr_estimate_auto_exposure(nullptr, 6500, 0, &exposure, &diagnostic) ==
        SONY2FUJI_STATUS_INVALID_ARGUMENT && std::abs(exposure + 1) < 1e-5f,
        "HDR auto exposure accepted a missing source");
}

void toneV2(sony2fuji_session* session) {
    constexpr uint32_t width = 1025;
    Source source;
    source.hdr.resize(width * 3);
    source.sdr.resize(width * 3);
    for (uint32_t i = 0; i < width; ++i) {
        const float hdr = std::exp2(-8.f + i / 64.f);
        const float sdr = std::exp2(-8.f + i / 128.f);
        std::fill_n(source.hdr.data() + i * 3, 3, hdr);
        std::fill_n(source.sdr.data() + i * 3, 3, sdr);
    }
    for (auto* buffer : {&source.pair.hdr, &source.pair.sdr}) {
        buffer->width = width;
        buffer->stride_bytes = buffer->size_bytes = width * 12;
    }
    source.pair.hdr.data = source.hdr.data(); source.pair.sdr.data = source.sdr.data();
    source.pair.native_width = width;
    source.pair.source_headroom = 256;
    sony2fuji_hdr_request_v2 settings{};
    settings.base = request();
    settings.base.struct_size = sizeof(settings);
    settings.base.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_TONE_VERSION;
    settings.curve = init<sony2fuji_tone_curve_config>();
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    auto render = [&](sony2fuji_status expected, const auto& verify) {
        auto result = init<sony2fuji_hdr_image_pair_v1>();
        auto status = sony2fuji_hdr_render(session, &source.pair, &settings.base, &result, &diagnostic);
        check(status == expected, "unexpected HDR tone request status");
        if (status == SONY2FUJI_STATUS_OK) {
            verify(static_cast<const float*>(result.hdr.data), static_cast<const float*>(result.sdr.data));
            sony2fuji_hdr_release_pair(&result);
        } else check(!result.owner_token && !result.hdr.data, "invalid HDR tone request produced an image");
    };
    const auto unchanged = [&](const float* hdr, const float* sdr) {
        check(std::memcmp(hdr, source.hdr.data(), width * 12) == 0 &&
            std::memcmp(sdr, source.sdr.data(), width * 12) == 0, "neutral HDR tone changed float pixels");
    };
    render(SONY2FUJI_STATUS_OK, unchanged);
    settings.black_point = 100;
    settings.base.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_VERSION;
    render(SONY2FUJI_STATUS_OK, unchanged);
    settings.base.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_TONE_VERSION;
    for (float black : {-100.f, 100.f}) for (float white : {-100.f, 100.f}) {
        settings.black_point = black; settings.white_point = white;
        render(SONY2FUJI_STATUS_OK, [&](const float* hdr, const float* sdr) {
            for (uint32_t i = 1; i < width; ++i) {
                check(hdr[i * 3] > hdr[(i - 1) * 3], "black/white points reversed HDR grayscale levels");
                check(sdr[i * 3] > sdr[(i - 1) * 3], "black/white points reversed SDR grayscale levels");
            }
            check(std::abs(hdr[0] - source.hdr[0] * std::exp2(black / 50)) < 1e-7f,
                "black point did not change the darkest sample by two stops");
            check(std::abs(hdr[(width - 1) * 3] - 256 * std::exp2(white / 50)) < 1e-3f,
                "white point did not change the brightest sample by two stops");
        });
    }
    settings.black_point = settings.white_point = 0;
    settings.curve_strength = 100;
    render(SONY2FUJI_STATUS_OK, [](const float* hdr, const float* sdr) {
        check(std::abs(hdr[768 * 3] - 32) < 1e-4f && std::abs(sdr[512 * 3] - .03125f) < 1e-6f,
            "HDR S curve did not act above reference white and on the independent SDR base");
    });
    settings.curve_strength = 0;
    settings.curve.mode = SONY2FUJI_CURVE_CUSTOM; settings.curve.count = 3;
    settings.curve.points[0] = {0, 0}; settings.curve.points[1] = {.5, .4375}; settings.curve.points[2] = {1, 1};
    render(SONY2FUJI_STATUS_OK, [](const float* hdr, const float* sdr) {
        check(std::abs(hdr[512 * 3] - .5f) < 1e-6f && std::abs(sdr[1024 * 3] - .5f) < 1e-6f,
            "custom curve did not map reference white to its control point");
        check(hdr[0] == std::exp2(-8.f) && hdr[1024 * 3] == 256, "custom curve changed its endpoints");
        check(hdr[511 * 3] < hdr[512 * 3] && hdr[513 * 3] > hdr[512 * 3] &&
            hdr[513 * 3] - hdr[511 * 3] < .02f, "custom curve jumped at reference white");
    });
    settings.curve.count = 4;
    settings.curve.points[1] = {.25, .5}; settings.curve.points[2] = {.5, .4375};
    settings.curve.points[3] = {1, 1};
    render(SONY2FUJI_STATUS_INVALID_ARGUMENT, unchanged);
    settings.curve.points[1].y = .4;
    settings.white_point = std::numeric_limits<float>::quiet_NaN();
    render(SONY2FUJI_STATUS_INVALID_ARGUMENT, unchanged);
    settings.white_point = 0;
    settings.base.struct_size = sizeof(settings.base);
    render(SONY2FUJI_STATUS_INVALID_ARGUMENT, unchanged);
    settings.base.struct_size = sizeof(settings);
    settings.base.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_LOOK_VERSION + 1;
    render(SONY2FUJI_STATUS_UNSUPPORTED, unchanged);
}

void colorV3(sony2fuji_session* session) {
    Source source;
    std::copy_n(std::array<float, 6>{4, 1.5f, -.2f, .18f, .18f, .18f}.begin(), 6, source.hdr.begin());
    sony2fuji_hdr_request_v3 settings{};
    auto& base = settings.base.base;
    base = request();
    base.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_COLOR_VERSION;
    base.struct_size = sizeof(settings);
    base.quarter_turns = 1;
    settings.base.curve = init<sony2fuji_tone_curve_config>();
    settings.vibrance = 60;
    settings.hsl = init<sony2fuji_hsl_config>();
    settings.grading = init<sony2fuji_color_grading_config>();
    std::fill_n(settings.hsl.hue, SONY2FUJI_HSL_CHANNELS, 80);
    settings.grading.highlights_hue = 210;
    settings.grading.highlights_saturation = 65;
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    auto result = init<sony2fuji_hdr_image_pair_v1>();
    check(sony2fuji_hdr_render(session, &source.pair, &base, &result, &diagnostic) == SONY2FUJI_STATUS_OK,
        "HDR v3 typed render failed");
    float after[3];
    std::memcpy(after, result.hdr.data, sizeof(after));
    sony2fuji_hdr_release_pair(&result);

    sony2fuji_hsl_probe* probe = nullptr;
    check(sony2fuji_hdr_create_hsl_probe(session, &source.pair, &base, 42, 5, &probe, &diagnostic) == SONY2FUJI_STATUS_OK,
        "HDR probe creation failed");
    const std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)> guard(probe, sony2fuji_hsl_probe_destroy);
    auto query = init<sony2fuji_hsl_probe_query>();
    query.source_revision = 42; query.request_revision = 5;
    auto sample = init<sony2fuji_hsl_probe_result>();
    check(sony2fuji_hsl_probe_sample(probe, &query, &sample) == SONY2FUJI_STATUS_OK &&
        sample.availability == SONY2FUJI_HSL_PROBE_AVAILABLE && sample.width == 1 && sample.height == 2 &&
        sample.rgb[0] > 4 && sample.rgb[2] < -.2f && std::memcmp(sample.rgb, after, sizeof(after)) != 0,
        "HDR probe lost signed super-white RGB or sampled after HSL");
    auto beforeColor = settings;
    std::fill_n(beforeColor.hsl.hue, SONY2FUJI_HSL_CHANNELS, 0);
    beforeColor.grading.highlights_saturation = 0;
    result = init<sony2fuji_hdr_image_pair_v1>();
    check(sony2fuji_hdr_render(session, &source.pair, &beforeColor.base.base, &result, &diagnostic) == SONY2FUJI_STATUS_OK,
        "HDR pre-HSL reference render failed");
    check(std::memcmp(sample.rgb, result.hdr.data, sizeof(after)) == 0,
        "HDR probe differs from the rendered pre-HSL stage");
    sony2fuji_hdr_release_pair(&result);
    query.y = 1;
    check(sony2fuji_hsl_probe_sample(probe, &query, &sample) == SONY2FUJI_STATUS_OK &&
        sample.availability == SONY2FUJI_HSL_PROBE_NEAR_GRAY, "HDR probe selected a hue for neutral gray");
    query.request_revision++;
    check(sony2fuji_hsl_probe_sample(probe, &query, &sample) == SONY2FUJI_STATUS_OK &&
        sample.availability == SONY2FUJI_HSL_PROBE_STALE, "HDR probe accepted a stale revision");
    query.request_revision--; query.y = -1;
    check(sony2fuji_hsl_probe_sample(probe, &query, &sample) == SONY2FUJI_STATUS_OK &&
        sample.availability == SONY2FUJI_HSL_PROBE_OUTSIDE, "HDR probe admitted an outside coordinate");

    base.long_edge = 1;
    sony2fuji_hsl_probe* resized = nullptr;
    check(sony2fuji_hdr_create_hsl_probe(session, &source.pair, &base, 42, 6, &resized, &diagnostic) == SONY2FUJI_STATUS_OK,
        "Resized HDR probe creation failed");
    const std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)> resizeGuard(resized, sony2fuji_hsl_probe_destroy);
    query.request_revision = 6; query.x = .5f; query.y = .5f;
    check(sony2fuji_hsl_probe_sample(resized, &query, &sample) == SONY2FUJI_STATUS_OK &&
        sample.width == 1 && sample.height == 1 && sample.availability == SONY2FUJI_HSL_PROBE_AVAILABLE,
        "HDR probe ignored preview size");
    beforeColor.base.base.long_edge = 1;
    result = init<sony2fuji_hdr_image_pair_v1>();
    check(sony2fuji_hdr_render(session, &source.pair, &beforeColor.base.base, &result, &diagnostic) == SONY2FUJI_STATUS_OK,
        "Resized HDR pre-HSL reference render failed");
    check(std::memcmp(sample.rgb, result.hdr.data, sizeof(after)) == 0,
        "HDR probe and render disagree after resizing");
    sony2fuji_hdr_release_pair(&result);

    base.crop_y = .5f; base.crop_height = .5f;
    sony2fuji_hsl_probe* cropped = nullptr;
    check(sony2fuji_hdr_create_hsl_probe(session, &source.pair, &base, 42, 7, &cropped, &diagnostic) == SONY2FUJI_STATUS_OK,
        "Cropped HDR probe creation failed");
    const std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)> cropGuard(cropped, sony2fuji_hsl_probe_destroy);
    query.request_revision = 7;
    check(sony2fuji_hsl_probe_sample(cropped, &query, &sample) == SONY2FUJI_STATUS_OK &&
        sample.width == 1 && sample.height == 1 && sample.availability == SONY2FUJI_HSL_PROBE_NEAR_GRAY &&
        sample.rgb[0] == .18f && sample.rgb[1] == .18f && sample.rgb[2] == .18f,
        "HDR probe sampled outside the cropped canvas");

    base.struct_size = sizeof(sony2fuji_hdr_request_v2);
    sony2fuji_hsl_probe* rejected = probe;
    check(sony2fuji_hdr_create_hsl_probe(session, &source.pair, &base, 42, 6, &rejected, &diagnostic) ==
        SONY2FUJI_STATUS_INVALID_ARGUMENT && rejected == nullptr, "Truncated HDR color request published a probe");
}

void lookV7Probe(sony2fuji_session* session, const char* path) {
    Source source;
    std::copy_n(std::array<float, 6>{2, 1, .25f, .18f, .18f, .18f}.begin(), 6, source.hdr.begin());
    sony2fuji_hdr_request_v7 settings{};
    auto& color = settings.base.base.base.base;
    auto& base = color.base.base;
    base = request();
    base.struct_size = sizeof(settings);
    base.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_LOOK_VERSION;
    base.quarter_turns = 1;
    color.base.curve = init<sony2fuji_tone_curve_config>();
    color.hsl = init<sony2fuji_hsl_config>();
    color.grading = init<sony2fuji_color_grading_config>();
    settings.base.base.effects = init<sony2fuji_photo_effects_config>();
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    auto info = init<sony2fuji_hdr_look_info_v1>();
    check(sony2fuji_hdr_probe_look(path, &info, &diagnostic) == SONY2FUJI_STATUS_OK,
        "HDR probe test look is invalid");

    auto sample = [&] {
        sony2fuji_hsl_probe* probe = nullptr;
        check(sony2fuji_hdr_create_hsl_probe(session, &source.pair, &base, 42, 7, &probe, &diagnostic) == SONY2FUJI_STATUS_OK,
            "HDR v7 probe creation failed");
        const std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)> guard(probe, sony2fuji_hsl_probe_destroy);
        auto query = init<sony2fuji_hsl_probe_query>();
        query.source_revision = 42; query.request_revision = 7;
        auto result = init<sony2fuji_hsl_probe_result>();
        check(sony2fuji_hsl_probe_sample(probe, &query, &result) == SONY2FUJI_STATUS_OK,
            "HDR v7 probe sampling failed");
        return result;
    };
    const auto reference = sample();
    check(reference.availability == SONY2FUJI_HSL_PROBE_AVAILABLE && reference.width == 1 && reference.height == 2,
        "HDR v7 reference probe lost the colored sample or geometry");
    settings.look_path = path;
    std::copy_n(info.sha256, 65, settings.look_sha256);
    for (float strength : {.5f, 1.f, 2.f}) {
        settings.look_strength = strength;
        const auto actual = sample();
        check(actual.availability == SONY2FUJI_HSL_PROBE_AVAILABLE &&
            std::memcmp(actual.rgb, reference.rgb, sizeof(actual.rgb)) == 0 &&
            std::memcmp(actual.hsl, reference.hsl, sizeof(actual.hsl)) == 0,
            "HDR v7 HSL probe sampled after the look");
        auto rendered = init<sony2fuji_hdr_image_pair_v1>();
        check(sony2fuji_hdr_render(session, &source.pair, &base, &rendered, &diagnostic) == SONY2FUJI_STATUS_OK,
            "HDR v7 look render failed");
        const bool changed = std::memcmp(rendered.hdr.data, reference.rgb, sizeof(reference.rgb)) != 0;
        sony2fuji_hdr_release_pair(&rendered);
        check(changed, "HDR v7 probe bypass also removed the look from rendering");
    }
}
}

int main(int argc, char** argv) {
    try {
        static_assert(std::is_standard_layout<sony2fuji_hdr_image_pair_v1>::value);
        static_assert(SONY2FUJI_REQUEST_VERSION == 2);
        static_assert(SONY2FUJI_PIXEL_RGB8 == 0 && SONY2FUJI_INPUT_DISPLAY_BUFFER == 2);
        static_assert(SONY2FUJI_HDR_RGB32F_LINEAR == 1 && SONY2FUJI_HDR_RGB8_SRGB == 2);
        autoExposure();
        sony2fuji_session* session = nullptr;
        check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK && session, "session creation failed");
        toneV2(session);
        colorV3(session);
        for (int i = 1; i < argc; ++i) lookV7Probe(session, argv[i]);
        Source source;
        auto output = init<sony2fuji_hdr_image_pair_v1>();
        auto settings = request();
        auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
        uint32_t nativeWidth=7,nativeHeight=9;
        check(sony2fuji_hdr_geometry_size(8000,6000,&settings,&nativeWidth,&nativeHeight,&diagnostic)==SONY2FUJI_STATUS_OK &&
            nativeWidth==8000 && nativeHeight==6000,"native geometry query lost the original canvas");
        auto cropped=settings; cropped.quarter_turns=1; cropped.crop_width=.5f;
        check(sony2fuji_hdr_geometry_size(8000,6000,&cropped,&nativeWidth,&nativeHeight,&diagnostic)==SONY2FUJI_STATUS_OK &&
            nativeWidth==3000 && nativeHeight==8000,"native geometry query changed core crop/rotation rounding");
        cropped.crop_width=2;
        check(sony2fuji_hdr_geometry_size(8000,6000,&cropped,&nativeWidth,&nativeHeight,&diagnostic)==SONY2FUJI_STATUS_INVALID_ARGUMENT &&
            nativeWidth==3000 && nativeHeight==8000,"invalid geometry query changed output bounds");
        check(sony2fuji_hdr_geometry_size(0,6000,&settings,&nativeWidth,&nativeHeight,&diagnostic)==SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "native geometry query accepted zero dimensions");
        check(sony2fuji_hdr_geometry_size(8000,6000,&settings,nullptr,&nativeHeight,&diagnostic)==SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "native geometry query accepted a null output");
        auto render = [&] { return sony2fuji_hdr_render(session, &source.pair, &settings, &output, &diagnostic); };
        check(render() == SONY2FUJI_STATUS_OK, "float identity render failed");
        check(output.hdr.data != source.pair.hdr.data && output.sdr.data != source.pair.sdr.data && output.owner_token,
            "output did not get independent ownership");
        check(reinterpret_cast<uintptr_t>(output.hdr.data) % 16 == 0, "output is not 16-byte aligned");
        check(std::memcmp(output.hdr.data, source.hdr.data(), 24) == 0 &&
            std::memcmp(output.sdr.data, source.sdr.data(), 24) == 0, "float identity clipped or quantized");
        check(output.decode_revision == 99 && output.source_headroom == 8 && output.hdr.content_headroom > 1,
            "headroom or provenance was lost");
        const std::vector<uint8_t> ownerHdrBefore(static_cast<const uint8_t*>(output.hdr.data),
            static_cast<const uint8_t*>(output.hdr.data) + output.hdr.size_bytes);
        const std::vector<uint8_t> ownerSdrBefore(static_cast<const uint8_t*>(output.sdr.data),
            static_cast<const uint8_t*>(output.sdr.data) + output.sdr.size_bytes);
        auto chained = init<sony2fuji_hdr_image_pair_v1>();
        check(sony2fuji_hdr_render(session,&output,&settings,&chained,&diagnostic)==SONY2FUJI_STATUS_OK,
            "owned output could not be borrowed as a new source");
        check(std::memcmp(output.hdr.data, ownerHdrBefore.data(), ownerHdrBefore.size()) == 0 &&
            std::memcmp(output.sdr.data, ownerSdrBefore.data(), ownerSdrBefore.size()) == 0,
            "published HDR owner was modified by an lvalue render");
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

        // A pair borrowed from an external caller is copied once by readPair,
        // then may be moved through the internal renderer. Neither success nor
        // validation failure may mutate the caller-owned pixels.
        Source borrowed;
        const auto borrowedHdr = borrowed.hdr;
        const auto borrowedSdr = borrowed.sdr;
        auto borrowedOutput = init<sony2fuji_hdr_image_pair_v1>();
        auto borrowedSettings = request();
        check(sony2fuji_hdr_render(session, &borrowed.pair, &borrowedSettings, &borrowedOutput, &diagnostic) == SONY2FUJI_STATUS_OK,
            "borrowed HDR pair render failed");
        check(borrowed.hdr == borrowedHdr && borrowed.sdr == borrowedSdr,
            "borrowed HDR pair was mutated by a successful render");
        sony2fuji_hdr_release_pair(&borrowedOutput);
        borrowedSettings.exposure_ev = 5;
        borrowedOutput = init<sony2fuji_hdr_image_pair_v1>();
        check(sony2fuji_hdr_render(session, &borrowed.pair, &borrowedSettings, &borrowedOutput, &diagnostic) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "invalid borrowed HDR request was accepted");
        check(borrowed.hdr == borrowedHdr && borrowed.sdr == borrowedSdr,
            "borrowed HDR pair was damaged by a failed render");

        sony2fuji_session_destroy(session);
        std::cout << "PASS hdr_api_validation\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
