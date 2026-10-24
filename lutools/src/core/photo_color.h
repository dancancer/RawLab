#pragma once

#include "sony2fuji/common.h"
#include <array>

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
RGB applyHsl(const RGB& pixel, const HslOptions& options);
void applyHsl(ImageData& image, const HslOptions& options);
bool estimateAutoExposure(const ImageData& image, ColorSpace space, const RGB& whiteBalance, float& ev);

} // namespace sony2fuji
