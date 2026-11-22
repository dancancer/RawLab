#include "sony2fuji/ffi/sony2fuji_c.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

#define REQUIRE(cond)                                                                                   \
    do {                                                                                                \
        if (!(cond)) {                                                                                  \
            std::cerr << "REQUIRE failed at " << __FILE__ << ":" << __LINE__ << ": " #cond << "\n";     \
            std::abort();                                                                               \
        }                                                                                               \
    } while (false)

namespace {

std::vector<uint8_t> makeTestRgba(uint32_t width, uint32_t height) {
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4, 255);
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const size_t idx = (static_cast<size_t>(y) * width + x) * 4;
            pixels[idx + 0] = static_cast<uint8_t>(40 + (x * 160) / (width - 1));
            pixels[idx + 1] = static_cast<uint8_t>(50 + (y * 140) / (height - 1));
            pixels[idx + 2] = static_cast<uint8_t>(90 + ((x + y) * 80) / (width + height - 2));
            pixels[idx + 3] = 255;
        }
    }
    return pixels;
}

sony2fuji_request makeDisplayRequest(const std::vector<uint8_t>& pixels, uint32_t width, uint32_t height) {
    sony2fuji_request req{};
    req.version = SONY2FUJI_REQUEST_VERSION;
    req.struct_size = sizeof(sony2fuji_request);
    req.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    req.input_pixels = pixels.data();
    req.input_width = width;
    req.input_height = height;
    req.input_pixel_format = SONY2FUJI_PIXEL_RGBA8;
    req.input_color_space = SONY2FUJI_COLOR_SRGB;
    req.wb_mode = SONY2FUJI_WB_CAMERA;
    req.wb_mul[0] = 1.0f;
    req.wb_mul[1] = 1.0f;
    req.wb_mul[2] = 1.0f;
    req.wb_mul[3] = 1.0f;
    req.brightness = 1.0f;
    req.contrast = 1.0f;
    req.saturation = 1.0f;
    req.temperature = 6500.0f;
    req.intent = SONY2FUJI_INTENT_PREVIEW;
    req.preview_long_edge = width;
    req.output_target = SONY2FUJI_TARGET_BUFFER;
    req.output_format = SONY2FUJI_OUTPUT_RGBA8;
    return req;
}

std::vector<uint8_t> renderDisplay(sony2fuji_session* session, const std::vector<uint8_t>& pixels, uint32_t width, uint32_t height) {
    sony2fuji_request req = makeDisplayRequest(pixels, width, height);
    sony2fuji_buffer out{};
    const sony2fuji_status st = sony2fuji_process(session, &req, &out);
    REQUIRE(st == SONY2FUJI_STATUS_OK);
    REQUIRE(out.data != nullptr);
    REQUIRE(out.size_bytes == static_cast<size_t>(out.width) * out.height * 4);
    const auto* bytes = static_cast<const uint8_t*>(out.data);
    std::vector<uint8_t> copy(bytes, bytes + out.size_bytes);
    sony2fuji_release_buffer(&out);
    return copy;
}

constexpr const char* kNeutralRasterRecipe = R"({
  "schema_version": 5,
  "processing": { "family": "rawlab", "version": 2, "quality": "standard" },
  "input": { "path": "memory.png", "type": "raster" },
  "edits": {
    "exposure": { "mode": "sensor", "ev": 0.0, "brightness": 1.0 },
    "white_balance": { "mode": "none" },
    "look": { "path": null, "strength": 1.0 },
    "tone": { "contrast": 1.0, "saturation": 1.0, "highlights": 0.0, "shadows": 0.0, "s_curve": 0.0 },
    "detail": { "sharpening": 0.0 }
  },
  "output": { "path": "out.png", "format": "png", "size": { "mode": "native" } }
})";

constexpr const char* kEditedRasterRecipe = R"({
  "schema_version": 5,
  "processing": { "family": "rawlab", "version": 2, "quality": "standard" },
  "input": { "path": "memory.png", "type": "raster" },
  "edits": {
    "exposure": { "mode": "sensor", "ev": 0.0, "brightness": 1.0 },
    "white_balance": { "mode": "none" },
    "look": { "path": null, "strength": 1.0 },
    "tone": { "contrast": 1.0, "saturation": 1.0, "highlights": 0.0, "shadows": 0.0, "s_curve": 0.0, "black_point": 0.35, "white_point": -0.2 },
    "effects": { "vignette_amount": -80.0, "vignette_midpoint": 50.0, "vignette_roundness": 0.0, "vignette_feather": 50.0, "vignette_highlights": 0.0, "grain_amount": 0.0, "grain_size": 25.0, "grain_roughness": 50.0 },
    "geometry": { "flip_horizontal": true },
    "detail": { "sharpening": 0.0 }
  },
  "output": { "path": "out.png", "format": "png", "size": { "mode": "native" } }
})";

} // namespace

int main() {
    constexpr uint32_t kWidth = 32;
    constexpr uint32_t kHeight = 24;
    const auto inputPixels = makeTestRgba(kWidth, kHeight);

    sony2fuji_session* session = nullptr;
    REQUIRE(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    REQUIRE(session != nullptr);

    sony2fuji_gpu_config gpu{};
    gpu.version = SONY2FUJI_GPU_CONFIG_VERSION;
    gpu.struct_size = sizeof(gpu);
    gpu.mode = SONY2FUJI_GPU_OFF;
    REQUIRE(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);

    // 1. Validation & null checks.
    REQUIRE(sony2fuji_apply_params(nullptr, kNeutralRasterRecipe) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    REQUIRE(sony2fuji_apply_params(session, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    REQUIRE(sony2fuji_apply_params(session, "") == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    REQUIRE(sony2fuji_apply_params(session, "{not-json") == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    REQUIRE(sony2fuji_apply_params(session, R"({"schema_version": 999})") == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    // HDR schema rejected on SDR apply_params
    REQUIRE(sony2fuji_apply_params(session, R"({"schema_version": 8})") == SONY2FUJI_STATUS_INVALID_ARGUMENT);

    // 2. Fresh neutral render baseline.
    sony2fuji_session* baselineSession = nullptr;
    REQUIRE(sony2fuji_session_create(&baselineSession) == SONY2FUJI_STATUS_OK);
    REQUIRE(sony2fuji_session_set_gpu_config(baselineSession, &gpu) == SONY2FUJI_STATUS_OK);
    REQUIRE(sony2fuji_apply_params(baselineSession, kNeutralRasterRecipe) == SONY2FUJI_STATUS_OK);
    const auto baselinePixels = renderDisplay(baselineSession, inputPixels, kWidth, kHeight);
    sony2fuji_session_destroy(baselineSession);

    // 3. Apply edited state, verify difference, then verify transactional rollback on failure.
    REQUIRE(sony2fuji_apply_params(session, kEditedRasterRecipe) == SONY2FUJI_STATUS_OK);
    const auto editedPixels = renderDisplay(session, inputPixels, kWidth, kHeight);
    REQUIRE(editedPixels != baselinePixels);

    // Failing apply_params must leave edited state intact.
    REQUIRE(sony2fuji_apply_params(session, R"({"schema_version": 5, "processing": {"family": "rawlab", "version": 2, "quality": "standard"}, "input": {"path": "m.png", "type": "raster"}, "edits": {"exposure": {"mode": "sensor"}, "tone": {"black_point": 99.0}}, "output": {"path": "o.png", "format": "png"}})") != SONY2FUJI_STATUS_OK);
    const auto afterFailedApply = renderDisplay(session, inputPixels, kWidth, kHeight);
    REQUIRE(afterFailedApply == editedPixels);

    // 4. Atomic full-state reset: omitting tone_controls, effects, geometry returns to exact neutral baseline.
    REQUIRE(sony2fuji_apply_params(session, kNeutralRasterRecipe) == SONY2FUJI_STATUS_OK);
    const auto resetPixels = renderDisplay(session, inputPixels, kWidth, kHeight);
    REQUIRE(resetPixels == baselinePixels);

    // 5. Frozen legacy setter compatibility and reset by subsequent apply_params.
    sony2fuji_photo_effects_config effects{};
    effects.version = SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION;
    effects.struct_size = sizeof(effects);
    effects.vignette_amount = -75.0f;
    effects.vignette_midpoint = 50.0f;
    effects.vignette_feather = 50.0f;
    REQUIRE(sony2fuji_session_set_photo_effects(session, &effects) == SONY2FUJI_STATUS_OK);
    const auto legacySetterPixels = renderDisplay(session, inputPixels, kWidth, kHeight);
    REQUIRE(legacySetterPixels != baselinePixels);

    REQUIRE(sony2fuji_apply_params(session, kNeutralRasterRecipe) == SONY2FUJI_STATUS_OK);
    const auto resetAfterLegacyPixels = renderDisplay(session, inputPixels, kWidth, kHeight);
    REQUIRE(resetAfterLegacyPixels == baselinePixels);

    // 6. Display lens correction allowed on raster input when display lens metadata is attached.
    sony2fuji_lens_metadata lensMeta{};
    lensMeta.version = SONY2FUJI_LENS_METADATA_VERSION;
    lensMeta.struct_size = sizeof(lensMeta);
    lensMeta.camera_make = "Sony";
    lensMeta.camera_model = "ILCE-7RM5";
    lensMeta.lens_make = "Sony";
    lensMeta.lens_model = "FE 35mm F1.4 GM";
    lensMeta.focal_length = 35.0f;
    lensMeta.aperture = 2.8f;
    lensMeta.source_orientation = 1;
    REQUIRE(sony2fuji_session_set_display_lens_metadata(session, &lensMeta) == SONY2FUJI_STATUS_OK);
    const char* kRasterWithLens = R"({
      "schema_version": 5,
      "processing": { "family": "rawlab", "version": 2, "quality": "standard" },
      "input": { "path": "memory.png", "type": "raster" },
      "edits": {
        "exposure": { "mode": "sensor", "ev": 0.0, "brightness": 1.0 },
        "white_balance": { "mode": "none" },
        "look": { "path": null, "strength": 1.0 },
        "tone": { "contrast": 1.0, "saturation": 1.0, "highlights": 0.0, "shadows": 0.0, "s_curve": 0.0 },
        "lens_correction": { "distortion": false, "tca": false, "vignetting": false, "auto_crop": false },
        "detail": { "sharpening": 0.0 }
      },
      "output": { "path": "out.png", "format": "png", "size": { "mode": "native" } }
    })";
    REQUIRE(sony2fuji_apply_params(session, kRasterWithLens) == SONY2FUJI_STATUS_OK);
    REQUIRE(sony2fuji_session_set_display_lens_metadata(session, nullptr) == SONY2FUJI_STATUS_OK);

    // 7. Schema version 7 with x3f_mode accepted for RAW.
    const char* kX3fRecipe = R"({
      "schema_version": 7,
      "x3f_mode": "normal-v1",
      "processing": { "family": "rawlab", "version": 3, "quality": "standard" },
      "input": { "path": "sample.X3F", "type": "raw" },
      "edits": {
        "exposure": { "mode": "preview", "ev": 0.25, "brightness": 1.0 },
        "white_balance": { "mode": "camera" },
        "look": { "path": null, "strength": 1.0 },
        "detail": { "sharpening": 0.0 }
      },
      "output": { "path": "out.png", "format": "png", "size": { "mode": "native" } }
    })";
    REQUIRE(sony2fuji_apply_params(session, kX3fRecipe) == SONY2FUJI_STATUS_OK);

    // 8. Wave 0 v17 apply_params, raster relative WB, and additive C ABI stubs.
    const char* kV17RasterRelativeWb = R"({
      "schema_version": 17,
      "processing": { "family": "rawlab", "version": 3, "quality": "standard" },
      "input": { "path": "memory.png", "type": "raster" },
      "edits": {
        "exposure": { "mode": "sensor", "ev": 0.0, "brightness": 1.0 },
        "white_balance": { "mode": "relative", "relative_temperature": 5200.0, "relative_tint": -10.0 },
        "tone": {
          "curve": {
            "mode": "custom",
            "points": [[0.0, 0.05], [1.0, 0.95]],
            "apply_to_luminosity": true,
            "parametric": { "highlights": -10.0, "shadows": 15.0 }
          }
        },
        "color_grading": {
          "shadows": { "hue": 200.0, "saturation": 20.0, "luminance": -5.0 },
          "global": { "hue": 30.0, "saturation": 10.0, "luminance": 2.0 },
          "blending": 60.0,
          "balance": -10.0
        }
      },
      "output": { "path": "out.png", "format": "png", "output_sharpening": "low", "size": { "mode": "native" } }
    })";
    REQUIRE(sony2fuji_apply_params(session, kV17RasterRelativeWb) == SONY2FUJI_STATUS_OK);
    const auto v17WbPixels = renderDisplay(session, inputPixels, kWidth, kHeight);
    REQUIRE(v17WbPixels != baselinePixels);
    // Reset to neutral returns exact baseline.
    REQUIRE(sony2fuji_apply_params(session, kNeutralRasterRecipe) == SONY2FUJI_STATUS_OK);
    REQUIRE(renderDisplay(session, inputPixels, kWidth, kHeight) == baselinePixels);

    // Additive C ABI stubs validation & safe behavior.
    REQUIRE(sony2fuji_session_set_ai_denoise_blend(session, 0.5f) == SONY2FUJI_STATUS_OK);
    REQUIRE(sony2fuji_session_set_ai_denoise_blend(session, 1.5f) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    REQUIRE(sony2fuji_session_set_ai_denoise_blend(session, 1.0f) == SONY2FUJI_STATUS_OK);

    sony2fuji_color_grading_v2_config cgV2{};
    cgV2.version = SONY2FUJI_COLOR_GRADING_V2_CONFIG_VERSION;
    cgV2.struct_size = sizeof(cgV2);
    cgV2.blending = 50.0f;
    REQUIRE(sony2fuji_session_set_color_grading_v2(session, &cgV2) == SONY2FUJI_STATUS_OK);

    sony2fuji_tone_curve_set_v2_config tcV2{};
    tcV2.version = SONY2FUJI_TONE_CURVE_SET_V2_CONFIG_VERSION;
    tcV2.struct_size = sizeof(tcV2);
    for (auto& c : tcV2.curves) {
        c.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
        c.struct_size = sizeof(c);
        c.mode = SONY2FUJI_CURVE_LEGACY;
    }
    tcV2.curves[0].mode = SONY2FUJI_CURVE_CUSTOM;
    tcV2.curves[0].count = 2;
    tcV2.curves[0].points[0] = {0.0, 0.1};
    tcV2.curves[0].points[1] = {1.0, 0.9};
    tcV2.parametric.version = SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION;
    tcV2.parametric.struct_size = sizeof(tcV2.parametric);
    tcV2.parametric.split_shadow = 0.25f;
    tcV2.parametric.split_midtone = 0.50f;
    tcV2.parametric.split_highlight = 0.75f;
    REQUIRE(sony2fuji_session_set_tone_curves_v2(session, &tcV2) == SONY2FUJI_STATUS_OK);

    const double xs[3] = {0.0, 0.5, 1.0};
    double ys[3] = {0.0, 0.0, 0.0};
    REQUIRE(sony2fuji_sample_tone_curve_v2(&tcV2.curves[0], &tcV2.parametric, xs, ys, 3) == SONY2FUJI_STATUS_OK);
    REQUIRE(std::abs(ys[0] - 0.1) < 1e-6 && std::abs(ys[1] - 0.5) < 1e-6 && std::abs(ys[2] - 0.9) < 1e-6);

    sony2fuji_buffer imgBuf{};
    imgBuf.data = const_cast<uint8_t*>(inputPixels.data());
    imgBuf.size_bytes = inputPixels.size();
    imgBuf.width = kWidth;
    imgBuf.height = kHeight;
    imgBuf.stride_bytes = kWidth * 4;
    imgBuf.pixel_format = SONY2FUJI_PIXEL_RGBA8;

    sony2fuji_bsh_diagnosis diag{};
    diag.version = SONY2FUJI_BSH_DIAGNOSIS_VERSION;
    diag.struct_size = sizeof(diag);
    REQUIRE(sony2fuji_diagnose_image(&imgBuf, nullptr, &diag) == SONY2FUJI_STATUS_OK);
    REQUIRE(diag.width == kWidth && diag.height == kHeight && diag.bit_depth == 8 && diag.channels == 4);

    sony2fuji_bsh_sample_query bshQ{SONY2FUJI_BSH_SAMPLE_VERSION, sizeof(bshQ), 0.5f, 0.5f, 0.02f, 0};
    sony2fuji_bsh_sample_result bshRes{};
    bshRes.version = SONY2FUJI_BSH_SAMPLE_VERSION;
    bshRes.struct_size = sizeof(bshRes);
    REQUIRE(sony2fuji_sample_region_bsh(&imgBuf, &bshQ, &bshRes) == SONY2FUJI_STATUS_OK);
    REQUIRE(bshRes.width == kWidth && bshRes.height == kHeight);

    const auto dispReq = makeDisplayRequest(inputPixels, kWidth, kHeight);
    sony2fuji_wb_probe_query wbQ{SONY2FUJI_WB_PROBE_VERSION, sizeof(wbQ), 0.5f, 0.5f, 3, 0};
    sony2fuji_wb_probe_result wbRes{};
    wbRes.version = SONY2FUJI_WB_PROBE_VERSION;
    wbRes.struct_size = sizeof(wbRes);
    REQUIRE(sony2fuji_session_sample_wb_probe(session, &dispReq, &wbQ, &wbRes) == SONY2FUJI_STATUS_OK);
    REQUIRE(wbRes.availability == SONY2FUJI_WB_PROBE_AVAILABLE);
    REQUIRE(wbRes.valid_pixel_count == 9);
    REQUIRE(wbRes.rejected_overexposed_count == 0);

    sony2fuji_wb_probe_query wbOutside{SONY2FUJI_WB_PROBE_VERSION, sizeof(wbOutside), -0.1f, 0.5f, 3, 0};
    sony2fuji_wb_probe_result wbOutRes{};
    wbOutRes.version = SONY2FUJI_WB_PROBE_VERSION;
    wbOutRes.struct_size = sizeof(wbOutRes);
    REQUIRE(sony2fuji_session_sample_wb_probe(session, &dispReq, &wbOutside, &wbOutRes) == SONY2FUJI_STATUS_OK);
    REQUIRE(wbOutRes.availability == SONY2FUJI_WB_PROBE_OUTSIDE);

    sony2fuji_request bufReq = dispReq;
    bufReq.input_type = SONY2FUJI_INPUT_BUFFER;
    sony2fuji_wb_probe_result wbBufRes{};
    wbBufRes.version = SONY2FUJI_WB_PROBE_VERSION;
    wbBufRes.struct_size = sizeof(wbBufRes);
    REQUIRE(sony2fuji_session_sample_wb_probe(session, &bufReq, &wbQ, &wbBufRes) == SONY2FUJI_STATUS_OK);
    REQUIRE(wbBufRes.availability == SONY2FUJI_WB_PROBE_UNAVAILABLE);

    sony2fuji_session_destroy(session);
    std::cout << "apply_params_api_tests passed\n";
    return 0;
}
