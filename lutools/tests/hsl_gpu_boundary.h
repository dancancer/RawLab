#pragma once

#include "gpu/photo_gpu.h"
#include <algorithm>
#include <cmath>
#include <iostream>

namespace rawlabtest {

template<class Render>
bool hslGpuBoundary(Render render) {
    using namespace sony2fuji;
    // 反解中性显示曲线；contrast=2 后在 HSL 入口产生明确的负值和大于 1 的值。
    const auto sceneValue = [](float displayed) {
        const float encoded = (displayed + .5f) * .5f;
        const float linear = encoded <= .04045f ? encoded / 12.92f :
            std::pow((encoded + .055f) / 1.055f, 2.4f);
        return .1845f / std::pow((1 / linear - 1) * .1845f / (1 - .1845f), 1 / 1.5f);
    };
    ImageData input(12, 1);
    size_t index = 0;
    for (float low : {-.015f, .975f}) {
        const float high = low + .04f;
        for (const RGB pixel : {RGB(high, low, low), RGB(high, high, low), RGB(low, high, low),
                 RGB(low, high, high), RGB(low, low, high), RGB(high, low, high)})
            input.pixels[index++] = RGB(sceneValue(pixel.r), sceneValue(pixel.g), sceneValue(pixel.b));
    }
    sony2fuji_request request{};
    request.brightness = request.saturation = 1; request.contrast = 2;
    request.intent = SONY2FUJI_INTENT_FINAL;
    ImageData baseline;
    if (!render(input, request, {}, baseline) || baseline.pixels.size() != input.pixels.size()) return false;
    bool below = false, above = false;
    for (const auto& pixel : baseline.pixels) {
        below |= std::min({pixel.r, pixel.g, pixel.b}) < 0;
        above |= std::max({pixel.r, pixel.g, pixel.b}) > 1;
    }
    if (!below || !above) return false;
    HslOptions options;
    options.hue[4] = 12; options.saturation[0] = -20; options.lightness[5] = 10;
    float maximum = 0;
    for (float greenLightness : {0.f, 10.f}) {
        options.lightness[3] = greenLightness;
        ImageData actual;
        if (!render(input, request, options, actual) || actual.pixels.size() != baseline.pixels.size()) return false;
        for (size_t i = 0; i < actual.pixels.size(); ++i) {
            const auto expected = applyHsl(baseline.pixels[i], options);
            const auto pixel = actual.pixels[i];
            if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b)) return false;
            maximum = std::max({maximum, std::abs(pixel.r - expected.r),
                std::abs(pixel.g - expected.g), std::abs(pixel.b - expected.b)});
        }
    }
    std::cout << "HSL out-of-range CPU/GPU max=" << maximum << '\n';
    return maximum <= 5e-5f;
}
}
