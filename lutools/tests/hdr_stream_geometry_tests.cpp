#include "core/hdr_rendering.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>

using namespace sony2fuji;

namespace {
void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

HDRImagePair fixture(int width, int height) {
    HDRImagePair image;
    image.hdr = ImageData(width, height); image.sdr = ImageData(width, height);
    image.nativeWidth = width; image.nativeHeight = height; image.sourceHeadroom = 8;
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        const float value = float((x * 37 + y * 113) % 997) / 997;
        image.hdr.at(x, y) = {value * 8 - .1f, value * 3, value * 2 + .07f};
        image.sdr.at(x, y) = {value, value * .7f, value * .3f};
    }
    return image;
}

void compare(const HDRImagePair& source, const HDRRenderOptions& options) {
    const auto expected = renderHDRPair(source, options);
    const auto geometrySize = geometryOutputSize(source.hdr.width, source.hdr.height, options.geometry);
    const auto size = hdrResizeSize(geometrySize.first, geometrySize.second, options.longEdge);
    check(size.first == expected.hdr.width && size.second == expected.hdr.height, "Stream output dimensions differ");
    const auto geometry = makeGeometrySampler(source.hdr.width, source.hdr.height, options.geometry);
    const PhotoEffectSampler effects(options.effects, size.first, size.second);
    for (const bool hdr : {true, false}) {
        const auto& input = hdr ? source.hdr : source.sdr;
        ImageData edited(input.width, input.height);
        // 行块尾部故意不整除；颜色必须在全局几何之前完成。
        for (int top = 0; top < input.height; top += 17) {
            ImageData strip(input.width, std::min(17, input.height - top));
            std::copy_n(input.pixels.data() + size_t(top) * input.width, strip.pixels.size(), strip.pixels.data());
            editHDRPixels(strip, options, hdr);
            std::copy(strip.pixels.begin(), strip.pixels.end(), edited.pixels.begin() + size_t(top) * input.width);
        }
        const GeometryPixelReader read = [&](int x, int y) { return edited.at(x, y); };
        const GeometryPixelReader transformed = [&](int x, int y) { return geometry(x, y, read); };
        const GeometryPixelReader resized = [&](int x, int y) {
            return sampleHDRResize(x, y, geometrySize.first, geometrySize.second, size.first, size.second, transformed);
        };
        ImageData actual(size.first, size.second);
        const double peak = hdr && options.rendition.peakLimitEV > 0 ? std::exp2(double(options.rendition.peakLimitEV)) : 0;
        if (options.hasDetail()) {
            const auto plan = planHDRDetail(actual.width, actual.height, options.detail, peak, resized);
            for (int top = 0; top < actual.height; top += 19) {
                const int end = std::min(top + 19, actual.height);
                const int first = std::max(0, top - plan.halo), last = std::min(actual.height, end + plan.halo);
                ImageData band(actual.width, last - first);
                for (int y = first; y < last; ++y) for (int x = 0; x < actual.width; ++x)
                    band.at(x, y - first) = resized(x, y);
                renderHDRDetailBand(plan, band.pixels.data(), first, last - first,
                    actual.pixels.data() + size_t(top) * actual.width, top, end - top);
            }
        } else {
            for (int top = 0; top < actual.height; top += 19) for (int left = 0; left < actual.width; left += 31)
                for (int y = top; y < std::min(top + 19, actual.height); ++y)
                    for (int x = left; x < std::min(left + 31, actual.width); ++x) actual.at(x, y) = resized(x, y);
        }
        if (options.hasPhotoEffects())
            for (int y = 0; y < actual.height; ++y) for (int x = 0; x < actual.width; ++x)
                actual.at(x, y) = effects.applyExtendedLinear(actual.at(x, y), x, y, peak);
        const auto& reference = hdr ? expected.hdr : expected.sdr;
        check(std::memcmp(actual.pixels.data(), reference.pixels.data(), actual.pixels.size() * sizeof(RGB)) == 0,
            "Stream geometry/resize changes float bits or introduces a tile seam");
    }
}
}

int main() {
    try {
        const auto source = fixture(267, 139);
        int cases = 0;
        for (int turn = 0; turn < 4; ++turn) for (bool flipX : {false, true}) for (bool flipY : {false, true})
            for (float angle : {0.f, -13.25f, 45.f}) for (uint32_t edge : {0u, 61u, 1u}) {
                HDRRenderOptions options;
                options.exposureEV = .25f; options.temperature = 7300; options.tint = 8;
                options.contrast = 12; options.highlights = -15; options.shadows = 10; options.saturation = 5;
                options.geometry.quarter_turns = turn; options.geometry.flip_horizontal = flipX;
                options.geometry.flip_vertical = flipY; options.geometry.straighten_degrees = angle;
                options.geometry.perspective_horizontal = angle == 0 ? 0 : -.37f;
                options.geometry.perspective_vertical = angle == 0 ? 0 : .23f;
                options.geometry.crop_x = .13f; options.geometry.crop_y = .21f;
                options.geometry.crop_width = .61f; options.geometry.crop_height = .79f;
                options.longEdge = edge; compare(source, options); ++cases;
            }
        for (const auto size : {std::pair{1, 1}, std::pair{1, 113}, std::pair{111, 1}}) {
            auto tiny = fixture(size.first, size.second);
            HDRRenderOptions options; compare(tiny, options);
            options.geometry.quarter_turns = 1; options.geometry.straighten_degrees = -45;
            options.longEdge = 1; compare(tiny, options); cases += 2;
        }
        HDRRenderOptions crop;
        crop.geometry.crop_x = .99f; crop.geometry.crop_y = .99f;
        crop.geometry.crop_width = crop.geometry.crop_height = .000001f;
        compare(source, crop); compare(source, {});
        HDRRenderOptions tone;
        tone.processingVersion = SONY2FUJI_HDR_PROCESSING_TONE_VERSION;
        tone.tone.blackPoint = -50;
        tone.tone.whitePoint = 40;
        tone.tone.curveStrength = 60;
        tone.geometry.quarter_turns = 1;
        tone.longEdge = 127;
        compare(source, tone);
        auto& curve = tone.tone.curve;
        curve.mode = SONY2FUJI_CURVE_CUSTOM; curve.count = 3;
        curve.points[0] = {0, 0}; curve.points[1] = {.5, .4375}; curve.points[2] = {1, 1};
        compare(source, tone);
        tone.processingVersion = SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION;
        tone.color.vibrance = 40;
        tone.color.hsl.hue[2] = 15;
        tone.color.grading.wheels[2] = {225, 25};
        tone.rendition = {1.5f, -.5f, 20, -30};
        compare(source, tone);
        tone.processingVersion = SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION;
        tone.geometry.crop_x = .05f; tone.geometry.crop_width = .89f;
        tone.geometry.straighten_degrees = -7;
        tone.effects = {-63, 34, 30, 55, 60, 72, 18, 64};
        for (uint32_t edge : {0u, 171u, 1u}) { tone.longEdge = edge; compare(source, tone); }
        tone.processingVersion = SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION;
        tone.detail = {1.4f, -.8f, .6f, .8f};
        for (uint32_t edge : {0u, 171u, 1u}) { tone.longEdge = edge; compare(source, tone); }
        std::cout << "PASS " << cases + 11 << " stream color/geometry/resize combinations, exact float equality\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
