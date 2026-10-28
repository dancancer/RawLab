#include "core/hdr_rendering.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

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
    HDRRenderOptions options; options.processingVersion = 2;
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

} // namespace

int main(int argc, char* argv[]) {
    try {
        const std::string name = argc == 2 ? argv[1] : "";
        if (name == "identity") identity();
        else if (name == "tone") tone();
        else if (name == "white_balance") whiteBalance();
        else if (name == "geometry") geometry();
        else if (name == "validation") validation();
        else return 2;
        std::cout << "PASS hdr_" << name << '\n'; return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n'; return 1;
    }
}
