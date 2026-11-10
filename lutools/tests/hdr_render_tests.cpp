#include "core/hdr_rendering.h"
#include "core/hdr_look.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include <opencv2/core.hpp>
#endif

using namespace sony2fuji;

namespace {

void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

void near(float value, float reference, const char* message) {
    check(std::abs(value - reference) <= 1e-6f * std::max(1.0f, std::abs(reference)), message);
}

float luminance(const RGB& p) { return .2126f * p.r + .7152f * p.g + .0722f * p.b; }

HDRImagePair fixture() {
    HDRImagePair result;
    result.hdr = ImageData(8, 2);
    result.sdr = ImageData(8, 2);
    const float levels[] = {0, .18f, 1, 2, 4, 8, 16, -.1f};
    for (size_t i = 0; i < result.hdr.pixels.size(); ++i) {
        const float value = levels[i % 8];
        result.hdr.pixels[i] = {value, value, value};
        result.sdr.pixels[i] = {std::min(value, 1.0f), std::min(value, 1.0f), std::min(value, 1.0f)};
    }
    result.nativeWidth = 8; result.nativeHeight = 2;
    result.sourceHeadroom = 16;
    result.decodeRevision = 42;
    return result;
}

template<class Function> void rejects(Function function, const char* message) {
    bool rejected = false;
    try { function(); } catch (const std::invalid_argument&) { rejected = true; }
    check(rejected, message);
}

void identity() {
    auto source = fixture();
    const auto result = renderHDRPair(source, {});
    check(std::memcmp(source.hdr.pixels.data(), result.hdr.pixels.data(), source.hdr.pixels.size() * sizeof(RGB)) == 0,
        "HDR identity changed float bits or clipped super-whites");
    check(std::memcmp(source.sdr.pixels.data(), result.sdr.pixels.data(), source.sdr.pixels.size() * sizeof(RGB)) == 0,
        "SDR identity changed float bits");
    check(result.decodeRevision == 42 && result.sourceHeadroom == 16 && result.editedHeadroom >= 16,
        "content metadata was lost");
    HDRRenderOptions options;
    options.exposureEV = 1;
    const auto brighter = renderHDRPair(source, options);
    for (size_t i = 0; i < source.hdr.pixels.size(); ++i) {
        near(brighter.hdr.pixels[i].r, source.hdr.pixels[i].r * 2, "exposure did not double HDR");
        near(brighter.sdr.pixels[i].r, source.sdr.pixels[i].r * 2, "exposure did not double linear SDR");
    }
    near(source.hdr.pixels[6].r, 16, "source mutated");
    check(brighter.editedHeadroom >= 32, "edited headroom was capped to source capacity");
}

void tone() {
    auto source = fixture();
    HDRRenderOptions options;
    options.highlights = 100;
    auto brighter = renderHDRPair(source, options);
    options.highlights = -100;
    auto darker = renderHDRPair(source, options);
    check(brighter.hdr.pixels[4].r > 4 && darker.hdr.pixels[4].r < 4, "HDR highlights have wrong direction");
    near(brighter.hdr.pixels[4].r, 16, "positive highlight reference vector differs");
    near(darker.hdr.pixels[4].r, 1, "negative highlight reference vector differs");
    options = {}; options.shadows = 100;
    brighter = renderHDRPair(source, options);
    check(brighter.hdr.pixels[1].r > .18f, "HDR shadows did not brighten");
    options = {}; options.contrast = 100;
    brighter = renderHDRPair(source, options);
    near(brighter.hdr.pixels[1].r, .18f, "contrast moved its gray anchor");
    check(brighter.hdr.pixels[6].r > 16, "HDR contrast clipped highlights");
    near(brighter.hdr.pixels[4].r, 88.8888889f, "contrast reference vector differs");
    source.hdr.pixels[0] = {.2f, .5f, .8f};
    options = {}; options.saturation = -100;
    const auto gray = renderHDRPair(source, options).hdr.pixels[0];
    near(gray.r, luminance(source.hdr.pixels[0]), "desaturation does not preserve luminance");
    near(gray.r, .45788f, "desaturation reference vector differs");
    near(gray.r, gray.g, "desaturation is not gray"); near(gray.r, gray.b, "desaturation is not gray");
    source.hdr.pixels[0] = {.99999f, .99999f, .99999f};
    source.hdr.pixels[1] = {1.00001f, 1.00001f, 1.00001f};
    options = {}; options.highlights = 100;
    const auto edge = renderHDRPair(source, options);
    check(edge.hdr.pixels[1].r > edge.hdr.pixels[0].r && edge.hdr.pixels[1].r - edge.hdr.pixels[0].r < .001f,
        "HDR reference-white boundary has a plateau or jump");
    options = {}; options.processingVersion = SONY2FUJI_HDR_PROCESSING_CHANNEL_CURVES_VERSION;
    source = fixture();
    const auto original = renderHDRPair(source, options);
    options.tone.channels[0] = {SONY2FUJI_TONE_CURVE_CONFIG_VERSION, sizeof(sony2fuji_tone_curve_config),
        SONY2FUJI_CURVE_CUSTOM, 3, {{0,0},{.5,.6},{1,1}}};
    const auto red = renderHDRPair(source, options);
    check(red.hdr.pixels[2].r > original.hdr.pixels[2].r, "HDR red curve must affect red");
    for (size_t i = 0; i < source.hdr.pixels.size(); ++i) {
        near(red.hdr.pixels[i].g, original.hdr.pixels[i].g, "HDR red curve preserves green");
        near(red.hdr.pixels[i].b, original.hdr.pixels[i].b, "HDR red curve preserves blue");
        near(red.sdr.pixels[i].g, original.sdr.pixels[i].g, "SDR rendition preserves green");
    }
    options.tone.channels[0].points[1].y = .5;
    const auto identity = renderHDRPair(source, options);
    check(std::memcmp(identity.hdr.pixels.data(), original.hdr.pixels.data(), original.hdr.pixels.size() * sizeof(RGB)) == 0 &&
        std::memcmp(identity.sdr.pixels.data(), original.sdr.pixels.data(), original.sdr.pixels.size() * sizeof(RGB)) == 0,
        "HDR channel identity is exact");

}

void color() {
    auto source = fixture();
    source.hdr.pixels[0] = {4, 1.5f, -.2f};
    source.sdr.pixels[0] = {.8f, .3f, -.04f};
    source.hdr.pixels[2] = {.99999f, .99999f, .99999f};
    source.hdr.pixels[3] = {1.00001f, 1.00001f, 1.00001f};
    const auto atWhite = [](RGB p) {
        const float offset = 1 - luminance(p);
        return RGB(p.r + offset, p.g + offset, p.b + offset);
    };
    source.hdr.pixels[5] = atWhite({1, .8f, .6f});
    source.hdr.pixels[6] = atWhite({.6f, .8f, 1});
    HDRRenderOptions v2;
    v2.processingVersion = 2; v2.tone.whitePoint = 20;
    auto v3 = v2; v3.processingVersion = 3;
    auto previous = renderHDRPair(source, v2), next = renderHDRPair(source, v3);
    check(std::memcmp(previous.hdr.pixels.data(), next.hdr.pixels.data(), previous.hdr.pixels.size() * sizeof(RGB)) == 0 &&
        std::memcmp(previous.sdr.pixels.data(), next.sdr.pixels.data(), previous.sdr.pixels.size() * sizeof(RGB)) == 0,
        "neutral HDR v3 changed v2 pixels");

    v3.tone.whitePoint = 0;
    v3.color.vibrance = 100;
    next = renderHDRPair(source, v3);
    const auto bright = next.hdr.pixels[0], base = next.sdr.pixels[0];
    check(bright.r > 4 && bright.b < -.2f && base.r > .8f, "vibrance did not preserve the extended range in both renditions");
    near(luminance(bright), luminance(source.hdr.pixels[0]), "vibrance changed HDR luminance");
    near(next.hdr.pixels[1].r, .18f, "vibrance tinted neutral gray");
    const auto skin = next.hdr.pixels[5], cool = next.hdr.pixels[6];
    check(skin.r - skin.b < cool.b - cool.r, "vibrance did not protect the skin-tone range");

    v3.color = {};
    v3.color.hsl.hue.fill(100);
    next = renderHDRPair(source, v3);
    check(next.hdr.pixels[0].g > source.hdr.pixels[0].g, "HDR hue adjustment did not rotate its color direction");
    near(luminance(next.hdr.pixels[0]), luminance(source.hdr.pixels[0]), "HDR hue adjustment changed luminance");
    v3.color.hsl.hue.fill(0); v3.color.hsl.lightness.fill(100);
    next = renderHDRPair(source, v3);
    near(next.hdr.pixels[0].r, 8, "HDR HSL lightness did not brighten above reference white");
    near(next.hdr.pixels[1].r, .18f, "HDR HSL lightness changed neutral gray");

    v3.color = {};
    v3.color.grading.wheels[2] = {210, 65};
    next = renderHDRPair(source, v3);
    check(next.hdr.pixels[4].b > 4 && next.hdr.pixels[4].r < 4, "HDR grading bypassed highlights");
    near(luminance(next.hdr.pixels[4]), 4, "HDR grading changed luminance");
    check(next.hdr.pixels[3].b > next.hdr.pixels[2].b &&
        next.hdr.pixels[3].b - next.hdr.pixels[2].b < .001f, "HDR grading jumped at reference white");
    v3.color.vibrance = std::numeric_limits<float>::quiet_NaN();
    rejects([&] { renderHDRPair(source, v3); }, "invalid v3 color options were accepted");
}

void rendition() {
    auto source = fixture();
    source.hdr.pixels[4] = {6, 4, 2};
    source.sdr.pixels[1] = {.28f, .18f, .05f};
    HDRRenderOptions options;
    options.processingVersion = SONY2FUJI_HDR_PROCESSING_COLOR_VERSION;
    const auto reference = renderHDRPair(source, options);
    options.processingVersion = SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION;
    auto samePixels = [](const ImageData& a, const ImageData& b) {
        return std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(RGB)) == 0;
    };
    const auto neutral = renderHDRPair(source, options);
    check(samePixels(neutral.hdr, reference.hdr) && samePixels(neutral.sdr, reference.sdr), "neutral v4 changed v3 pixels");
    options.rendition.peakLimitEV = 2;
    const auto limited = renderHDRPair(source, options);
    check(samePixels(limited.sdr, reference.sdr), "HDR limit changed the SDR base");
    near(limited.hdr.pixels[2].r, 1, "HDR limit moved reference white");
    near(limited.hdr.pixels[3].r, 2, "HDR limit moved the knee");
    near(limited.hdr.pixels[4].r / limited.hdr.pixels[4].g, 1.5f, "HDR limit changed channel proportions");
    check(limited.hdr.pixels[5].r < 4 && limited.hdr.pixels[6].r > limited.hdr.pixels[5].r &&
        limited.editedHeadroom <= 4 && limited.sourceHeadroom == reference.sourceHeadroom, "HDR limit did not preserve peak detail");
    options.rendition.peakLimitEV = 0;
    options.rendition.sdrExposureEV = 1;
    const auto baseExposure = renderHDRPair(source, options);
    check(samePixels(baseExposure.hdr, reference.hdr), "SDR base exposure changed the HDR primary");
    near(baseExposure.sdr.pixels[1].r, .56f, "SDR base exposure scale differs");
    options.rendition.sdrContrast = -25;
    options.rendition.sdrSaturation = -100;
    const auto baseColor = renderHDRPair(source, options);
    check(samePixels(baseColor.hdr, reference.hdr), "SDR base contrast or saturation changed the HDR primary");
    near(baseColor.sdr.pixels[1].r, baseColor.sdr.pixels[1].b, "SDR base desaturation did not reach gray");
    check(baseColor.sdr.pixels[1].r != baseExposure.sdr.pixels[1].r, "SDR base trim had no effect");
    options.rendition.peakLimitEV = 7;
    rejects([&] { renderHDRPair(source, options); }, "invalid HDR output limit accepted");
}

void effects() {
    auto source = fixture();
    HDRRenderOptions options;
    options.processingVersion = SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION;
    options.rendition = {2, -.5f, 25, -15};
    const auto reference = renderHDRPair(source, options);
    options.processingVersion = SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION;
    const auto neutral = renderHDRPair(source, options);
    for (bool hdr : {true, false}) {
        const auto& a = hdr ? reference.hdr : reference.sdr;
        const auto& b = hdr ? neutral.hdr : neutral.sdr;
        check(std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(RGB)) == 0,
            "neutral v5 changed v4 pixels");
    }
    source.hdr = ImageData(65, 49);
    source.sdr = ImageData(65, 49);
    source.nativeWidth = 65; source.nativeHeight = 49;
    std::fill(source.hdr.pixels.begin(), source.hdr.pixels.end(), RGB(4, 3, -.3f));
    std::fill(source.sdr.pixels.begin(), source.sdr.pixels.end(), RGB(.45f, .3f, .15f));
    options.rendition = {};
    options.effects.vignetteAmount = -80;
    const auto dark = renderHDRPair(source, options);
    check(dark.hdr.at(0, 0).r < 4 && dark.hdr.at(0, 0).b < 0 &&
        dark.hdr.at(32, 24).r == 4 && dark.sdr.at(0, 0).r < .45f, "HDR dark vignette changed the center or clipped a channel");
    options.effects.vignetteHighlights = 100;
    const auto protectedHDR = renderHDRPair(source, options);
    check(protectedHDR.hdr.at(0, 0).r == 4 && protectedHDR.sdr.at(0, 0).r < .45f,
        "Vignette highlight protection did not use each rendition's luminance");
    options.effects.vignetteAmount = 60;
    const auto light = renderHDRPair(source, options);
    check(light.hdr.at(0, 0).r == 4 && light.sdr.at(0, 0).r > .45f,
        "Bright vignette pulled super-white HDR pixels toward white");
    options.effects.vignetteAmount = 0;
    options.effects.grainAmount = 100;
    const auto grained = renderHDRPair(source, options);
    const auto again = renderHDRPair(source, options);
    check(std::memcmp(grained.hdr.pixels.data(), again.hdr.pixels.data(), again.hdr.pixels.size() * sizeof(RGB)) == 0 &&
        std::memcmp(grained.sdr.pixels.data(), again.sdr.pixels.data(), again.sdr.pixels.size() * sizeof(RGB)) == 0,
        "HDR grain changed with rendering order");
    check(grained.hdr.at(0, 0).r > 1 && grained.hdr.at(0, 0).b < 0 &&
        grained.hdr.at(0, 0).r != grained.hdr.at(1, 0).r &&
        grained.sdr.at(0, 0).r != grained.sdr.at(1, 0).r, "HDR grain clipped or did not add texture");
    options.rendition.peakLimitEV = .3f;
    const auto capped = renderHDRPair(source, options);
    check(capped.editedHeadroom <= std::exp2(.3f) + 1e-6f, "HDR grain exceeded the final luminance ceiling");
    options.effects.grainRoughness = 101;
    rejects([&] { renderHDRPair(source, options); }, "invalid HDR effects accepted");
}

void detail() {
    auto source = fixture();
    HDRRenderOptions options;
    options.processingVersion = SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION;
    options.effects.grainAmount = 35;
    options.rendition.peakLimitEV = 1.25;
    const auto reference = renderHDRPair(source, options);
    options.processingVersion = SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION;
    const auto neutral = renderHDRPair(source, options);
    for (bool hdr : {true, false}) {
        const auto& a = hdr ? reference.hdr : reference.sdr;
        const auto& b = hdr ? neutral.hdr : neutral.sdr;
        check(std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(RGB)) == 0,
            "neutral v6 changed v5 pixels");
    }

    source.hdr = ImageData(9, 9);
    source.sdr = ImageData(9, 9);
    source.nativeWidth = source.nativeHeight = 9;
    std::fill(source.hdr.pixels.begin(), source.hdr.pixels.end(), RGB(4, 3, -.3f));
    std::fill(source.sdr.pixels.begin(), source.sdr.pixels.end(), RGB(.2f, .2f, .2f));
    source.hdr.at(4, 4) = {5, 3.75f, -.375f};
    source.sdr.at(4, 4).r = .25f;
    options.effects = {};
    options.rendition = {};
    options.detail.sharpening = 2;
    const auto sharpened = renderHDRPair(source, options);
    check(sharpened.hdr.at(4, 4).r > 5 && sharpened.hdr.at(4, 4).r < 5 * std::exp2(.45f) &&
        sharpened.hdr.at(4, 4).b < -.375f && sharpened.hdr.at(0, 0).r == 4,
        "Sharpening did not retain signed highlights or bounded local gain");
    options.detail = {0, 1, 0, 0};
    const auto clear = renderHDRPair(source, options);
    check(clear.hdr.at(4, 4).r > 5 && clear.hdr.at(2, 4).r < 4 && clear.hdr.at(3, 4).r == 4,
        "Clarity did not use the wider neighborhood");
    options.detail.clarity = -1;
    check(renderHDRPair(source, options).hdr.at(4, 4).r < 5, "Negative clarity did not soften the bump");
    HDRDetailOptions clarity{0, 1, 0, 0};
    for (const auto size : {2000, 4000, 8000, 16000})
        check(clarity.halo(size, 1) == size / 200 && clarity.halo(1, size) == size / 200,
            "HDR clarity radius lost its relative canvas scale above 4.7k");
    check(clarity.halo(65535, 1) == 328, "HDR clarity exceeded the supported canvas halo bound");
    check(clarity.halo(100000, 1) == 500, "HDR buffer clarity lost its relative radius beyond JPEG dimensions");
    ImageData tall(3, 65535);
    for (int y = 0; y < tall.height; ++y) for (int x = 0; x < tall.width; ++x) {
        const float value = .2f * std::exp2(.2f * std::sin(y * .03f));
        tall.at(x, y) = {value, value * 2, -value};
    }
    const auto plan = planHDRDetail(tall.width, tall.height, clarity, 0, [&](int x, int y) { return tall.at(x, y); });
    ImageData full(tall.width, tall.height), bands(tall.width, tall.height);
    renderHDRDetailBand(plan, tall.pixels.data(), 0, tall.height, full.pixels.data(), 0, tall.height);
    for (int first = 0; first < tall.height; first += hdrDetailBandHeight) {
        const int end = std::min(first + hdrDetailBandHeight, tall.height);
        const int top = std::max(0, first - plan.halo), bottom = std::min(tall.height, end + plan.halo);
        renderHDRDetailBand(plan, tall.pixels.data() + top * tall.width, top, bottom - top,
            bands.pixels.data() + first * tall.width, first, end - first);
    }
    check(std::memcmp(full.pixels.data(), bands.pixels.data(), full.pixels.size() * sizeof(RGB)) == 0,
        "Large-canvas HDR clarity changed at band boundaries");
    options.detail = {0, 0, 0, 1};
    const auto clean = renderHDRPair(source, options);
    check(clean.sdr.at(4, 4).r < .25f && clean.sdr.at(4, 4).r > .2f &&
        clean.sdr.at(4, 4).g == .2f && clean.hdr.at(4, 4).b < 0,
        "Rendered RGB denoise did not suppress a color fluctuation or clipped a signed channel");
    for (int x = 0; x < 3; ++x) for (int y = 0; y < 9; ++y) source.hdr.at(x, y) = {.2f, .2f, .2f};
    options.detail = {0, 0, 1, 0};
    const auto dehazed = renderHDRPair(source, options);
    check(dehazed.hdr.at(0, 0).r < .15f && dehazed.hdr.at(8, 8).r > 3.9f &&
        dehazed.hdr.at(8, 8).b < 0 && dehazed.sdr.at(0, 0).r < .15f,
        "Dehaze did not prioritize the shadows in each rendition");
    options.detail.dehaze = -1;
    check(renderHDRPair(source, options).hdr.at(0, 0).r > .25f, "Negative dehaze did not add veil");
    options.detail = {2, 1, -1, 1};
    options.rendition.peakLimitEV = .3f;
    check(renderHDRPair(source, options).editedHeadroom <= std::exp2(.3f) + 1e-6f,
        "HDR detail exceeded the final luminance ceiling");
    options.detail.denoise = std::numeric_limits<float>::quiet_NaN();
    rejects([&] { renderHDRPair(source, options); }, "non-finite HDR detail accepted");
}

void look(const char* path) {
    auto source = fixture();
    HDRRenderOptions options;
    options.processingVersion = SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION;
    options.detail = {1.2f, .5f, -.4f, .6f};
    const auto before = renderHDRPair(source, options);
    options.processingVersion = SONY2FUJI_HDR_PROCESSING_LOOK_VERSION;
    const auto after = renderHDRPair(source, options);
    for (bool hdr : {true, false}) {
        const auto& a = hdr ? before.hdr : before.sdr;
        const auto& b = hdr ? after.hdr : after.sdr;
        check(std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(RGB)) == 0,
            "Neutral HDR look changed v6 pixels");
    }
    const auto table = HDRLook::load(path);
    check(table->gridSize() == 2 && table->domainMax().r == 4 && table->fingerprint().size() == 64,
        "Declared HDR look lost its domain or resource identity");
    rejects([&] { HDRLook::load(path, std::string(64, '0')); }, "Incorrect HDR look identity accepted");
    auto plain = LUTParser::loadLUT(path);
    check(plain && plain->hasHDRLookContract() && !plain->isPhotoLUT(), "HDR table entered the SDR evaluator");
    const std::string oldCube = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
    check(plain->loadFromData(oldCube) == ErrorCode::Success && !plain->hasHDRLookContract(), "SDR CUBE gained an HDR contract");
    check(plain->loadFromData("# RawLabHDRLook: display-linear-srgb-v1\n" + oldCube) == ErrorCode::InvalidFormat,
        "HDR declaration accepted an SDR-only domain");
    options = {};
    options.processingVersion = SONY2FUJI_HDR_PROCESSING_LOOK_VERSION;
    options.look = table;
    source.hdr.pixels[1] = {8, 2, -.25f}; source.sdr.pixels[1] = {.5f, .25f, .125f};
    const auto zero = renderHDRPair(source, options);
    check(std::memcmp(zero.hdr.pixels.data(), source.hdr.pixels.data(), source.hdr.pixels.size() * sizeof(RGB)) == 0,
        "Zero look strength did not bypass HDR pixels");
    options.lookStrength = 1;
    const auto transformed = renderHDRPair(source, options);
    near(transformed.hdr.pixels[1].r, 7.125f, "HDR table discarded the residual above its domain");
    near(transformed.hdr.pixels[1].g, 1.5f, "HDR table did not map the channel within its domain");
    near(transformed.hdr.pixels[1].b, -.25f, "HDR table clipped the negative residual");
    near(transformed.sdr.pixels[1].r, .5f, "HDR table did not evaluate the independent SDR base");
    near(transformed.sdr.pixels[1].g, .1875f, "HDR table skipped the SDR base");
    near(transformed.hdr.pixels[2].r, .875f, "Reference-white CUBE anchor changed");
    check(transformed.editedHeadroom > 1, "HDR look lost HDR headroom");
    options.rendition.peakLimitEV = .5f;
    check(renderHDRPair(source, options).editedHeadroom <= std::exp2(.5f) + 1e-6f, "Look bypassed the HDR limit");
}

void silver(const char* path) {
    const auto table = HDRLook::load(path);
    for (const float grey : {-4.f, 0.f, .015625f, .1845f, 1.f, 2.f, 4.f, 16.f, 64.f, 80.f}) {
        const auto output = table->apply({grey, grey, grey}, 1);
        near(output.r, grey, "HDR Silver changed neutral luminance");
        near(output.g, output.r, "HDR Silver tinted the neutral axis");
        near(output.b, output.r, "HDR Silver tinted the neutral axis");
    }
    for (const RGB pixel : {RGB{2.f, .18f, -.125f}, RGB{-.3f, 3.f, 7.f}, RGB{20.f, 14.f, 6.f}}) {
        const auto output = table->apply(pixel, 1);
        const auto expected = (5 * pixel.r + 10 * pixel.g + pixel.b) / 16;
        near(output.r, expected, "HDR Silver changed its red, green or blue weighting");
        near(output.g, expected, "HDR Silver left residual color within its domain");
        near(output.b, expected, "HDR Silver left residual color within its domain");
    }
}

void whiteBalance() {
    auto source = fixture();
    HDRRenderOptions options; options.temperature = 10000;
    auto warm = renderHDRPair(source, options).hdr.pixels[1];
    check(warm.r > warm.b, "positive relative temperature is not warmer");
    near(luminance(warm), .18f, "relative WB changed neutral luminance");
    options = {}; options.temperature = 3000;
    auto cool = renderHDRPair(source, options).hdr.pixels[1];
    check(cool.b > cool.r, "negative relative temperature is not cooler");
    options = {}; options.tint = 100;
    auto tint = renderHDRPair(source, options).hdr.pixels[1];
    check(tint.g < tint.r && tint.g < tint.b, "positive tint is not magenta");
}

void geometry() {
    auto source = fixture();
    HDRRenderOptions options; options.geometry.quarter_turns = 1;
    auto rotated = renderHDRPair(source, options);
    check(rotated.hdr.width == 2 && rotated.hdr.height == 8 && rotated.sdr.width == 2, "geometry canvases diverge");
    near(rotated.hdr.at(1, 6).r, source.hdr.at(6, 0).r, "clockwise HDR rotation differs");
    near(rotated.sdr.at(1, 6).r, source.sdr.at(6, 0).r, "SDR rotation differs");
    options.longEdge = 4;
    auto smaller = renderHDRPair(source, options);
    check(smaller.hdr.width == 1 && smaller.hdr.height == 4 && smaller.sdr.height == 4, "final resize differs");
    options.longEdge = 100;
    check(renderHDRPair(source, options).hdr.height == 8, "long-edge limit upscaled the source");
    source.sourceQuality = HDRQuality::Preview; source.isProxy = true;
    rejects([&] { renderHDRPair(source, options); }, "proxy was promoted into FINAL");
    options.intent = HDRQuality::Preview;
    check(renderHDRPair(source, options).isProxy, "preview provenance was erased");
}

void validation() {
    auto source = fixture();
    HDRRenderOptions options; options.processingVersion = SONY2FUJI_HDR_PROCESSING_CHANNEL_CURVES_VERSION + 1;
    rejects([&] { renderHDRPair(source, options); }, "unknown HDR processing version accepted");
    options = {}; options.exposureEV = 5;
    rejects([&] { renderHDRPair(source, options); }, "exposure range not enforced");
    options = {}; options.temperature = std::numeric_limits<float>::quiet_NaN();
    rejects([&] { renderHDRPair(source, options); }, "nonfinite settings accepted");
    source.sdr.width = 9;
    rejects([&] { renderHDRPair(source, {}); }, "mismatched pair accepted");
    source = fixture(); source.hdr.width = std::numeric_limits<int>::max();
    rejects([&] { renderHDRPair(source, {}); }, "oversized or malformed pixel storage accepted");
    source = fixture(); source.hdr.pixels[0].r = std::numeric_limits<float>::infinity();
    rejects([&] { renderHDRPair(source, {}); }, "nonfinite pixels accepted");
}

void moveReuse() {
    auto source = fixture();
    const auto* hdrStorage = source.hdr.pixels.data();
    const auto* sdrStorage = source.sdr.pixels.data();
    const auto result = renderHDRPair(std::move(source), {});
    check(result.hdr.pixels.data() == hdrStorage && result.sdr.pixels.data() == sdrStorage,
        "rvalue HDR render did not reuse exclusive pixel storage");
    check(result.hdr.width == 8 && result.sdr.height == 2, "rvalue HDR render lost image metadata");
}

#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
void parallel() {
    HDRImagePair source;
    source.hdr=ImageData(512,384); source.sdr=ImageData(512,384);
    source.nativeWidth=4096; source.nativeHeight=3072; source.sourceHeadroom=8;
    for (size_t i=0;i<source.hdr.pixels.size();++i) {
        const float value=-.01f+float(i%4096)/512;
        source.hdr.pixels[i]={value,value*.75f,value*.5f};
        source.sdr.pixels[i]={value/8,value*.75f/8,value*.5f/8};
    }
    const auto original=source;
    for (int mode=0;mode<3;++mode) {
        HDRRenderOptions options; options.intent=HDRQuality::Preview; options.exposureEV=.5f;
        if (mode>0) { options.temperature=7200; options.tint=8; options.contrast=20;
            options.highlights=-30; options.shadows=20; options.saturation=10; }
        if (mode==2) { options.geometry.quarter_turns=1; options.longEdge=384; }
        cv::setNumThreads(1); const auto scalar=renderHDRPair(source,options);
        cv::setNumThreads(4); const auto multi=renderHDRPair(source,options);
        check(scalar.hdr.width==multi.hdr.width && scalar.hdr.height==multi.hdr.height &&
            scalar.outputNativeWidth==multi.outputNativeWidth && scalar.outputNativeHeight==multi.outputNativeHeight &&
            scalar.editedHeadroom==multi.editedHeadroom,"parallel HDR metadata differs");
        check(std::memcmp(scalar.hdr.pixels.data(),multi.hdr.pixels.data(),scalar.hdr.pixels.size()*sizeof(RGB))==0 &&
            std::memcmp(scalar.sdr.pixels.data(),multi.sdr.pixels.data(),scalar.sdr.pixels.size()*sizeof(RGB))==0,
            "parallel HDR/SDR pixels differ from scalar processing");
    }
    check(std::memcmp(source.hdr.pixels.data(),original.hdr.pixels.data(),source.hdr.pixels.size()*sizeof(RGB))==0 &&
        std::memcmp(source.sdr.pixels.data(),original.sdr.pixels.data(),source.sdr.pixels.size()*sizeof(RGB))==0,
        "parallel processing mutated its source");
    source.hdr.pixels.back().r=std::numeric_limits<float>::max();
    HDRRenderOptions overflow; overflow.exposureEV=4;
    bool rejected=false;
    try { renderHDRPair(source,overflow); } catch (const std::overflow_error&) { rejected=true; }
    check(rejected,"parallel workers lost finite overflow validation");
}
#endif

} // namespace

int main(int argc, char* argv[]) {
    try {
        const std::string name = argc >= 2 ? argv[1] : "";
        if (name == "identity") identity();
        else if (name == "tone") tone();
        else if (name == "color") color();
        else if (name == "rendition") rendition();
        else if (name == "effects") effects();
        else if (name == "detail") detail();
        else if (name == "look" && argc == 3) look(argv[2]);
        else if (name == "silver" && argc == 3) silver(argv[2]);
        else if (name == "white_balance") whiteBalance();
        else if (name == "geometry") geometry();
        else if (name == "validation") validation();
        else if (name == "move_reuse") moveReuse();
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
        else if (name == "parallel") parallel();
#endif
        else return 2;
        std::cout << "PASS hdr_" << name << '\n'; return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n'; return 1;
    }
}
