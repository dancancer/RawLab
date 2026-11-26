#include "core/photo_effects.h"
#include "core/photo_film_optics.h"
#include "core/photo_geometry.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "native_gpu_test_support.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

using namespace sony2fuji;

namespace {

ImageData makeTarget(int w, int h, float bg = 0.12f, float boxRel = 0.12f) {
    ImageData img(w, h);
    std::fill(img.pixels.begin(), img.pixels.end(), RGB{bg, bg, bg});
    const int halfW = std::max(2, int(std::lround(w * boxRel * 0.5f)));
    const int halfH = std::max(2, int(std::lround(h * boxRel * 0.5f)));
    const int cx = w / 2, cy = h / 2;
    for (int y = std::max(0, cy - halfH); y < std::min(h, cy + halfH); ++y) {
        for (int x = std::max(0, cx - halfW); x < std::min(w, cx + halfW); ++x) {
            img.at(x, y) = {1.0f, 1.0f, 1.0f};
        }
    }
    return img;
}

double measureNormalizedHalfMaxWidth(const ImageData& img, float bg, bool checkRedMinusBg) {
    const int cx = img.width / 2;
    const int cy = img.height / 2;
    const int halfW = std::max(2, int(std::lround(img.width * 0.12f * 0.5f)));
    const int edgeX = cx + halfW;
    const int startX = std::min(img.width - 1, edgeX + 1);
    const float peakExcess = (checkRedMinusBg ? img.at(startX, cy).r : img.at(startX, cy).g) - bg;
    assert(peakExcess > 0.01f);
    const float halfExcess = peakExcess * 0.5f;
    double halfDistPx = 0.0;
    for (int x = startX; x < img.width; ++x) {
        const float v = (checkRedMinusBg ? img.at(x, cy).r : img.at(x, cy).g) - bg;
        if (v <= halfExcess) {
            const float prev = x > startX ? ((checkRedMinusBg ? img.at(x - 1, cy).r : img.at(x - 1, cy).g) - bg) : peakExcess;
            const float frac = (prev > v) ? std::clamp((prev - halfExcess) / (prev - v), 0.0f, 1.0f) : 0.0f;
            halfDistPx = double(x - edgeX - 1) + double(frac);
            break;
        }
    }
    assert(halfDistPx > 0.5);
    const double diag = std::hypot(double(img.width), double(img.height));
    return halfDistPx / diag;
}

double channelStdDev(const ImageData& img, float expectedMeanApprox) {
    double sum = 0.0;
    for (const auto& p : img.pixels) sum += p.r;
    const double mean = sum / double(img.pixels.size());
    (void)expectedMeanApprox;
    double sq = 0.0;
    for (const auto& p : img.pixels) {
        const double d = double(p.r) - mean;
        sq += d * d;
    }
    return std::sqrt(sq / double(img.pixels.size()));
}

void testHalationEdgeAndNeutralInterior() {
    const float bg = 0.12f;
    ImageData img = makeTarget(640, 480, bg);
    FilmOpticsOptions opt;
    opt.halationAmount = 80.0f;
    opt.halationThreshold = 75.0f;
    opt.halationRadius = 35.0f;
    opt.halationHue = 0.0f;
    applyFilmOptics(img, opt);

    const int cy = 240;
    const int halfW = std::max(2, int(std::lround(640 * 0.12f * 0.5f)));
    const int outerX = 320 + halfW + 4;
    const RGB halo = img.at(outerX, cy);
    assert(halo.r > halo.g && halo.g > halo.b);
    assert(halo.r - bg > 0.04f);

    // Distant dark interior must stay strictly neutral with |R - B| == 0.
    const RGB distant = img.at(12, 12);
    assert(std::abs(distant.r - distant.b) == 0.0f);
    assert(distant.r == bg && distant.g == bg && distant.b == bg);

    // Hue shift (-100 crimson -> +100 warm orange-red) increases green/red ratio monotonically.
    opt.halationHue = -100.0f;
    ImageData crimson = makeTarget(320, 240, bg);
    applyFilmOptics(crimson, opt);
    opt.halationHue = 100.0f;
    ImageData orange = makeTarget(320, 240, bg);
    applyFilmOptics(orange, opt);
    const int testX = 160 + std::max(2, int(std::lround(320 * 0.12f * 0.5f))) + 2;
    const RGB hc = crimson.at(testX, 120);
    const RGB ho = orange.at(testX, 120);
    assert(hc.r > hc.g && hc.g > hc.b);
    assert(ho.r > ho.g && ho.g > ho.b);
    assert((ho.g - bg) > (hc.g - bg) + 0.005f);
    std::cout << "PASS: halation R>G>B glow, hue shift, and zero-cast neutral dark interior\n";
}

void testBloomAndScaleInvariance() {
    const float bg = 0.10f;
    FilmOpticsOptions hal;
    hal.halationAmount = 75.0f;
    hal.halationThreshold = 70.0f;
    hal.halationRadius = 35.0f;

    ImageData h1280 = makeTarget(1280, 960, bg);
    ImageData h2560 = makeTarget(2560, 1920, bg);
    applyFilmOptics(h1280, hal);
    applyFilmOptics(h2560, hal);
    const double wH1 = measureNormalizedHalfMaxWidth(h1280, bg, true);
    const double wH2 = measureNormalizedHalfMaxWidth(h2560, bg, true);
    const double relHalDiff = std::abs(wH1 - wH2) / std::max(wH1, wH2);
    assert(relHalDiff <= 0.10);

    FilmOpticsOptions bloom;
    bloom.bloomAmount = 75.0f;
    bloom.bloomThreshold = 65.0f;
    bloom.bloomRadius = 40.0f;

    ImageData b1280 = makeTarget(1280, 960, bg);
    ImageData b2560 = makeTarget(2560, 1920, bg);
    applyFilmOptics(b1280, bloom);
    applyFilmOptics(b2560, bloom);
    const double wB1 = measureNormalizedHalfMaxWidth(b1280, bg, false);
    const double wB2 = measureNormalizedHalfMaxWidth(b2560, bg, false);
    const double relBloomDiff = std::abs(wB1 - wB2) / std::max(wB1, wB2);
    assert(relBloomDiff <= 0.10);

    const RGB bloomOuter = b1280.at(640 + int(std::lround(1280 * 0.06f)) + 4, 480);
    assert(bloomOuter.r > bg + 0.02f && std::abs(bloomOuter.r - bloomOuter.b) < 1e-5f);
    std::cout << "PASS: 1280px vs 2560px normalized halo/bloom half-max width invariance ("
              << relHalDiff * 100.0 << "%, " << relBloomDiff * 100.0 << "%)\n";
}

void testZeroBypassAndFieldRoi() {
    ImageData base = makeTarget(256, 192, 0.25f);
    ImageData copy = base;
    applyFilmOptics(copy, FilmOpticsOptions{});
    for (size_t i = 0; i < base.pixels.size(); ++i) {
        assert(copy.pixels[i].r == base.pixels[i].r &&
               copy.pixels[i].g == base.pixels[i].g &&
               copy.pixels[i].b == base.pixels[i].b);
    }

    FilmOpticsOptions opt;
    opt.halationAmount = 60.0f;
    opt.bloomAmount = 40.0f;
    ImageData full = makeTarget(320, 240, 0.12f);
    applyFilmOptics(full, opt);

    const ImageData src = makeTarget(320, 240, 0.12f);
    const FilmOpticsField field = buildFilmOpticsField(src, 320, 240, opt);
    SubRectMap roi{320, 240, 80.0, 60.0, 160.0, 120.0};
    ImageData sub(160, 120);
    for (int y = 0; y < 120; ++y) {
        for (int x = 0; x < 160; ++x) {
            sub.at(x, y) = src.at(80 + x, 60 + y);
        }
    }
    applyFilmOpticsWithField(sub, field, opt, roi);
    for (int y = 0; y < 120; ++y) {
        for (int x = 0; x < 160; ++x) {
            const RGB pFull = full.at(80 + x, 60 + y);
            const RGB pSub = sub.at(x, y);
            assert(std::abs(pFull.r - pSub.r) < 0.01f &&
                   std::abs(pFull.g - pSub.g) < 0.01f &&
                   std::abs(pFull.b - pSub.b) < 0.01f);
        }
    }
    std::cout << "PASS: film optics zero-value bypass and ROI field consistency\n";
}

void testNegativeAsymmetricGrainAndPresets() {
    auto flatPatch = [](float val) {
        ImageData img(256, 256);
        std::fill(img.pixels.begin(), img.pixels.end(), RGB{val, val, val});
        return img;
    };

    // Legacy + Custom must match v0.13 reference formula byte-for-byte.
    PhotoEffectsOptions legacy;
    legacy.grainAmount = 50.0f;
    legacy.grainSize = 25.0f;
    legacy.grainRoughness = 50.0f;
    legacy.grainToneCurve = GrainToneCurve::Legacy;
    legacy.grainFormatPreset = GrainFormatPreset::Custom;
    ImageData legacyImg = flatPatch(0.50f);
    applyPhotoEffects(legacyImg, legacy);
    PhotoEffectSampler sampler(legacy, 256, 256);
    for (int y = 0; y < 256; ++y) {
        for (int x = 0; x < 256; ++x) {
            const RGB expected = sampler.applySRGB({0.5f, 0.5f, 0.5f}, x, y);
            const RGB actual = legacyImg.at(x, y);
            assert(actual.r == expected.r && actual.g == expected.g && actual.b == expected.b);
        }
    }
    assert(grainToneWeight(0.5f, GrainToneCurve::Legacy) == 1.0f);
    assert(std::abs(grainToneWeight(0.25f, GrainToneCurve::Legacy) - std::sqrt(0.75f)) < 1e-6f);

    // NegativeAsymmetric: highlight L=0.95 stddev < 0.35x shadow L=0.25 and midtone L=0.50 stddev.
    PhotoEffectsOptions asym = legacy;
    asym.grainToneCurve = GrainToneCurve::NegativeAsymmetric;
    ImageData shadowImg = flatPatch(0.25f);
    ImageData midImg = flatPatch(0.50f);
    ImageData highImg = flatPatch(0.95f);
    applyPhotoEffects(shadowImg, asym);
    applyPhotoEffects(midImg, asym);
    applyPhotoEffects(highImg, asym);
    const double sdShadow = channelStdDev(shadowImg, 0.25f);
    const double sdMid = channelStdDev(midImg, 0.50f);
    const double sdHigh = channelStdDev(highImg, 0.95f);
    assert(sdShadow > 0.004 && sdMid > 0.0025);
    assert(sdHigh < 0.35 * sdShadow);
    assert(sdHigh < 0.35 * sdMid);

    // Format presets 135 vs 120 vs Custom produce consistent distinct textures.
    PhotoEffectsOptions p135 = asym;
    p135.grainFormatPreset = GrainFormatPreset::Film135;
    PhotoEffectsOptions p120 = asym;
    p120.grainFormatPreset = GrainFormatPreset::Film120;
    assert(resolveGrainSize(25.0f, GrainFormatPreset::Film135) == 18.0f);
    assert(resolveGrainRoughness(50.0f, GrainFormatPreset::Film135) == 65.0f);
    assert(resolveGrainSize(25.0f, GrainFormatPreset::Film120) == 34.0f);
    assert(resolveGrainRoughness(50.0f, GrainFormatPreset::Film120) == 22.0f);
    ImageData img135 = flatPatch(0.35f);
    ImageData img120 = flatPatch(0.35f);
    applyPhotoEffects(img135, p135);
    applyPhotoEffects(img120, p120);
    bool diff = false;
    for (size_t i = 0; i < img135.pixels.size(); ++i) {
        if (img135.pixels[i].r != img120.pixels[i].r) {
            diff = true;
            break;
        }
    }
    assert(diff);
    std::cout << "PASS: NegativeAsymmetric grain distribution (hi/mid="
              << (sdHigh / sdMid) << ", hi/sh=" << (sdHigh / sdShadow) << ") & 135/120 presets\n";
}

void testApiParityAndForceGpu() {
    const int W = 320, H = 240;
    std::vector<uint8_t> rgbInput(size_t(W) * H * 3, 28);
    for (int y = 96; y < 144; ++y) {
        for (int x = 136; x < 184; ++x) {
            const size_t idx = (size_t(y) * W + x) * 3;
            rgbInput[idx + 0] = 250;
            rgbInput[idx + 1] = 248;
            rgbInput[idx + 2] = 245;
        }
    }

    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);

    const char* defaultJson = R"json({
        "schema_version": 5,
        "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
        "input": {"path": "memory.png", "type": "raster"},
        "edits": {
            "exposure": {"mode": "sensor", "ev": 0.0, "brightness": 1.0},
            "white_balance": {"mode": "none"},
            "look": {"path": null, "strength": 1.0},
            "effects": {}
        },
        "output": {"path": "out.png", "format": "png", "size": {"mode": "native"}}
    })json";
    assert(sony2fuji_apply_params(session, defaultJson) == SONY2FUJI_STATUS_OK);

    auto makeReq = [&](sony2fuji_intent intent) {
        sony2fuji_request req{};
        req.version = SONY2FUJI_REQUEST_VERSION;
        req.struct_size = sizeof(req);
        req.input_type = SONY2FUJI_INPUT_BUFFER;
        req.input_pixels = rgbInput.data();
        req.input_width = static_cast<uint32_t>(W);
        req.input_height = static_cast<uint32_t>(H);
        req.input_is_linear = 0;
        req.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
        req.input_color_space = SONY2FUJI_COLOR_SRGB;
        req.brightness = 1.0f;
        req.contrast = 1.0f;
        req.saturation = 1.0f;
        req.temperature = 6500.0f;
        req.sharpening = 0.25f;
        req.size_mode = SONY2FUJI_SIZE_NATIVE;
        req.intent = intent;
        req.output_target = SONY2FUJI_TARGET_BUFFER;
        req.output_format = SONY2FUJI_OUTPUT_RGB8;
        return req;
    };

    auto runWithGpuMode = [&](sony2fuji_gpu_mode mode, sony2fuji_intent intent) {
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), mode};
        assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
        sony2fuji_request req = makeReq(intent);
        sony2fuji_buffer out{};
        const sony2fuji_status st = sony2fuji_process(session, &req, &out);
        assert(st == SONY2FUJI_STATUS_OK);
        const auto* ptr = static_cast<const uint8_t*>(out.data);
        std::vector<uint8_t> bytes(ptr, ptr + out.size_bytes);
        sony2fuji_release_buffer(&out);
        return bytes;
    };

    const auto baselineCpu = runWithGpuMode(SONY2FUJI_GPU_OFF, SONY2FUJI_INTENT_FINAL);
    const char* activeJson = R"json({
        "schema_version": 5,
        "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
        "input": {"path": "memory.png", "type": "raster"},
        "edits": {
            "exposure": {"mode": "sensor", "ev": 0.0, "brightness": 1.0},
            "white_balance": {"mode": "none"},
            "look": {"path": null, "strength": 1.0},
            "effects": {
                "grain_amount": 35.0,
                "grain_size": 25.0,
                "grain_roughness": 50.0,
                "grain_tone_curve": "negative_asymmetric",
                "grain_format_preset": "135",
                "halation": {"amount": 65.0, "threshold": 70.0, "radius": 35.0, "hue": -20.0},
                "bloom": {"amount": 40.0, "threshold": 70.0, "radius": 40.0}
            }
        },
        "output": {"path": "out.png", "format": "png", "size": {"mode": "native"}}
    })json";
    assert(sony2fuji_apply_params(session, activeJson) == SONY2FUJI_STATUS_OK);
    const auto cpuFinal = runWithGpuMode(SONY2FUJI_GPU_OFF, SONY2FUJI_INTENT_FINAL);
    const auto cpuPreview = runWithGpuMode(SONY2FUJI_GPU_OFF, SONY2FUJI_INTENT_PREVIEW);
    assert(cpuFinal != baselineCpu);

    // Reset back to defaults -> exact 0 difference vs baseline.
    assert(sony2fuji_apply_params(session, defaultJson) == SONY2FUJI_STATUS_OK);
    const auto resetCpu = runWithGpuMode(SONY2FUJI_GPU_OFF, SONY2FUJI_INTENT_FINAL);
    assert(resetCpu == baselineCpu);

    // Active Force GPU parity test if a native GPU backend is available.
    if (rawlabtest::nativeGpuAvailable()) {
        assert(sony2fuji_apply_params(session, activeJson) == SONY2FUJI_STATUS_OK);
        const auto gpuFinal = runWithGpuMode(SONY2FUJI_GPU_FORCE, SONY2FUJI_INTENT_FINAL);
        assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
        assert(gpuFinal.size() == cpuFinal.size());
        int maxDiff = 0;
        for (size_t i = 0; i < cpuFinal.size(); ++i) {
            maxDiff = std::max(maxDiff, std::abs(int(cpuFinal[i]) - int(gpuFinal[i])));
        }
        assert(maxDiff <= 2);

        // Preview intent Force GPU check too
        const auto gpuPreview = runWithGpuMode(SONY2FUJI_GPU_FORCE, SONY2FUJI_INTENT_PREVIEW);
        assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
        int maxPrevDiff = 0;
        for (size_t i = 0; i < cpuPreview.size(); ++i) {
            maxPrevDiff = std::max(maxPrevDiff, std::abs(int(cpuPreview[i]) - int(gpuPreview[i])));
        }
        assert(maxPrevDiff <= 2);
        std::cout << "PASS: Force GPU parity (final maxDiff=" << maxDiff << " RGB8, preview maxDiff=" << maxPrevDiff << " RGB8)\n";
    } else {
        std::cout << "PASS: CPU canonical API round-trip & zero-reset parity (native GPU not present)\n";
    }
    sony2fuji_session_destroy(session);
}

void testCombinedV014AllFeaturesParity() {
    const int W = 160, H = 120;
    std::vector<uint8_t> rgbInput(static_cast<size_t>(W) * H * 3u, 0);
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            const float fx = float(x) / float(W - 1);
            const float fy = float(y) / float(H - 1);
            const float fineTex = 0.05f * std::sin(x * 1.1f) * std::cos(y * 1.1f);
            float r = std::clamp(0.12f + 0.42f * fx + 0.08f * std::sin(fx * 12.0f) + fineTex, 0.02f, 0.90f);
            float g = std::clamp(0.10f + 0.34f * fy + 0.06f * std::cos(fy * 10.0f) - 0.5f * fineTex, 0.02f, 0.90f);
            float b = std::clamp(0.14f + 0.38f * (1.0f - fx), 0.02f, 0.90f);
            if (x >= 68 && x < 92 && y >= 48 && y < 72) {
                r = 0.96f; g = 0.94f; b = 0.92f;
            } else if (x == 67 && y >= 48 && y < 72) {
                r = 0.85f; g = 0.14f; b = 0.88f;
            } else if (x == 92 && y >= 48 && y < 72) {
                r = 0.14f; g = 0.84f; b = 0.16f;
            }
            const size_t idx = (static_cast<size_t>(y) * W + x) * 3u;
            rgbInput[idx + 0] = static_cast<uint8_t>(std::lround(r * 255.0f));
            rgbInput[idx + 1] = static_cast<uint8_t>(std::lround(g * 255.0f));
            rgbInput[idx + 2] = static_cast<uint8_t>(std::lround(b * 255.0f));
        }
    }

    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);

    auto runCase = [&](const char* label, const char* jsonText) {
        assert(sony2fuji_apply_params(session, jsonText) == SONY2FUJI_STATUS_OK);
        auto runMode = [&](sony2fuji_gpu_mode mode, sony2fuji_intent intent) {
            sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), mode};
            assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
            sony2fuji_request req{};
            req.version = SONY2FUJI_REQUEST_VERSION;
            req.struct_size = sizeof(req);
            req.input_type = SONY2FUJI_INPUT_BUFFER;
            req.input_pixels = rgbInput.data();
            req.input_width = static_cast<uint32_t>(W);
            req.input_height = static_cast<uint32_t>(H);
            req.input_is_linear = 0;
            req.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
            req.input_color_space = SONY2FUJI_COLOR_SRGB;
            req.brightness = 1.0f;
            req.contrast = 1.0f;
            req.saturation = 1.0f;
            req.temperature = 6500.0f;
            req.sharpening = 0.60f;
            req.size_mode = SONY2FUJI_SIZE_NATIVE;
            req.intent = intent;
            req.output_target = SONY2FUJI_TARGET_BUFFER;
            req.output_format = SONY2FUJI_OUTPUT_RGB8;
            sony2fuji_buffer out{};
            assert(sony2fuji_process(session, &req, &out) == SONY2FUJI_STATUS_OK);
            const auto* ptr = static_cast<const uint8_t*>(out.data);
            std::vector<uint8_t> bytes(ptr, ptr + out.size_bytes);
            sony2fuji_release_buffer(&out);
            return bytes;
        };

        const auto cpuFinal = runMode(SONY2FUJI_GPU_OFF, SONY2FUJI_INTENT_FINAL);
        const auto cpuPreview = runMode(SONY2FUJI_GPU_OFF, SONY2FUJI_INTENT_PREVIEW);
        if (rawlabtest::nativeGpuAvailable()) {
            const auto gpuFinal = runMode(SONY2FUJI_GPU_FORCE, SONY2FUJI_INTENT_FINAL);
            assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
            int maxDiffFinal = 0;
            for (size_t i = 0; i < cpuFinal.size(); ++i) {
                maxDiffFinal = std::max(maxDiffFinal, std::abs(int(cpuFinal[i]) - int(gpuFinal[i])));
            }
            assert(maxDiffFinal <= 2);

            const auto gpuPreview = runMode(SONY2FUJI_GPU_FORCE, SONY2FUJI_INTENT_PREVIEW);
            assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
            int maxDiffPreview = 0;
            for (size_t i = 0; i < cpuPreview.size(); ++i) {
                maxDiffPreview = std::max(maxDiffPreview, std::abs(int(cpuPreview[i]) - int(gpuPreview[i])));
            }
            assert(maxDiffPreview <= 2);
            std::cout << "PASS: Combined v0.14.0 [" << label << "] Force GPU parity (final maxDiff="
                      << maxDiffFinal << ", preview maxDiff=" << maxDiffPreview << ")\n";
        } else {
            assert(!cpuFinal.empty() && cpuFinal.size() == cpuPreview.size());
            std::cout << "PASS: Combined v0.14.0 [" << label << "] CPU render (native GPU not present)\n";
        }
    };

    const char* allColorJson = R"json({
        "schema_version": 20,
        "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
        "input": {"path": "memory.png", "type": "raster"},
        "edits": {
            "exposure": {"mode": "sensor", "ev": 0.0, "brightness": 1.0},
            "white_balance": {"mode": "none"},
            "look": {"path": null, "strength": 1.0},
            "tone": {"contrast": 1.0, "saturation": 1.0, "highlights": 0.0, "shadows": 0.0},
            "color": {
                "calibration": {
                    "shadow_tint": -20.0,
                    "red_hue": 25.0, "red_saturation": 18.0,
                    "green_hue": -15.0, "green_saturation": 12.0,
                    "blue_hue": 30.0, "blue_saturation": -10.0
                },
                "point_color": {
                    "swatches": [{
                        "src_hue": 22.0, "src_saturation": 0.55, "src_luminance": 0.55,
                        "hue_shift": 18.0, "saturation_shift": -22.0, "luminance_shift": 10.0,
                        "variance": -45.0, "range": 65.0, "hue_range": 55.0, "sat_range": 50.0, "lum_range": 50.0,
                        "enabled": true
                    }]
                },
                "selective_color": {
                    "method": "relative",
                    "bands": {
                        "reds": {"cyan": -20.0, "magenta": 15.0, "yellow": 10.0, "black": -10.0},
                        "blues": {"cyan": 25.0, "magenta": -15.0, "yellow": -10.0, "black": 15.0}
                    }
                }
            },
            "color_grading": {
                "shadows": {"hue": 215.0, "saturation": 25.0, "luminance": -8.0},
                "highlights": {"hue": 42.0, "saturation": 20.0, "luminance": 8.0},
                "blending": 60.0,
                "balance": 10.0
            },
            "detail": {
                "sharpening": 0.60,
                "luminance_v2": true,
                "sharpening_radius": 1.2,
                "sharpening_detail": 25.0,
                "sharpening_masking": 50.0
            },
            "lens_correction": {
                "defringe_purple_amount": 8.0,
                "defringe_purple_hue": 50.0,
                "defringe_green_amount": 6.0,
                "defringe_green_hue": 50.0
            },
            "effects": {
                "clarity": 0.40,
                "dehaze": 0.25,
                "texture": 0.45,
                "grain_amount": 35.0,
                "grain_size": 25.0,
                "grain_roughness": 50.0,
                "grain_tone_curve": "negative_asymmetric",
                "grain_format_preset": "135",
                "halation": {"amount": 60.0, "threshold": 65.0, "radius": 35.0, "hue": -25.0},
                "bloom": {"amount": 40.0, "threshold": 65.0, "radius": 40.0}
            }
        },
        "output": {"path": "out.png", "format": "png", "size": {"mode": "native"}}
    })json";

    const char* bwFilmJson = R"json({
        "schema_version": 20,
        "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
        "input": {"path": "memory.png", "type": "raster"},
        "edits": {
            "exposure": {"mode": "sensor", "ev": 0.0, "brightness": 1.0},
            "white_balance": {"mode": "none"},
            "look": {"path": null, "strength": 1.0},
            "tone": {"contrast": 1.0, "saturation": 1.0, "highlights": 0.0, "shadows": 0.0},
            "color": {
                "calibration": {"shadow_tint": 15.0, "red_hue": -25.0, "blue_saturation": 35.0},
                "bw": {"enabled": true, "mixer": {"red": 45.0, "yellow": 20.0, "blue": -50.0}},
                "selective_color": {"method": "absolute", "bands": {"neutrals": {"cyan": 8.0, "black": 10.0}}}
            },
            "detail": {
                "sharpening": 0.50,
                "luminance_v2": true,
                "sharpening_radius": 1.1,
                "sharpening_detail": 20.0,
                "sharpening_masking": 40.0
            },
            "effects": {
                "clarity": 0.30,
                "texture": 0.35,
                "grain_amount": 40.0,
                "grain_tone_curve": "negative_asymmetric",
                "grain_format_preset": "120",
                "halation": {"amount": 50.0, "threshold": 65.0, "radius": 30.0, "hue": 20.0},
                "bloom": {"amount": 30.0, "threshold": 70.0, "radius": 35.0}
            }
        },
        "output": {"path": "out.png", "format": "png", "size": {"mode": "native"}}
    })json";

    runCase("Calibration+PointColor+Selective+Grading+Defringe+Dehaze+Clarity+Texture+Halation+Bloom+SharpenV2+AsymGrain", allColorJson);
    runCase("BwMixer+Clarity+Texture+Halation+Bloom+SharpenV2+120Grain", bwFilmJson);
    sony2fuji_session_destroy(session);
}

} // namespace

int main() {
    testHalationEdgeAndNeutralInterior();
    testBloomAndScaleInvariance();
    testZeroBypassAndFieldRoi();
    testNegativeAsymmetricGrainAndPresets();
    testApiParityAndForceGpu();
    testCombinedV014AllFeaturesParity();
    return 0;
}
