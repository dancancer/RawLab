#include "test_harness.h"
#include "sony2fuji/edit_recipe.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <functional>
#include <initializer_list>
#include <memory>
#include <string>
#include <vector>

namespace {

using rawlab::test::require;

struct SessionDeleter {
    void operator()(sony2fuji_session* s) const {
        if (s) sony2fuji_session_destroy(s);
    }
};
using SessionPtr = std::unique_ptr<sony2fuji_session, SessionDeleter>;

struct BufferGuard {
    sony2fuji_buffer buf{};
    ~BufferGuard() { sony2fuji_release_buffer(&buf); }
    void reset() { sony2fuji_release_buffer(&buf); }
};

struct HdrPairGuard {
    sony2fuji_hdr_image_pair_v1 pair{};
    HdrPairGuard() {
        pair.version = SONY2FUJI_HDR_VERSION;
        pair.struct_size = sizeof(pair);
        pair.hdr.version = SONY2FUJI_HDR_VERSION;
        pair.hdr.struct_size = sizeof(pair.hdr);
        pair.sdr.version = SONY2FUJI_HDR_VERSION;
        pair.sdr.struct_size = sizeof(pair.sdr);
    }
    ~HdrPairGuard() { reset(); }
    void reset() {
        sony2fuji_hdr_release_pair(&pair);
        pair = {};
        pair.version = SONY2FUJI_HDR_VERSION;
        pair.struct_size = sizeof(pair);
        pair.hdr.version = SONY2FUJI_HDR_VERSION;
        pair.hdr.struct_size = sizeof(pair.hdr);
        pair.sdr.version = SONY2FUJI_HDR_VERSION;
        pair.sdr.struct_size = sizeof(pair.sdr);
    }
};

SessionPtr createSession() {
    sony2fuji_session* raw = nullptr;
    require(sony2fuji_session_create(&raw) == SONY2FUJI_STATUS_OK && raw != nullptr,
        "sony2fuji_session_create failed");
    return SessionPtr(raw);
}

std::vector<uint8_t> makePatternRgb8(uint32_t width, uint32_t height) {
    std::vector<uint8_t> pixels(size_t(width) * height * 3);
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const float fx = float(x) / float(std::max(1u, width - 1));
            const float fy = float(y) / float(std::max(1u, height - 1));
            const float stripe = 0.25f * std::sin(float(x) * 0.35f) * std::cos(float(y) * 0.29f);
            const float r = std::clamp(0.15f + 0.65f * fx + stripe, 0.0f, 1.0f);
            const float g = std::clamp(0.20f + 0.55f * fy + 0.5f * stripe, 0.0f, 1.0f);
            const float b = std::clamp(0.25f + 0.45f * (1.0f - fx * fy) - 0.5f * stripe, 0.0f, 1.0f);
            const size_t idx = (size_t(y) * width + x) * 3;
            pixels[idx + 0] = static_cast<uint8_t>(std::lround(r * 255.0f));
            pixels[idx + 1] = static_cast<uint8_t>(std::lround(g * 255.0f));
            pixels[idx + 2] = static_cast<uint8_t>(std::lround(b * 255.0f));
        }
    }
    return pixels;
}

sony2fuji_request makeBufferRequest(const std::vector<uint8_t>& pixels, uint32_t width, uint32_t height,
    sony2fuji_intent intent) {
    sony2fuji_request req{};
    req.version = SONY2FUJI_REQUEST_VERSION;
    req.struct_size = sizeof(req);
    req.input_type = SONY2FUJI_INPUT_BUFFER;
    req.input_pixels = pixels.data();
    req.input_width = width;
    req.input_height = height;
    req.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    req.input_color_space = SONY2FUJI_COLOR_SRGB;
    req.input_is_linear = 0;
    req.temperature = 6500.0f;
    req.tint = 0.0f;
    req.exposure_ev = 0.15f;
    req.brightness = 1.0f;
    req.contrast = 1.15f;
    req.highlights = -0.35f;
    req.shadows = 0.45f;
    req.saturation = 1.1f;
    req.sharpening = 0.35f;
    req.size_mode = intent == SONY2FUJI_INTENT_PREVIEW ? SONY2FUJI_SIZE_FIT_LONG_EDGE : SONY2FUJI_SIZE_NATIVE;
    req.preview_long_edge = intent == SONY2FUJI_INTENT_PREVIEW ? 400u : 0u;
    req.output_target = SONY2FUJI_TARGET_BUFFER;
    req.output_format = SONY2FUJI_OUTPUT_RGB8;
    req.intent = intent;
    return req;
}

void configureComplexSdrSession(sony2fuji_session* s, int quarterTurns, bool perspectiveActive) {
    require(sony2fuji_session_set_processing_version(s, SONY2FUJI_PROCESSING_BASIC_V3) == SONY2FUJI_STATUS_OK,
        "set processing version failed");
    sony2fuji_atmosphere_config atmo{};
    atmo.version = SONY2FUJI_ATMOSPHERE_CONFIG_VERSION;
    atmo.struct_size = sizeof(atmo);
    atmo.clarity = 0.4f;
    atmo.dehaze = 0.3f;
    require(sony2fuji_session_set_atmosphere(s, &atmo) == SONY2FUJI_STATUS_OK, "set atmosphere failed");

    sony2fuji_photo_effects_config effects{};
    effects.version = SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION;
    effects.struct_size = sizeof(effects);
    effects.vignette_amount = -40.0f;
    effects.vignette_midpoint = 50.0f;
    effects.vignette_roundness = 0.0f;
    effects.vignette_feather = 50.0f;
    effects.vignette_highlights = 20.0f;
    effects.grain_amount = 35.0f;
    effects.grain_size = 30.0f;
    effects.grain_roughness = 50.0f;
    require(sony2fuji_session_set_photo_effects(s, &effects) == SONY2FUJI_STATUS_OK, "set photo effects failed");

    sony2fuji_geometry_config geo{};
    geo.version = SONY2FUJI_GEOMETRY_CONFIG_VERSION;
    geo.struct_size = sizeof(geo);
    geo.crop_x = 0.08f;
    geo.crop_y = 0.10f;
    geo.crop_width = 0.84f;
    geo.crop_height = 0.80f;
    geo.quarter_turns = quarterTurns;
    geo.flip_horizontal = 1;
    geo.flip_vertical = 0;
    geo.straighten_degrees = 3.5f;
    require(sony2fuji_session_set_geometry(s, &geo) == SONY2FUJI_STATUS_OK, "set geometry failed");

    if (perspectiveActive) {
        sony2fuji_perspective_config persp{};
        persp.version = SONY2FUJI_PERSPECTIVE_CONFIG_VERSION;
        persp.struct_size = sizeof(persp);
        persp.horizontal = 0.15f;
        persp.vertical = -0.10f;
        require(sony2fuji_session_set_perspective(s, &persp) == SONY2FUJI_STATUS_OK, "set perspective failed");
    }
}

void testSdrBufferRoiParity(uint32_t width, uint32_t height, int quarterTurns, int maxAllowedChannelDiff) {
    auto session = createSession();
    sony2fuji_gpu_config gpu{};
    gpu.version = SONY2FUJI_GPU_CONFIG_VERSION;
    gpu.struct_size = sizeof(gpu);
    gpu.mode = SONY2FUJI_GPU_OFF;
    require(sony2fuji_session_set_gpu_config(session.get(), &gpu) == SONY2FUJI_STATUS_OK, "gpu off failed");
    configureComplexSdrSession(session.get(), quarterTurns, true);

    const auto src = makePatternRgb8(width, height);
    BufferGuard fullRef;
    auto finalReq = makeBufferRequest(src, width, height, SONY2FUJI_INTENT_FINAL);
    require(sony2fuji_process(session.get(), &finalReq, &fullRef.buf) == SONY2FUJI_STATUS_OK,
        "full SDR reference render failed");

    sony2fuji_viewport_roi roi{};
    roi.struct_size = sizeof(roi);
    roi.enabled = 1;
    roi.norm_x0 = 0.25;
    roi.norm_y0 = 0.20;
    roi.norm_x1 = 0.75;
    roi.norm_y1 = 0.70;
    roi.max_output_long_edge = 0;
    require(sony2fuji_session_set_viewport_roi(session.get(), &roi) == SONY2FUJI_STATUS_OK,
        "set viewport roi failed");

    BufferGuard roiOut;
    auto previewReq = makeBufferRequest(src, width, height, SONY2FUJI_INTENT_PREVIEW);
    require(sony2fuji_process(session.get(), &previewReq, &roiOut.buf) == SONY2FUJI_STATUS_OK,
        "SDR preview ROI render failed");

    sony2fuji_viewport_roi_result meta{};
    meta.struct_size = sizeof(meta);
    require(sony2fuji_session_get_viewport_roi_result(session.get(), &meta) == SONY2FUJI_STATUS_OK,
        "get viewport roi result failed");
    require(meta.active == 1, "ROI result active flag must be 1");
    require(meta.full_native_width == fullRef.buf.width && meta.full_native_height == fullRef.buf.height,
        "ROI full_native dimensions must match post-geometry FINAL output");
    require(roiOut.buf.width == meta.native_x1 - meta.native_x0 &&
            roiOut.buf.height == meta.native_y1 - meta.native_y0,
        "ROI buffer dimensions must match returned native rect");

    const uint8_t* refBytes = static_cast<const uint8_t*>(fullRef.buf.data);
    const uint8_t* roiBytes = static_cast<const uint8_t*>(roiOut.buf.data);
    int maxDiff = 0;
    for (uint32_t y = 0; y < roiOut.buf.height; ++y) {
        for (uint32_t x = 0; x < roiOut.buf.width; ++x) {
            const size_t refIdx = size_t(meta.native_y0 + y) * fullRef.buf.stride_bytes +
                size_t(meta.native_x0 + x) * 3;
            const size_t roiIdx = size_t(y) * roiOut.buf.stride_bytes + size_t(x) * 3;
            for (int c = 0; c < 3; ++c) {
                const int d = std::abs(int(refBytes[refIdx + c]) - int(roiBytes[roiIdx + c]));
                maxDiff = std::max(maxDiff, d);
            }
        }
    }
    require(maxDiff <= maxAllowedChannelDiff,
        "SDR ROI interior pixels diverged from full-frame render: maxDiff=" + std::to_string(maxDiff));

    // FINAL intent must ignore viewport ROI and clear viewport_roi_result.
    BufferGuard finalAgain;
    require(sony2fuji_process(session.get(), &finalReq, &finalAgain.buf) == SONY2FUJI_STATUS_OK,
        "FINAL render with ROI armed failed");
    require(finalAgain.buf.width == fullRef.buf.width && finalAgain.buf.height == fullRef.buf.height,
        "FINAL must ignore viewport ROI");
    sony2fuji_viewport_roi_result cleared{};
    cleared.struct_size = sizeof(cleared);
    require(sony2fuji_session_get_viewport_roi_result(session.get(), &cleared) == SONY2FUJI_STATUS_OK,
        "get cleared roi result failed");
    require(cleared.active == 0, "FINAL render must clear viewport_roi_result.active");
}

void testSdrGpuPolicyAndValidation() {
    auto session = createSession();
    const auto src = makePatternRgb8(64, 48);

    sony2fuji_viewport_roi bad{};
    bad.struct_size = sizeof(bad);
    bad.enabled = 1;
    bad.norm_x0 = 0.6;
    bad.norm_y0 = 0.1;
    bad.norm_x1 = 0.4;
    bad.norm_y1 = 0.9;
    require(sony2fuji_session_set_viewport_roi(session.get(), &bad) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "Inverted ROI bounds must be rejected");

    sony2fuji_viewport_roi roi{};
    roi.struct_size = sizeof(roi);
    roi.enabled = 1;
    roi.norm_x0 = 0.1;
    roi.norm_y0 = 0.1;
    roi.norm_x1 = 0.8;
    roi.norm_y1 = 0.8;
    roi.max_output_long_edge = 2048;
    require(sony2fuji_session_set_viewport_roi(session.get(), &roi) == SONY2FUJI_STATUS_OK,
        "valid ROI config failed");

    sony2fuji_gpu_config forceGpu{};
    forceGpu.version = SONY2FUJI_GPU_CONFIG_VERSION;
    forceGpu.struct_size = sizeof(forceGpu);
    forceGpu.mode = SONY2FUJI_GPU_FORCE;
    require(sony2fuji_session_set_gpu_config(session.get(), &forceGpu) == SONY2FUJI_STATUS_OK,
        "set force gpu failed");

    BufferGuard out;
    auto req = makeBufferRequest(src, 64, 48, SONY2FUJI_INTENT_PREVIEW);
    require(sony2fuji_process(session.get(), &req, &out.buf) == SONY2FUJI_STATUS_UNSUPPORTED,
        "GPU Force with active ROI must fail with UNSUPPORTED");
    require(sony2fuji_session_get_unsupported_reason(session.get()) == SONY2FUJI_UNSUPPORTED_FORCE_GPU,
        "Unsupported reason must be ForceGpu");

    sony2fuji_gpu_config autoGpu{};
    autoGpu.version = SONY2FUJI_GPU_CONFIG_VERSION;
    autoGpu.struct_size = sizeof(autoGpu);
    autoGpu.mode = SONY2FUJI_GPU_AUTO;
    require(sony2fuji_session_set_gpu_config(session.get(), &autoGpu) == SONY2FUJI_STATUS_OK,
        "set auto gpu failed");
    require(sony2fuji_process(session.get(), &req, &out.buf) == SONY2FUJI_STATUS_OK,
        "GPU Auto with active ROI must fall back to CPU cleanly");
}

void testSdrRawUpgradeFromInteractivePreview() {
#ifdef TEST_EXAMPLES_DIR
    const auto rawPath = std::filesystem::path(TEST_EXAMPLES_DIR) / "DSC06251.ARW";
    std::error_code ec;
    if (!std::filesystem::exists(rawPath, ec) || !std::filesystem::is_regular_file(rawPath, ec)) {
        return;
    }
    auto session = createSession();
    require(sony2fuji_session_set_interactive_preview(session.get(), 1) == SONY2FUJI_STATUS_OK,
        "enable interactive preview failed");
    const auto rawStr = rawPath.u8string();
    sony2fuji_request baseReq{};
    baseReq.version = SONY2FUJI_REQUEST_VERSION;
    baseReq.struct_size = sizeof(baseReq);
    baseReq.input_type = SONY2FUJI_INPUT_RAW;
    baseReq.input_path = rawStr.c_str();
    baseReq.temperature = 6500.0f;
    baseReq.brightness = 1.0f;
    baseReq.contrast = 1.0f;
    baseReq.saturation = 1.0f;
    baseReq.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
    baseReq.preview_long_edge = 1280;
    baseReq.output_target = SONY2FUJI_TARGET_BUFFER;
    baseReq.output_format = SONY2FUJI_OUTPUT_RGB8;
    baseReq.intent = SONY2FUJI_INTENT_PREVIEW;

    BufferGuard baseBuf;
    require(sony2fuji_process(session.get(), &baseReq, &baseBuf.buf) == SONY2FUJI_STATUS_OK,
        "RAW interactive base preview failed");
    require(std::max(baseBuf.buf.width, baseBuf.buf.height) <= 1280u, "base preview must stay bounded");

    sony2fuji_viewport_roi roi{};
    roi.struct_size = sizeof(roi);
    roi.enabled = 1;
    roi.norm_x0 = 0.4;
    roi.norm_y0 = 0.4;
    roi.norm_x1 = 0.6;
    roi.norm_y1 = 0.6;
    roi.max_output_long_edge = 2048;
    require(sony2fuji_session_set_viewport_roi(session.get(), &roi) == SONY2FUJI_STATUS_OK, "set roi failed");

    BufferGuard roiBuf;
    require(sony2fuji_process(session.get(), &baseReq, &roiBuf.buf) == SONY2FUJI_STATUS_OK,
        "RAW ROI preview failed");
    sony2fuji_viewport_roi_result meta{};
    meta.struct_size = sizeof(meta);
    require(sony2fuji_session_get_viewport_roi_result(session.get(), &meta) == SONY2FUJI_STATUS_OK,
        "get RAW roi result failed");
    require(meta.active == 1 && meta.full_native_width >= 4000u,
        "RAW ROI must upgrade interactive half-size cache to full native dimensions");
    require(roiBuf.buf.width == meta.native_x1 - meta.native_x0 &&
            roiBuf.buf.height == meta.native_y1 - meta.native_y0,
        "RAW ROI 20% tile must deliver 1:1 native pixels");
#endif
}

void testHdrRoiParityHeadroomAndSubRect() {
    const uint32_t w = 240;
    const uint32_t h = 160;
    std::vector<float> hdrPixels(size_t(w) * h * 3);
    std::vector<float> sdrPixels(size_t(w) * h * 3);
    for (uint32_t y = 0; y < h; ++y) {
        for (uint32_t x = 0; x < w; ++x) {
            const float fx = float(x) / float(w - 1);
            const float fy = float(y) / float(h - 1);
            const float wave = 0.12f * std::sin(float(x) * 0.4f) * std::cos(float(y) * 0.3f);
            // Put a bright HDR highlight only in top-left corner outside center ROI.
            const float peakBoost = (x < 24 && y < 24) ? 5.5f : 1.0f;
            const size_t idx = (size_t(y) * w + x) * 3;
            hdrPixels[idx + 0] = std::max(0.02f, (0.25f + 0.6f * fx + wave) * peakBoost);
            hdrPixels[idx + 1] = std::max(0.02f, (0.30f + 0.5f * fy + 0.5f * wave) * peakBoost);
            hdrPixels[idx + 2] = std::max(0.02f, (0.20f + 0.4f * (1.0f - fx) - wave) * peakBoost);
            sdrPixels[idx + 0] = std::min(1.0f, hdrPixels[idx + 0]);
            sdrPixels[idx + 1] = std::min(1.0f, hdrPixels[idx + 1]);
            sdrPixels[idx + 2] = std::min(1.0f, hdrPixels[idx + 2]);
        }
    }

    sony2fuji_hdr_image_pair_v1 source{};
    source.version = SONY2FUJI_HDR_VERSION;
    source.struct_size = sizeof(source);
    source.hdr.version = SONY2FUJI_HDR_VERSION;
    source.hdr.struct_size = sizeof(source.hdr);
    source.hdr.data = hdrPixels.data();
    source.hdr.size_bytes = hdrPixels.size() * sizeof(float);
    source.hdr.width = w;
    source.hdr.height = h;
    source.hdr.stride_bytes = uint64_t(w) * 12;
    source.hdr.pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
    source.hdr.color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
    source.hdr.content_headroom = 5.5f;
    source.hdr.headroom_kind = SONY2FUJI_HDR_HEADROOM_MEASURED;

    source.sdr = source.hdr;
    source.sdr.data = sdrPixels.data();
    source.sdr.content_headroom = 1.0f;
    source.native_width = w;
    source.native_height = h;
    source.orientation_applied = 1;
    source.source_intent = SONY2FUJI_INTENT_FINAL;
    source.render_intent = SONY2FUJI_INTENT_FINAL;
    source.is_proxy = 0;
    source.decode_revision = 1;
    source.source_headroom = 5.5f;
    source.source_headroom_kind = SONY2FUJI_HDR_HEADROOM_MEASURED;

    sony2fuji_hdr_request_v6 req{};
    auto& v1 = req.base.base.base.base.base;
    auto& v2 = req.base.base.base.base;
    auto& v3 = req.base.base.base;
    v1.version = SONY2FUJI_HDR_VERSION;
    v1.struct_size = sizeof(req);
    v1.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION;
    v1.intent = SONY2FUJI_INTENT_FINAL;
    v1.temperature = 6500.0f;
    v1.exposure_ev = 0.25f;
    v1.contrast = 12.0f;
    v1.crop_x = 0.05f;
    v1.crop_y = 0.05f;
    v1.crop_width = 0.90f;
    v1.crop_height = 0.90f;
    v1.quarter_turns = 1;
    v1.flip_horizontal = 1;
    v1.straighten_degrees = 2.0f;
    v1.long_edge = 0;
    v2.curve.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
    v2.curve.struct_size = sizeof(v2.curve);
    v3.hsl.version = SONY2FUJI_HSL_CONFIG_VERSION;
    v3.hsl.struct_size = sizeof(v3.hsl);
    v3.grading.version = SONY2FUJI_COLOR_GRADING_CONFIG_VERSION;
    v3.grading.struct_size = sizeof(v3.grading);
    req.base.effects.version = SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION;
    req.base.effects.struct_size = sizeof(req.base.effects);
    req.base.effects.vignette_amount = -35.0f;
    req.base.effects.vignette_midpoint = 50.0f;
    req.base.effects.vignette_feather = 50.0f;
    req.base.effects.grain_amount = 20.0f;
    req.base.effects.grain_size = 25.0f;
    req.base.effects.grain_roughness = 50.0f;
    req.sharpening = 0.5f;
    req.clarity = 0.35f;
    req.dehaze = 0.25f;
    req.denoise = 0.2f;

    auto session = createSession();
    HdrPairGuard fullOut;
    require(sony2fuji_hdr_render(session.get(), &source, &req.base.base.base.base.base, &fullOut.pair, nullptr) == SONY2FUJI_STATUS_OK,
        "HDR full reference render failed");

    sony2fuji_hdr_roi_v1 roi{};
    roi.version = SONY2FUJI_HDR_VERSION;
    roi.struct_size = sizeof(roi);
    roi.norm_x0 = 0.30;
    roi.norm_y0 = 0.25;
    roi.norm_x1 = 0.70;
    roi.norm_y1 = 0.75;
    roi.max_output_long_edge = 0;
    roi.base_content_headroom = 4.25f;

    auto previewReq = req;
    previewReq.base.base.base.base.base.intent = SONY2FUJI_INTENT_PREVIEW;
    previewReq.base.base.base.base.base.long_edge = 1280;

    HdrPairGuard roiOut;
    sony2fuji_hdr_roi_result_v1 roiMeta{};
    roiMeta.version = SONY2FUJI_HDR_VERSION;
    roiMeta.struct_size = sizeof(roiMeta);
    require(sony2fuji_hdr_render_roi(session.get(), &source, &previewReq.base.base.base.base.base, &roi,
            &roiOut.pair, &roiMeta, nullptr) == SONY2FUJI_STATUS_OK,
        "HDR render_roi failed");
    require(std::abs(roiOut.pair.hdr.content_headroom - 4.25f) < 1e-5f,
        "HDR ROI must preserve base_content_headroom override on output buffer");
    require(roiMeta.full_native_width == fullOut.pair.hdr.width &&
            roiMeta.full_native_height == fullOut.pair.hdr.height,
        "HDR ROI full_native dimensions must match post-geometry FINAL output");
    require(roiOut.pair.hdr.width == roiMeta.native_x1 - roiMeta.native_x0 &&
            roiOut.pair.hdr.height == roiMeta.native_y1 - roiMeta.native_y0,
        "HDR ROI buffer dimensions must match native rect");

    const float* refHdr = static_cast<const float*>(fullOut.pair.hdr.data);
    const float* gotHdr = static_cast<const float*>(roiOut.pair.hdr.data);
    float maxDiff = 0.0f;
    for (uint32_t y = 0; y < roiOut.pair.hdr.height; ++y) {
        for (uint32_t x = 0; x < roiOut.pair.hdr.width; ++x) {
            const size_t ri = size_t(roiMeta.native_y0 + y) * fullOut.pair.hdr.width * 3 + size_t(roiMeta.native_x0 + x) * 3;
            const size_t gi = size_t(y) * roiOut.pair.hdr.width * 3 + size_t(x) * 3;
            for (int c = 0; c < 3; ++c) {
                maxDiff = std::max(maxDiff, std::abs(refHdr[ri + c] - gotHdr[gi + c]));
            }
        }
    }
    require(maxDiff < 0.01f, "HDR ROI interior pixels diverged from full render: " + std::to_string(maxDiff));

    // Pre-cropped sub-rect workflow (Apple ProRAW tile simulation)
    sony2fuji_hdr_roi_source_bounds_v1 bounds{};
    bounds.version = SONY2FUJI_HDR_VERSION;
    bounds.struct_size = sizeof(bounds);
    require(sony2fuji_hdr_roi_source_bounds(w, h, &previewReq.base.base.base.base.base, &roi, &bounds, nullptr) == SONY2FUJI_STATUS_OK,
        "sony2fuji_hdr_roi_source_bounds failed");
    require(bounds.source_x1 > bounds.source_x0 && bounds.source_y1 > bounds.source_y0,
        "source bounds must be non-empty");
    const uint32_t subW = bounds.source_x1 - bounds.source_x0;
    const uint32_t subH = bounds.source_y1 - bounds.source_y0;
    std::vector<float> subHdr(size_t(subW) * subH * 3);
    std::vector<float> subSdr(size_t(subW) * subH * 3);
    for (uint32_t y = 0; y < subH; ++y) {
        std::copy_n(hdrPixels.data() + (size_t(bounds.source_y0 + y) * w + bounds.source_x0) * 3,
            subW * 3, subHdr.data() + size_t(y) * subW * 3);
        std::copy_n(sdrPixels.data() + (size_t(bounds.source_y0 + y) * w + bounds.source_x0) * 3,
            subW * 3, subSdr.data() + size_t(y) * subW * 3);
    }
    auto subSource = source;
    subSource.hdr.data = subHdr.data();
    subSource.hdr.size_bytes = subHdr.size() * sizeof(float);
    subSource.hdr.width = subW;
    subSource.hdr.height = subH;
    subSource.hdr.stride_bytes = uint64_t(subW) * 12;
    subSource.sdr = subSource.hdr;
    subSource.sdr.data = subSdr.data();
    subSource.sdr.content_headroom = 1.0f;

    auto subRoi = roi;
    subRoi.source_x0 = bounds.source_x0;
    subRoi.source_y0 = bounds.source_y0;
    subRoi.full_source_width = w;
    subRoi.full_source_height = h;
    HdrPairGuard subOut;
    require(sony2fuji_hdr_render_roi(session.get(), &subSource, &previewReq.base.base.base.base.base, &subRoi,
            &subOut.pair, nullptr, nullptr) == SONY2FUJI_STATUS_OK,
        "pre-cropped HDR render_roi failed");
    require(subOut.pair.hdr.width == roiOut.pair.hdr.width && subOut.pair.hdr.height == roiOut.pair.hdr.height,
        "pre-cropped HDR ROI output size must match");

    sony2fuji_hdr_clear_session_cache(session.get());

    // ForceGpu must reject HDR ROI with UNSUPPORTED
    sony2fuji_gpu_config forceGpu{};
    forceGpu.version = SONY2FUJI_GPU_CONFIG_VERSION;
    forceGpu.struct_size = sizeof(forceGpu);
    forceGpu.mode = SONY2FUJI_GPU_FORCE;
    require(sony2fuji_session_set_gpu_config(session.get(), &forceGpu) == SONY2FUJI_STATUS_OK, "set gpu failed");
    HdrPairGuard forceFail;
    require(sony2fuji_hdr_render_roi(session.get(), &source, &previewReq.base.base.base.base.base, &roi,
            &forceFail.pair, nullptr, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
        "GPU Force HDR ROI must return UNSUPPORTED");

#ifdef TEST_EXAMPLES_DIR
    const auto rawPath = std::filesystem::path(TEST_EXAMPLES_DIR) / "DSC06251.ARW";
    std::error_code ec;
    if (std::filesystem::exists(rawPath, ec) && std::filesystem::is_regular_file(rawPath, ec)) {
        auto camSession = createSession();
        const auto rawStr = rawPath.u8string();
        HdrPairGuard camOut;
        sony2fuji_hdr_roi_result_v1 camMeta{};
        camMeta.version = SONY2FUJI_HDR_VERSION;
        camMeta.struct_size = sizeof(camMeta);
        sony2fuji_hdr_roi_v1 camRoi{};
        camRoi.version = SONY2FUJI_HDR_VERSION;
        camRoi.struct_size = sizeof(camRoi);
        camRoi.norm_x0 = 0.45;
        camRoi.norm_y0 = 0.45;
        camRoi.norm_x1 = 0.55;
        camRoi.norm_y1 = 0.55;
        camRoi.max_output_long_edge = 1280;
        camRoi.base_content_headroom = 3.5f;
        require(sony2fuji_hdr_render_camera_raw_roi(camSession.get(), rawStr.c_str(), nullptr, 0,
                &previewReq.base.base.base.base.base, &camRoi, &camOut.pair, &camMeta, nullptr) == SONY2FUJI_STATUS_OK,
            "Camera RAW HDR ROI failed");
        require(camMeta.full_native_width >= 4000u && camMeta.is_proxy == 0,
            "Camera RAW HDR ROI must resolve full native canvas on macOS");
        require(std::abs(camOut.pair.hdr.content_headroom - 3.5f) < 1e-5f,
            "Camera RAW HDR ROI must keep base_content_headroom");
        camOut.reset();
        camRoi.norm_x0 = 0.40;
        camRoi.norm_x1 = 0.50;
        require(sony2fuji_hdr_render_camera_raw_roi(camSession.get(), rawStr.c_str(), nullptr, 0,
                &previewReq.base.base.base.base.base, &camRoi, &camOut.pair, &camMeta, nullptr) == SONY2FUJI_STATUS_OK,
            "Second Camera RAW HDR ROI render (cached) failed");
        sony2fuji_hdr_clear_session_cache(camSession.get());
    }
#endif
}

// 色相扫描 + 带彩边的亮度阶梯：每个色彩算子都有可作用的像素，去紫/绿边也有边缘可处理。
std::vector<uint8_t> makeStageOrderPattern(uint32_t width, uint32_t height) {
    std::vector<uint8_t> pixels(size_t(width) * height * 3);
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const float fx = float(x) / float(width - 1);
            const float fy = float(y) / float(height - 1);
            float r, g, b;
            if (fy < 0.55f) {
                const float hue = fx * 6.0f;
                const float s = 0.15f + 0.85f * fy / 0.55f;
                const float v = 0.35f + 0.6f * std::fabs(std::sin(float(x) * 0.05f));
                const int sector = int(hue) % 6;
                const float f = hue - std::floor(hue);
                const float p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
                const float table[6][3] = {{v, t, p}, {q, v, p}, {p, v, t}, {p, q, v}, {t, p, v}, {v, p, q}};
                r = table[sector][0];
                g = table[sector][1];
                b = table[sector][2];
            } else {
                r = g = b = fx + 0.08f * std::sin(float(x) * 0.7f) * std::cos(float(y) * 0.53f);
                if ((x / 9) % 2 == 0 && (y / 11) % 2 == 1) { r += 0.25f; b += 0.3f; g -= 0.05f; }
                if (x % 13 < 2) { g += 0.25f; r -= 0.1f; }
            }
            const size_t idx = (size_t(y) * width + x) * 3;
            pixels[idx + 0] = static_cast<uint8_t>(std::lround(std::clamp(r, 0.0f, 1.0f) * 255.0f));
            pixels[idx + 1] = static_cast<uint8_t>(std::lround(std::clamp(g, 0.0f, 1.0f) * 255.0f));
            pixels[idx + 2] = static_cast<uint8_t>(std::lround(std::clamp(b, 0.0f, 1.0f) * 255.0f));
        }
    }
    return pixels;
}

sony2fuji_tone_curve_config customCurve(std::initializer_list<std::pair<double, double>> points) {
    sony2fuji_tone_curve_config curve{SONY2FUJI_TONE_CURVE_CONFIG_VERSION, sizeof(curve), SONY2FUJI_CURVE_CUSTOM,
        static_cast<uint32_t>(points.size()), {}};
    uint32_t i = 0;
    for (const auto& point : points) curve.points[i++] = {point.first, point.second};
    return curve;
}

struct StageCase {
    const char* name;
    std::function<void(sony2fuji::EditRecipe&)> apply;
    // 逐像素算子只容许 ROI 重采样的 ±1 DN 级舍入；空间算子另有引导图分析场的近似。
    int maxDiff;
    double meanDiff;
    // 旧版 sony2fuji_process 入口：参数来自请求，会话状态由 sony2fuji_apply_params 写入。
    bool legacyEntry = false;
};

// 1:1 视口 ROI 与导出整图必须走同一条阶段链：任一算子在某条路径缺失或顺序错位，
// 同一区域的像素就会明显偏离。逐个算子单独开启，再把全部逐像素算子叠在一起锁定顺序。
void testStageOrderRoiMatchesFullRender() {
    constexpr uint32_t width = 360;
    constexpr uint32_t height = 240;
    const auto src = makeStageOrderPattern(width, height);
    const std::string fixtures = TEST_FIXTURE_DIR;
    const auto curves = [](sony2fuji::EditRecipe& r) {
        r.toneCurve = customCurve({{0, 0.05}, {0.25, 0.17}, {0.7, 0.85}, {1, 0.97}});
        r.channelCurves[0] = customCurve({{0, 0}, {0.5, 0.6}, {1, 1}});
        r.channelCurves[2] = customCurve({{0, 0.08}, {0.5, 0.45}, {1, 1}});
        r.parametricCurve.highlights = -35;
        r.parametricCurve.darks = 30;
    };
    const auto bwPoints = [](sony2fuji::EditRecipe& r) {
        r.toneControls.black_point = -0.6f;
        r.toneControls.white_point = 0.5f;
    };
    const auto vibrance = [](sony2fuji::EditRecipe& r) { r.toneControls.vibrance = 0.7f; };
    const auto hsl = [](sony2fuji::EditRecipe& r) {
        for (int i = 0; i < 8; ++i) {
            r.hsl.hue[i] = i % 2 ? 40.0f : -30.0f;
            r.hsl.saturation[i] = i % 3 ? 35.0f : -45.0f;
            r.hsl.lightness[i] = i % 2 ? -25.0f : 30.0f;
        }
    };
    const auto pointColor = [](sony2fuji::EditRecipe& r) {
        r.pointColor.swatchCount = 2;
        auto& a = r.pointColor.swatches[0];
        a.srcHue = 25; a.srcSaturation = 0.6f; a.srcLuminance = 0.55f;
        a.hueShift = 30; a.saturationShift = 40; a.luminanceShift = -20; a.variance = -30; a.range = 70;
        auto& b = r.pointColor.swatches[1];
        b.srcHue = 210; b.srcSaturation = 0.7f; b.srcLuminance = 0.45f;
        b.hueShift = -40; b.saturationShift = -30; b.luminanceShift = 25; b.variance = 40; b.range = 60;
    };
    const auto selective = [](sony2fuji::EditRecipe& r) {
        for (int i = 0; i < 9; ++i)
            r.selectiveColor.bands[i] = {float(i * 7 - 30), float(25 - i * 6), float(i % 2 ? 30 : -20), float(i % 3 ? 10 : -15)};
    };
    const auto grading = [](sony2fuji::EditRecipe& r) {
        auto& g = r.colorGradingV2;
        g.shadows_hue = 200; g.shadows_saturation = 45; g.shadows_luminance = -20;
        g.midtones_hue = 40; g.midtones_saturation = 25;
        g.highlights_hue = 60; g.highlights_saturation = 30; g.highlights_luminance = 15;
        g.global_hue = 300; g.global_saturation = 15; g.blending = 70; g.balance = -20;
    };
    const auto calibration = [](sony2fuji::EditRecipe& r) { r.calibration = {25, 30, 40, -25, -30, 20, 35}; };
    const auto look = [fixtures](sony2fuji::EditRecipe& r) {
        r.lookPath = fixtures + "/golden-srgb-look.cube";
        r.lookStrength = 0.8f;
    };
    const auto tone = [](sony2fuji::EditRecipe& r) { r.contrast = 1.35f; r.saturation = 1.3f; };
    const auto whiteBalance = [](sony2fuji::EditRecipe& r) {
        r.exposureEv = 0.4f;
        r.rasterRelativeWb = true;
        r.temperatureKelvin = 5200;
        r.tint = 15;
    };
    const auto bwMixer = [](sony2fuji::EditRecipe& r) {
        r.bw.enabled = true;
        r.bw.weights = {40, -20, 30, -50, 25, -35, 60, -10};
    };
    const auto everyColorStage = [=](sony2fuji::EditRecipe& r) {
        whiteBalance(r); calibration(r); look(r); tone(r); curves(r); bwPoints(r);
        vibrance(r); hsl(r); pointColor(r); selective(r); grading(r);
    };

    const std::vector<StageCase> cases = {
        {"exposure_white_balance", whiteBalance, 2, 0.35},
        {"calibration", calibration, 2, 0.35},
        {"look", look, 2, 0.35},
        {"contrast_saturation", tone, 2, 0.35},
        {"curves", curves, 2, 0.35},
        {"luminosity_curve", [=](sony2fuji::EditRecipe& r) { curves(r); r.curveApplyToLuminosity = true; }, 2, 0.35},
        {"black_white_points", bwPoints, 2, 0.35},
        {"vibrance", vibrance, 2, 0.35},
        {"hsl", hsl, 2, 0.35},
        {"point_color", pointColor, 2, 0.35},
        {"selective_color", selective, 2, 0.35},
        {"color_grading", grading, 2, 0.35},
        {"bw_mixer", bwMixer, 2, 0.35},
        {"bw_mixer_then_color", [=](sony2fuji::EditRecipe& r) { bwMixer(r); grading(r); hsl(r); }, 2, 0.35},
        {"every_color_stage", everyColorStage, 2, 0.35},
        {"defringe", [](sony2fuji::EditRecipe& r) { r.defringe = {12, 60, 8, 40}; }, 2, 0.35},
        {"dehaze", [](sony2fuji::EditRecipe& r) { r.atmosphere.dehaze = 0.6f; }, 4, 0.5},
        {"clarity", [](sony2fuji::EditRecipe& r) { r.atmosphere.clarity = 0.6f; }, 4, 0.5},
        {"texture", [](sony2fuji::EditRecipe& r) { r.texture = 0.6f; }, 2, 0.35},
        {"chroma_denoise", [](sony2fuji::EditRecipe& r) { r.chromaDenoise = 1; }, 2, 0.35},
        {"sharpen", [](sony2fuji::EditRecipe& r) { r.sharpening = 0.9f; r.sharpenV2 = {true, 1.4f, 40, 20}; }, 2, 0.35},
        {"film_optics", [](sony2fuji::EditRecipe& r) { r.filmOptics = {45, 65, 40, 10, 35, 60, 45}; }, 4, 0.5},
        {"effects", [](sony2fuji::EditRecipe& r) {
            r.effects.vignette_amount = -45; r.effects.grain_amount = 30; r.effects.grain_size = 30; }, 2, 0.35},
        // Basic v3 黑白点把数值推出 [0,1] 后再经几何重采样：ROI 不得比导出多截断一次。
        {"bw_mixer_black_white_points_perspective", [=](sony2fuji::EditRecipe& r) {
            bwMixer(r); bwPoints(r);
            r.perspective.horizontal = 0.15f; r.perspective.vertical = -0.10f; r.geometry.quarter_turns = 2; }, 2, 0.35},
        {"bw_mixer_black_white_points_crop_rotate", [=](sony2fuji::EditRecipe& r) {
            bwMixer(r); bwPoints(r);
            r.geometry.crop_x = 0.06f; r.geometry.crop_y = 0.08f; r.geometry.crop_width = 0.86f; r.geometry.crop_height = 0.82f;
            r.geometry.quarter_turns = 1; r.geometry.flip_horizontal = 1; r.geometry.straighten_degrees = 3.5f; }, 2, 0.35},
        // 引导图的分析场必须与瓦片用同一套会话曲线，旧版入口也一样。
        {"film_optics_luminosity_curve", [=](sony2fuji::EditRecipe& r) {
            curves(r); r.curveApplyToLuminosity = true; r.filmOptics = {45, 65, 40, 10, 35, 60, 45}; }, 4, 0.5, true},
        {"clarity_curves", [=](sony2fuji::EditRecipe& r) {
            curves(r); r.curveApplyToLuminosity = true; r.atmosphere.clarity = 0.6f; }, 4, 0.5, true},
    };

    sony2fuji_render_options_v1 options{};
    options.version = SONY2FUJI_RENDER_OPTIONS_V1_VERSION;
    options.struct_size = sizeof(options);
    options.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    options.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    options.input_pixels = src.data();
    options.input_width = width;
    options.input_height = height;
    options.input_color_space = SONY2FUJI_COLOR_SRGB;
    options.output_target = SONY2FUJI_TARGET_BUFFER;
    options.output_format = SONY2FUJI_OUTPUT_RGB8;

    for (const auto version : {SONY2FUJI_PROCESSING_LEGACY, SONY2FUJI_PROCESSING_BASIC_V3}) {
        auto session = createSession();
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
        require(sony2fuji_session_set_gpu_config(session.get(), &gpu) == SONY2FUJI_STATUS_OK, "gpu off failed");
        for (const auto& stage : cases) {
            sony2fuji::EditRecipe recipe;
            recipe.schemaVersion = 20;
            recipe.processingVersion = version;
            recipe.rasterInput = true;
            recipe.exposureMode = SONY2FUJI_EXPOSURE_SENSOR;
            recipe.inputPath = "pattern.png";
            recipe.outputPath = "out.png";
            recipe.outputFormat = SONY2FUJI_OUTPUT_PNG;
            stage.apply(recipe);
            const std::string json = sony2fuji::serializeEditRecipe(recipe);
            const std::string label = std::string(stage.name) +
                (version == SONY2FUJI_PROCESSING_BASIC_V3 ? " [basic v3]" : " [legacy]") +
                (stage.legacyEntry ? " [sony2fuji_process]" : "");

            BufferGuard fullOut;
            BufferGuard roiOut;
            sony2fuji_viewport_roi roi{sizeof(roi), 1, 0.30, 0.20, 0.70, 0.75, 0};
            sony2fuji_viewport_roi_result meta{};
            meta.struct_size = sizeof(meta);
            if (stage.legacyEntry) {
                require(sony2fuji_apply_params(session.get(), json.c_str()) == SONY2FUJI_STATUS_OK,
                    label + " apply_params failed");
                auto request = recipe.toRequest();
                request.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
                request.input_path = nullptr;
                request.input_pixels = src.data();
                request.input_width = width;
                request.input_height = height;
                request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
                request.input_color_space = SONY2FUJI_COLOR_SRGB;
                request.input_is_linear = 0;
                request.output_target = SONY2FUJI_TARGET_BUFFER;
                request.output_format = SONY2FUJI_OUTPUT_RGB8;
                request.output_path = nullptr;
                request.intent = SONY2FUJI_INTENT_FINAL;
                request.size_mode = SONY2FUJI_SIZE_NATIVE;
                sony2fuji_viewport_roi off{sizeof(off), 0, 0, 0, 1, 1, 0};
                require(sony2fuji_session_set_viewport_roi(session.get(), &off) == SONY2FUJI_STATUS_OK, label + " roi off failed");
                require(sony2fuji_process(session.get(), &request, &fullOut.buf) == SONY2FUJI_STATUS_OK,
                    label + " full render failed");
                require(sony2fuji_session_set_viewport_roi(session.get(), &roi) == SONY2FUJI_STATUS_OK, label + " set roi failed");
                request.intent = SONY2FUJI_INTENT_PREVIEW;
                request.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
                request.preview_long_edge = 1024;
                require(sony2fuji_process(session.get(), &request, &roiOut.buf) == SONY2FUJI_STATUS_OK,
                    label + " ROI render failed");
                require(sony2fuji_session_get_viewport_roi_result(session.get(), &meta) == SONY2FUJI_STATUS_OK,
                    label + " ROI result failed");
                require(sony2fuji_session_set_viewport_roi(session.get(), &off) == SONY2FUJI_STATUS_OK, label + " roi off failed");
            } else {
                auto full = options;
                full.intent = SONY2FUJI_INTENT_FINAL;
                full.size_mode = SONY2FUJI_SIZE_NATIVE;
                require(sony2fuji_session_render(session.get(), &full, json.c_str(), &fullOut.buf, nullptr) ==
                    SONY2FUJI_STATUS_OK, label + " full render failed");
                auto preview = options;
                preview.intent = SONY2FUJI_INTENT_PREVIEW;
                preview.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
                preview.preview_long_edge = 1024;
                preview.interactive_preview = 1;
                preview.viewport_roi = &roi;
                require(sony2fuji_session_render(session.get(), &preview, json.c_str(), &roiOut.buf, &meta) ==
                    SONY2FUJI_STATUS_OK, label + " ROI render failed");
            }
            require(meta.active == 1 && roiOut.buf.width == meta.native_x1 - meta.native_x0 &&
                    roiOut.buf.height == meta.native_y1 - meta.native_y0 &&
                    meta.full_native_width == fullOut.buf.width && meta.full_native_height == fullOut.buf.height,
                label + " ROI must be a 1:1 tile of the full render");

            const auto* fullBytes = static_cast<const uint8_t*>(fullOut.buf.data);
            const auto* roiBytes = static_cast<const uint8_t*>(roiOut.buf.data);
            int maxDiff = 0;
            double sum = 0;
            for (uint32_t y = 0; y < roiOut.buf.height; ++y) {
                for (uint32_t x = 0; x < roiOut.buf.width; ++x) {
                    const size_t f = size_t(meta.native_y0 + y) * fullOut.buf.stride_bytes + size_t(meta.native_x0 + x) * 3;
                    const size_t t = size_t(y) * roiOut.buf.stride_bytes + size_t(x) * 3;
                    for (int c = 0; c < 3; ++c) {
                        const int d = std::abs(int(fullBytes[f + c]) - int(roiBytes[t + c]));
                        maxDiff = std::max(maxDiff, d);
                        sum += d;
                    }
                }
            }
            const double meanDiff = sum / (double(roiOut.buf.width) * roiOut.buf.height * 3);
            rawlab::test::checkPass(maxDiff <= stage.maxDiff && meanDiff <= stage.meanDiff,
                label + " ROI matches full render (max=" + std::to_string(maxDiff) +
                " mean=" + std::to_string(meanDiff) + ")");
        }
    }
}

// #697：RAW 无几何导出复用预建的 Basic v3 分析场（校准前像素）；几何导出和 1:1 ROI 引导图
// 在阶段链内建场，必须取同一位置的像素，否则相机校准会让高光/阴影落点在三条路径间漂移。
void testBasicToneFieldBeforeCalibrationAcrossPaths() {
    const auto dng = std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng";
    auto session = createSession();
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    require(sony2fuji_session_set_gpu_config(session.get(), &gpu) == SONY2FUJI_STATUS_OK, "gpu off failed");

    sony2fuji::EditRecipe recipe;
    recipe.schemaVersion = 20;
    recipe.processingVersion = SONY2FUJI_PROCESSING_BASIC_V3;
    recipe.inputPath = dng;
    recipe.outputPath = "out.png";
    recipe.outputFormat = SONY2FUJI_OUTPUT_PNG;
    recipe.exposureMode = SONY2FUJI_EXPOSURE_SENSOR;
    recipe.highlights = 0.7f;
    recipe.shadows = 0.6f;
    recipe.calibration = {60, 80, 100, -70, -100, 60, 100};

    sony2fuji_render_options_v1 options{};
    options.version = SONY2FUJI_RENDER_OPTIONS_V1_VERSION;
    options.struct_size = sizeof(options);
    options.input_type = SONY2FUJI_INPUT_RAW;
    options.input_path = dng.c_str();
    options.output_target = SONY2FUJI_TARGET_BUFFER;
    options.output_format = SONY2FUJI_OUTPUT_RGB8;
    options.intent = SONY2FUJI_INTENT_FINAL;
    options.size_mode = SONY2FUJI_SIZE_NATIVE;

    const std::string json = sony2fuji::serializeEditRecipe(recipe);
    BufferGuard exportOut;
    require(sony2fuji_session_render(session.get(), &options, json.c_str(), &exportOut.buf, nullptr) ==
        SONY2FUJI_STATUS_OK, "RAW export failed");

    // 180° 旋转是逐像素重排，几何本身不重采样，差异只能来自分析场。
    auto rotated = recipe;
    rotated.geometry.quarter_turns = 2;
    const std::string rotatedJson = sony2fuji::serializeEditRecipe(rotated);
    BufferGuard rotatedOut;
    require(sony2fuji_session_render(session.get(), &options, rotatedJson.c_str(), &rotatedOut.buf, nullptr) ==
        SONY2FUJI_STATUS_OK, "RAW geometry export failed");

    auto preview = options;
    preview.intent = SONY2FUJI_INTENT_PREVIEW;
    preview.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
    preview.preview_long_edge = 1024;
    preview.interactive_preview = 1;
    sony2fuji_viewport_roi roi{sizeof(roi), 1, 0.30, 0.20, 0.70, 0.75, 0};
    preview.viewport_roi = &roi;
    sony2fuji_viewport_roi_result meta{};
    meta.struct_size = sizeof(meta);
    BufferGuard roiOut;
    require(sony2fuji_session_render(session.get(), &preview, json.c_str(), &roiOut.buf, &meta) ==
        SONY2FUJI_STATUS_OK, "RAW ROI render failed");

    const auto& full = exportOut.buf;
    require(rotatedOut.buf.width == full.width && rotatedOut.buf.height == full.height,
        "180-degree export must keep the canvas size");
    require(meta.active == 1 && roiOut.buf.width == meta.native_x1 - meta.native_x0 &&
            roiOut.buf.height == meta.native_y1 - meta.native_y0 &&
            meta.full_native_width == full.width && meta.full_native_height == full.height,
        "RAW ROI must be a 1:1 tile of the export");

    // 与逐像素阶段同一上限（见 testStageOrderRoiMatchesFullRender）。
    const auto compare = [&](const sony2fuji_buffer& other, uint32_t x0, uint32_t y0, bool rotate180,
                             const std::string& label) {
        const auto* a = static_cast<const uint8_t*>(full.data);
        const auto* b = static_cast<const uint8_t*>(other.data);
        int maxDiff = 0;
        double sum = 0;
        for (uint32_t y = 0; y < other.height; ++y) {
            for (uint32_t x = 0; x < other.width; ++x) {
                const uint32_t fx = rotate180 ? full.width - 1 - x : x0 + x;
                const uint32_t fy = rotate180 ? full.height - 1 - y : y0 + y;
                const size_t f = size_t(fy) * full.stride_bytes + size_t(fx) * 3;
                const size_t t = size_t(y) * other.stride_bytes + size_t(x) * 3;
                for (int c = 0; c < 3; ++c) {
                    const int d = std::abs(int(a[f + c]) - int(b[t + c]));
                    maxDiff = std::max(maxDiff, d);
                    sum += d;
                }
            }
        }
        const double meanDiff = sum / (double(other.width) * other.height * 3);
        rawlab::test::checkPass(maxDiff <= 2 && meanDiff <= 0.35,
            label + " (max=" + std::to_string(maxDiff) + " mean=" + std::to_string(meanDiff) + ")");
    };
    compare(rotatedOut.buf, 0, 0, true, "calibrated Basic v3 export matches the geometry export");
    compare(roiOut.buf, meta.native_x0, meta.native_y0, false, "calibrated Basic v3 export matches the 1:1 ROI");
}

} // namespace

RAWLAB_TEST_MAIN(
    testStageOrderRoiMatchesFullRender();
    testBasicToneFieldBeforeCalibrationAcrossPaths();
    testSdrBufferRoiParity(240, 160, 0, 2);
    testSdrBufferRoiParity(1400, 900, 1, 2);
    testSdrBufferRoiParity(240, 160, 2, 2);
    testSdrBufferRoiParity(240, 160, 3, 2);
    testSdrGpuPolicyAndValidation();
    testSdrRawUpgradeFromInteractivePreview();
    testHdrRoiParityHeadroomAndSubRect();
)
