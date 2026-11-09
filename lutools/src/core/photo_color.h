#pragma once

#include "sony2fuji/common.h"
#include <array>
#include <cmath>

namespace sony2fuji {

struct HslOptions {
    std::array<float, 8> hue{};
    std::array<float, 8> saturation{};
    std::array<float, 8> lightness{};
    bool valid() const;
    bool active() const;
};

struct HslColor {
    float maximum = 0, minimum = 0, spread = 0;
    float hue = 0, saturation = 0, lightness = 0;
    size_t lower = 0, upper = 1;
    float blend = 0;
    bool valid = false;
    std::array<float, 8> weights() const;
    float value(const std::array<float, 8>& values) const;
};

HslColor analyzeHslColor(const RGB& pixel);
inline RGB hueUnitRGB(float hue) {
    const float sector = hue / 60;
    const float x = 1 - std::abs(std::fmod(sector, 2) - 1);
    switch (static_cast<int>(sector)) {
        case 0: return {1, x, 0};
        case 1: return {x, 1, 0};
        case 2: return {0, 1, x};
        case 3: return {0, x, 1};
        case 4: return {x, 0, 1};
        default: return {1, 0, x};
    }
}
RGB applyHsl(const RGB& pixel, const HslOptions& options);
void applyHsl(ImageData& image, const HslOptions& options);
bool estimateAutoExposure(const ImageData& image, ColorSpace space, const RGB& whiteBalance, float& ev,
    bool preserveBrightHighlights = false);

} // namespace sony2fuji
