#include "test_harness.h"
#include "core/photo_bw_mixer.h"
#include "core/photo_calibration.h"
#include "core/photo_color_grading.h"
#include "core/photo_point_color.h"
#include "core/photo_selective_color.h"
#include "core/pipeline.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "nlohmann/json.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {

using Json = nlohmann::json;
using rawlab::test::checkPass;
using rawlab::test::requirePass;

double stdDev(const std::vector<double>& values) {
    if (values.empty()) return 0.0;
    double sum = 0.0;
    for (double v : values) sum += v;
    const double mean = sum / static_cast<double>(values.size());
    double var = 0.0;
    for (double v : values) {
        const double d = v - mean;
        var += d * d;
    }
    return std::sqrt(var / static_cast<double>(values.size()));
}

std::vector<uint8_t> makeLinearRgb8Buffer(const std::vector<sony2fuji::RGB>& pixels) {
    std::vector<uint8_t> buf;
    buf.reserve(pixels.size() * 3);
    auto q8 = [](float v) -> uint8_t {
        const long r = std::lround(std::clamp(v, 0.0f, 1.0f) * 255.0f);
        return static_cast<uint8_t>(std::clamp(r, 0L, 255L));
    };
    for (const auto& p : pixels) {
        buf.push_back(q8(p.r));
        buf.push_back(q8(p.g));
        buf.push_back(q8(p.b));
    }
    return buf;
}

std::vector<sony2fuji::RGB> makeColorfulGrid(int w, int h) {
    std::vector<sony2fuji::RGB> px(size_t(w) * h);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const float fx = float(x) / float(std::max(1, w - 1));
            const float fy = float(y) / float(std::max(1, h - 1));
            const int sector = (y * w + x) % 6;
            sony2fuji::RGB p;
            if (sector == 0) p = {0.06f + 0.55f * fx, 0.03f + 0.06f * fy, 0.02f + 0.04f * fy};
            else if (sector == 1) p = {0.03f + 0.05f * fx, 0.06f + 0.52f * fy, 0.03f + 0.08f * fx};
            else if (sector == 2) p = {0.02f + 0.07f * fy, 0.04f + 0.08f * fx, 0.07f + 0.58f * fx};
            else if (sector == 3) p = {0.42f * fx + 0.12f, 0.36f * fx + 0.09f, 0.05f * fy + 0.02f};
            else if (sector == 4) p = {0.32f * fy + 0.08f, 0.07f * fx + 0.03f, 0.44f * fx + 0.11f};
            else p = {0.04f + 0.72f * fx, 0.04f + 0.72f * fx, 0.04f + 0.72f * fx};
            px[size_t(y) * w + x] = p;
        }
    }
    return px;
}

struct RenderedRgb8 {
    int width = 0;
    int height = 0;
    std::vector<uint8_t> rgb8;
    sony2fuji_render_backend backend = SONY2FUJI_BACKEND_CPU;
};

RenderedRgb8 renderWithEditJson(
    const std::vector<sony2fuji::RGB>& linearPixels,
    int w,
    int h,
    const std::string& editStateJson,
    sony2fuji_gpu_mode gpuMode
) {
    sony2fuji_session* session = nullptr;
    requirePass(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK && session != nullptr,
        "sony2fuji_session_create succeeded");
    const sony2fuji_gpu_config gpuCfg{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpuCfg), gpuMode};
    requirePass(sony2fuji_session_set_gpu_config(session, &gpuCfg) == SONY2FUJI_STATUS_OK,
        "set_gpu_config succeeded");
    const sony2fuji_status editSt = sony2fuji_apply_params(session, editStateJson.c_str());
    requirePass(editSt == SONY2FUJI_STATUS_OK,
        std::string("sony2fuji_apply_params succeeded (") +
        (sony2fuji_status_message(editSt) ? sony2fuji_status_message(editSt) : "") + "): " + editStateJson);

    auto rawRgb8 = makeLinearRgb8Buffer(linearPixels);
    sony2fuji_request req{};
    req.version = SONY2FUJI_REQUEST_VERSION;
    req.struct_size = sizeof(req);
    req.input_type = SONY2FUJI_INPUT_BUFFER;
    req.input_width = static_cast<uint32_t>(w);
    req.input_height = static_cast<uint32_t>(h);
    req.input_pixels = rawRgb8.data();
    req.input_color_space = SONY2FUJI_COLOR_SRGB;
    req.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    req.input_is_linear = 1;
    req.wb_mode = SONY2FUJI_WB_CAMERA;
    req.wb_mul[0] = 1.0f;
    req.wb_mul[1] = 1.0f;
    req.wb_mul[2] = 1.0f;
    req.wb_mul[3] = 1.0f;
    req.temperature = 6500.0f;
    req.size_mode = SONY2FUJI_SIZE_NATIVE;
    req.output_target = SONY2FUJI_TARGET_BUFFER;
    req.output_format = SONY2FUJI_OUTPUT_RGB8;
    req.intent = SONY2FUJI_INTENT_FINAL;
    req.brightness = 1.0f;
    req.contrast = 1.0f;
    req.saturation = 1.0f;
    req.lut_strength = 1.0f;

    sony2fuji_buffer outBuf{};
    const sony2fuji_status st = sony2fuji_process(session, &req, &outBuf);
    requirePass(st == SONY2FUJI_STATUS_OK,
        std::string(gpuMode == SONY2FUJI_GPU_FORCE ? "Force GPU render succeeded (" : "CPU render succeeded (") +
        (sony2fuji_status_message(st) ? sony2fuji_status_message(st) : "") + ")");

    RenderedRgb8 out;
    out.width = static_cast<int>(outBuf.width);
    out.height = static_cast<int>(outBuf.height);
    const auto* bytes = static_cast<const uint8_t*>(outBuf.data);
    out.rgb8.assign(bytes, bytes + outBuf.size_bytes);
    out.backend = sony2fuji_session_get_last_backend(session);
    sony2fuji_release_buffer(&outBuf);
    sony2fuji_session_destroy(session);
    return out;
}

int maxRgb8Diff(const RenderedRgb8& a, const RenderedRgb8& b) {
    requirePass(a.rgb8.size() == b.rgb8.size(), "rendered buffer sizes match");
    int maxDiff = 0;
    for (size_t i = 0; i < a.rgb8.size(); ++i) {
        const int d = std::abs(int(a.rgb8[i]) - int(b.rgb8[i]));
        if (d > maxDiff) maxDiff = d;
    }
    return maxDiff;
}

std::string makeBaseEditStateJson(const Json& colorObj, const Json& colorGradingObj = Json()) {
    Json edits = {
        {"exposure", {{"mode", "scene"}}},
        {"white_balance", {{"mode", "camera"}}},
        {"color", colorObj}
    };
    if (!colorGradingObj.is_null()) {
        edits["color_grading"] = colorGradingObj;
    }
    Json root = {
        {"schema_version", 20},
        {"x3f_mode", "legacy"},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"input", {{"path", "photo.dng"}, {"type", "raw"}}},
        {"edits", std::move(edits)},
        {"output", {{"path", "out.png"}, {"format", "png"}, {"size", {{"mode", "native"}}}}}
    };
    return root.dump();
}

void testCalibrationNeutralInvariant() {
    // 256-step linear ramp covering full grayscale range.
    std::vector<sony2fuji::RGB> ramp(256);
    for (int i = 0; i < 256; ++i) {
        const float v = static_cast<float>(i) / 255.0f;
        ramp[i] = {v, v, v};
    }

    const std::array<sony2fuji::CameraCalibrationOptions, 4> extremes = {{
        {0.0f, 100.0f, 100.0f, -100.0f, 100.0f, 100.0f, -100.0f},
        {0.0f, -100.0f, -100.0f, 100.0f, -100.0f, -100.0f, 100.0f},
        {0.0f, 100.0f, -100.0f, 100.0f, 100.0f, -100.0f, -100.0f},
        {0.0f, -100.0f, 100.0f, -100.0f, -100.0f, 100.0f, 100.0f},
    }};

    for (size_t idx = 0; idx < extremes.size(); ++idx) {
        sony2fuji::ImageData img(256, 1);
        img.pixels = ramp;
        sony2fuji::applyCameraCalibration(img, extremes[idx]);
        float maxCast = 0.0f;
        for (int i = 0; i < 256; ++i) {
            const auto& p = img.pixels[i];
            maxCast = std::max(maxCast, std::abs(p.r - p.g));
            maxCast = std::max(maxCast, std::abs(p.g - p.b));
            maxCast = std::max(maxCast, std::abs(p.r - ramp[i].r));
        }
        checkPass(maxCast == 0.0f, "256-step calibration grayscale invariant extreme #" + std::to_string(idx));

        const Json calJson = {
            {"calibration", {
                {"shadow_tint", 0.0},
                {"red_hue", extremes[idx].redHue},
                {"red_saturation", extremes[idx].redSaturation},
                {"green_hue", extremes[idx].greenHue},
                {"green_saturation", extremes[idx].greenSaturation},
                {"blue_hue", extremes[idx].blueHue},
                {"blue_saturation", extremes[idx].blueSaturation},
            }}
        };
        const auto rendered = renderWithEditJson(ramp, 256, 1, makeBaseEditStateJson(calJson), SONY2FUJI_GPU_OFF);
        int maxByteCast = 0;
        for (int i = 0; i < 256; ++i) {
            const int r = rendered.rgb8[i * 3 + 0];
            const int g = rendered.rgb8[i * 3 + 1];
            const int b = rendered.rgb8[i * 3 + 2];
            maxByteCast = std::max(maxByteCast, std::abs(r - g));
            maxByteCast = std::max(maxByteCast, std::abs(g - b));
        }
        checkPass(maxByteCast == 0, "256-step pipeline calibration RGB8 grayscale invariant #" + std::to_string(idx));
    }

    // Shadow tint shifts shadow grays without casting highlights.
    sony2fuji::ImageData tintImg(2, 1);
    tintImg.pixels[0] = {0.03f, 0.03f, 0.03f};
    tintImg.pixels[1] = {0.75f, 0.75f, 0.75f};
    sony2fuji::CameraCalibrationOptions tintOpts;
    tintOpts.shadowTint = 80.0f; // magenta in shadows
    sony2fuji::applyCameraCalibration(tintImg, tintOpts);
    checkPass(tintImg.pixels[0].r > tintImg.pixels[0].g && tintImg.pixels[0].b > tintImg.pixels[0].g,
        "positive shadowTint adds magenta tint to shadows");
    checkPass(std::abs(tintImg.pixels[1].r - tintImg.pixels[1].g) < 1e-6f,
        "shadowTint preserves bright neutral highlights");
}

void testPointColorVarianceAndPreview() {
    // 16x16 mottled skin patch surrounded by non-skin blue/green border.
    constexpr int W = 16;
    constexpr int H = 16;
    sony2fuji::ImageData baseImg(W, H);
    const float anchorH = 18.0f;
    const float anchorS = 0.46f;
    const float anchorL = 0.68f;
    float anchorRgb[3]{};
    sony2fuji::pointColorHsbToRgb(anchorH, anchorS, anchorL, anchorRgb);

    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            const size_t idx = size_t(y) * W + x;
            if (x >= 2 && x <= 13 && y >= 2 && y <= 13) {
                const float hJitter = float((x * 7 + y * 5) % 19) - 9.0f; // +/- 9 deg around anchor
                const float sJitter = (float((x * 3 + y * 11) % 11) - 5.0f) * 0.015f;
                const float lJitter = (float((x * 5 + y * 3) % 11) - 5.0f) * 0.018f;
                float rgb[3]{};
                sony2fuji::pointColorHsbToRgb(anchorH + hJitter, anchorS + sJitter, anchorL + lJitter, rgb);
                baseImg.pixels[idx] = {rgb[0], rgb[1], rgb[2]};
            } else {
                // Distinct cool blue-cyan background far from skin anchor.
                baseImg.pixels[idx] = {0.10f, 0.45f, 0.85f};
            }
        }
    }

    auto measureSkinStd = [&](float variance) -> std::pair<double, double> {
        sony2fuji::ImageData work = baseImg;
        sony2fuji::PointColorOptions opts;
        opts.swatchCount = 1;
        opts.swatches[0].srcHue = anchorH;
        opts.swatches[0].srcSaturation = anchorS;
        opts.swatches[0].srcLuminance = anchorL;
        opts.swatches[0].variance = variance;
        opts.swatches[0].range = 60.0f;
        sony2fuji::applyPointColor(work, opts);

        // Background pixels outside mask must stay bit-exact untouched.
        checkPass(work.pixels[0].r == baseImg.pixels[0].r &&
                  work.pixels[0].g == baseImg.pixels[0].g &&
                  work.pixels[0].b == baseImg.pixels[0].b,
            "point color non-matching blue pixel untouched for variance " + std::to_string(int(variance)));

        std::vector<double> hues;
        std::vector<double> lums;
        for (int y = 2; y <= 13; ++y) {
            for (int x = 2; x <= 13; ++x) {
                const auto& p = work.pixels[size_t(y) * W + x];
                float hh = 0.0f, ss = 0.0f, ll = 0.0f;
                sony2fuji::pointColorRgbToHsb(p.r, p.g, p.b, hh, ss, ll);
                double dh = hh - anchorH;
                if (dh > 180.0) dh -= 360.0;
                if (dh < -180.0) dh += 360.0;
                hues.push_back(dh);
                lums.push_back(ll);
            }
        }
        return {stdDev(hues), stdDev(lums)};
    };

    const auto [hStd0, lStd0] = measureSkinStd(0.0f);
    const auto [hStd30, lStd30] = measureSkinStd(-30.0f);
    const auto [hStd60, lStd60] = measureSkinStd(-60.0f);
    checkPass(hStd60 < hStd30 && hStd30 < hStd0, "Point Color negative variance monotonically reduces Hue std-dev");
    checkPass(lStd60 < lStd30 && lStd30 < lStd0, "Point Color negative variance monotonically reduces Luminance std-dev");

    // Smooth boundary ramp with no hard step tears.
    sony2fuji::ImageData ramp(64, 1);
    for (int i = 0; i < 64; ++i) {
        float rgb[3]{};
        const float h = 350.0f + float(i) * 1.5f; // crosses 0 -> 86 deg smoothly
        sony2fuji::pointColorHsbToRgb(std::fmod(h, 360.0f), anchorS, anchorL, rgb);
        ramp.pixels[i] = {rgb[0], rgb[1], rgb[2]};
    }
    sony2fuji::PointColorOptions rampOpts;
    rampOpts.swatchCount = 1;
    rampOpts.swatches[0].srcHue = 20.0f;
    rampOpts.swatches[0].srcSaturation = anchorS;
    rampOpts.swatches[0].srcLuminance = anchorL;
    rampOpts.swatches[0].variance = -60.0f;
    rampOpts.swatches[0].hueShift = 25.0f;
    sony2fuji::applyPointColor(ramp, rampOpts);
    float maxAdjStep = 0.0f;
    for (int i = 1; i < 64; ++i) {
        maxAdjStep = std::max(maxAdjStep, std::abs(ramp.pixels[i].r - ramp.pixels[i - 1].r));
        maxAdjStep = std::max(maxAdjStep, std::abs(ramp.pixels[i].g - ramp.pixels[i - 1].g));
        maxAdjStep = std::max(maxAdjStep, std::abs(ramp.pixels[i].b - ramp.pixels[i - 1].b));
    }
    checkPass(maxAdjStep < 0.05f, "Point Color variance & shift boundary transition is smooth without hard tears");

    // C ABI swatch preview matches exact core HSB transform.
    float srcRgb[3]{}, shiftedRgb[3]{};
    const auto previewSt = sony2fuji_point_color_preview_swatch(
        anchorH, anchorS, anchorL, 25.0f, -20.0f, 15.0f, srcRgb, shiftedRgb);
    checkPass(previewSt == SONY2FUJI_STATUS_OK, "C ABI point_color_preview_swatch returns OK");
    checkPass(std::abs(srcRgb[0] - anchorRgb[0]) < 1e-5f && shiftedRgb[1] > srcRgb[1],
        "C ABI point_color_preview_swatch matches core HSB and reflects hue shift");
}

void testSelectiveColor9Bands() {
    const std::array<sony2fuji::RGB, 9> samples = {{
        {1.0f, 0.0f, 0.0f}, // 0 reds
        {1.0f, 1.0f, 0.0f}, // 1 yellows
        {0.0f, 1.0f, 0.0f}, // 2 greens
        {0.0f, 1.0f, 1.0f}, // 3 cyans
        {0.0f, 0.0f, 1.0f}, // 4 blues
        {1.0f, 0.0f, 1.0f}, // 5 magentas
        {1.0f, 1.0f, 1.0f}, // 6 whites
        {0.5f, 0.5f, 0.5f}, // 7 neutrals
        {0.0f, 0.0f, 0.0f}, // 8 blacks
    }};

    for (size_t targetBand = 0; targetBand < 9; ++targetBand) {
        sony2fuji::ImageData img(9, 1);
        img.pixels.assign(samples.begin(), samples.end());
        sony2fuji::SelectiveColorOptions opts;
        opts.method = sony2fuji::SelectiveColorMethod::Absolute;
        if (targetBand == 8) {
            // Pure black (0,0,0) shifts upward when removing ink in Absolute mode.
            opts.bands[targetBand].cyan = -30.0f;
            opts.bands[targetBand].black = -20.0f;
        } else {
            opts.bands[targetBand].cyan = 40.0f;
            opts.bands[targetBand].black = 20.0f;
        }
        sony2fuji::applySelectiveColor(img, opts);

        for (size_t i = 0; i < 9; ++i) {
            const float diff =
                std::abs(img.pixels[i].r - samples[i].r) +
                std::abs(img.pixels[i].g - samples[i].g) +
                std::abs(img.pixels[i].b - samples[i].b);
            if (i == targetBand) {
                checkPass(diff > 0.05f, "Selective Color Absolute shifts canonical band #" + std::to_string(targetBand));
            } else {
                checkPass(diff < 1e-5f, "Selective Color keeps other canonical band #" + std::to_string(i) + " isolated");
            }
        }
    }

    // Relative vs Absolute behavior: pure white untouched by Relative Whites, shifted by Absolute Whites;
    // midgray shifts stronger under Absolute than Relative.
    sony2fuji::ImageData relImg(2, 1), absImg(2, 1);
    relImg.pixels[0] = {1.0f, 1.0f, 1.0f};
    relImg.pixels[1] = {0.5f, 0.5f, 0.5f};
    absImg.pixels = relImg.pixels;

    sony2fuji::SelectiveColorOptions scRel;
    scRel.method = sony2fuji::SelectiveColorMethod::Relative;
    scRel.bands[6].cyan = 60.0f; // whites
    scRel.bands[7].cyan = 60.0f; // neutrals

    sony2fuji::SelectiveColorOptions scAbs = scRel;
    scAbs.method = sony2fuji::SelectiveColorMethod::Absolute;

    sony2fuji::applySelectiveColor(relImg, scRel);
    sony2fuji::applySelectiveColor(absImg, scAbs);

    checkPass(relImg.pixels[0].r == 1.0f && absImg.pixels[0].r < 0.5f,
        "Relative Whites preserves pure (1,1,1) white while Absolute tints it");
    checkPass(relImg.pixels[1].r > absImg.pixels[1].r && relImg.pixels[1].r < 0.5f,
        "Relative Neutrals shifts proportionally smaller than Absolute Neutrals");
}

void testBwMixerAndSplitToneOrder() {
    const std::vector<sony2fuji::RGB> colors = {
        {0.35f, 0.03f, 0.02f}, // Red patch
        {0.02f, 0.03f, 0.40f}, // Blue patch
        {0.02f, 0.02f, 0.02f}, // Shadow gray
        {0.65f, 0.65f, 0.65f}, // Highlight gray
    };

    // Default weights (0) B&W produces neutral monochrome image.
    const Json bwNeutral = {
        {"bw", {{"enabled", true}, {"mixer", Json::object()}}}
    };
    const auto monoOut = renderWithEditJson(colors, 4, 1, makeBaseEditStateJson(bwNeutral), SONY2FUJI_GPU_OFF);
    for (int i = 0; i < 4; ++i) {
        checkPass(monoOut.rgb8[i * 3] == monoOut.rgb8[i * 3 + 1] && monoOut.rgb8[i * 3 + 1] == monoOut.rgb8[i * 3 + 2],
            "B&W neutral mixer renders exact R==G==B #" + std::to_string(i));
    }

    // Channel mixer separates Red (+80) from Blue (-80).
    const Json bwFiltered = {
        {"bw", {{"enabled", true}, {"mixer", {{"red", 80.0}, {"blue", -80.0}}}}}
    };
    const auto filteredOut = renderWithEditJson(colors, 4, 1, makeBaseEditStateJson(bwFiltered), SONY2FUJI_GPU_OFF);
    checkPass(filteredOut.rgb8[0] > monoOut.rgb8[0], "B&W mixer red=+80 brightens red patch");
    checkPass(filteredOut.rgb8[3] < monoOut.rgb8[3], "B&W mixer blue=-80 darkens blue patch");

    // B&W before Color Grading v2 allows split-toning B&W images cleanly.
    const Json bwSplit = {
        {"bw", {{"enabled", true}, {"mixer", Json::object()}}}
    };
    const Json bwSplitGrading = {
        {"shadows", {{"hue", 220.0}, {"saturation", 65.0}, {"luminance", 0.0}}},
        {"highlights", {{"hue", 40.0}, {"saturation", 65.0}, {"luminance", 0.0}}},
        {"blending", 50.0},
        {"balance", 0.0}
    };
    const auto splitOut = renderWithEditJson(colors, 4, 1, makeBaseEditStateJson(bwSplit, bwSplitGrading), SONY2FUJI_GPU_OFF);
    // Pixel 2 is shadow gray -> cool blue shadow tint (B > R).
    checkPass(splitOut.rgb8[2 * 3 + 2] > splitOut.rgb8[2 * 3 + 0],
        "B&W + Color Grading v2 cool shadow split-tones shadow pixel blue");
    // Pixel 3 is highlight gray -> warm orange highlight tint (R > B).
    checkPass(splitOut.rgb8[3 * 3 + 0] > splitOut.rgb8[3 * 3 + 2],
        "B&W + Color Grading v2 warm highlight split-tones highlight pixel warm");
}

void testZeroValueExactBypass() {
    const auto grid = makeColorfulGrid(24, 16);
    const std::string emptyEdit = makeBaseEditStateJson(Json::object());
    const std::string defaultV14Edit = makeBaseEditStateJson({
        {"calibration", {
            {"shadow_tint", 0.0}, {"red_hue", 0.0}, {"red_saturation", 0.0},
            {"green_hue", 0.0}, {"green_saturation", 0.0}, {"blue_hue", 0.0}, {"blue_saturation", 0.0}
        }},
        {"point_color", {{"swatches", Json::array()}}},
        {"selective_color", {{"method", "relative"}, {"bands", Json::object()}}},
        {"bw", {{"enabled", false}, {"mixer", Json::object()}}}
    });
    const auto a = renderWithEditJson(grid, 24, 16, emptyEdit, SONY2FUJI_GPU_OFF);
    const auto b = renderWithEditJson(grid, 24, 16, defaultV14Edit, SONY2FUJI_GPU_OFF);
    checkPass(maxRgb8Diff(a, b) == 0, "Zero-value v0.14 color science exact bypass max_diff == 0");
}

void testMetalForceGpuAndParity() {
    const auto grid = makeColorfulGrid(32, 24);

    // Build combined Track A color science state exercising all 4 features together.
    const Json combined = {
        {"calibration", {
            {"shadow_tint", -25.0}, {"red_hue", 35.0}, {"red_saturation", 25.0},
            {"green_hue", -20.0}, {"green_saturation", 15.0}, {"blue_hue", 40.0}, {"blue_saturation", -15.0}
        }},
        {"point_color", {{"swatches", {{
            {"src_hue", 22.0}, {"src_saturation", 0.55}, {"src_luminance", 0.55},
            {"hue_shift", 18.0}, {"saturation_shift", -25.0}, {"luminance_shift", 12.0},
            {"variance", -45.0}, {"range", 65.0}, {"hue_range", 55.0}, {"sat_range", 50.0}, {"lum_range", 50.0},
            {"enabled", true}
        }}}}},
        {"selective_color", {
            {"method", "relative"},
            {"bands", {
                {"reds", {{"cyan", -20.0}, {"magenta", 15.0}, {"yellow", 10.0}, {"black", -10.0}}},
                {"blues", {{"cyan", 25.0}, {"magenta", -15.0}, {"yellow", -10.0}, {"black", 15.0}}},
                {"neutrals", {{"cyan", 8.0}, {"magenta", 0.0}, {"yellow", -8.0}, {"black", 5.0}}}
            }}
        }}
    };
    const Json combinedGrading = {
        {"shadows", {{"hue", 215.0}, {"saturation", 30.0}, {"luminance", -10.0}}},
        {"highlights", {{"hue", 42.0}, {"saturation", 25.0}, {"luminance", 10.0}}},
        {"blending", 60.0}, {"balance", 15.0}
    };
    const Json bwCombined = {
        {"calibration", {{"shadow_tint", 30.0}, {"red_hue", -40.0}, {"blue_saturation", 50.0}}},
        {"bw", {{"enabled", true}, {"mixer", {{"red", 45.0}, {"yellow", 20.0}, {"blue", -55.0}}}}},
        {"selective_color", {{"method", "absolute"}, {"bands", {{"neutrals", {{"cyan", 10.0}, {"black", 12.0}}}}}}}
    };
    const Json bwCombinedGrading = {
        {"highlights", {{"hue", 35.0}, {"saturation", 40.0}, {"luminance", 5.0}}}
    };

    const auto cpuCombined = renderWithEditJson(grid, 32, 24, makeBaseEditStateJson(combined, combinedGrading), SONY2FUJI_GPU_OFF);
    const auto gpuCombined = renderWithEditJson(grid, 32, 24, makeBaseEditStateJson(combined, combinedGrading), SONY2FUJI_GPU_FORCE);
    checkPass(gpuCombined.backend == SONY2FUJI_BACKEND_METAL, "Metal Force GPU backend active for color science");
    checkPass(maxRgb8Diff(cpuCombined, gpuCombined) <= 2,
        "CPU vs Metal RGB8 parity <= 2 for combined calibration + point_color + selective_color (maxDiff=" +
        std::to_string(maxRgb8Diff(cpuCombined, gpuCombined)) + ")");

    const auto cpuBw = renderWithEditJson(grid, 32, 24, makeBaseEditStateJson(bwCombined, bwCombinedGrading), SONY2FUJI_GPU_OFF);
    const auto gpuBw = renderWithEditJson(grid, 32, 24, makeBaseEditStateJson(bwCombined, bwCombinedGrading), SONY2FUJI_GPU_FORCE);
    checkPass(gpuBw.backend == SONY2FUJI_BACKEND_METAL, "Metal Force GPU backend active for B&W + split tone");
    checkPass(maxRgb8Diff(cpuBw, gpuBw) <= 2,
        "CPU vs Metal RGB8 parity <= 2 for B&W + selective_color + grading (maxDiff=" +
        std::to_string(maxRgb8Diff(cpuBw, gpuBw)) + ")");
}

} // namespace

int main(int argc, char** argv) {
    try {
        bool runMetal = false;
        for (int i = 1; i < argc; ++i) {
            if (std::string(argv[i]) == "--metal") {
                runMetal = true;
            }
        }
        if (runMetal) {
            testMetalForceGpuAndParity();
        } else {
            testCalibrationNeutralInvariant();
            testPointColorVarianceAndPreview();
            testSelectiveColor9Bands();
            testBwMixerAndSplitToneOrder();
            testZeroValueExactBypass();
        }
        return rawlab::test::exitCode();
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
