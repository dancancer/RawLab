#pragma once

#include "sony2fuji/common.h"
#include <array>

namespace sony2fuji {

struct ColorGradingWheel {
    float hue = 0;
    float saturation = 0;
};

struct ColorGradingOptions {
    std::array<ColorGradingWheel,3> wheels{};
    bool valid() const;
    bool active() const;
};

std::array<RGB,3> colorGradingCoefficients(const ColorGradingOptions& options);
std::array<float,3> colorGradingWeights(float linearLuminance);
RGB applyColorGrading(const RGB& pixel, const ColorGradingOptions& options);
void applyColorGrading(ImageData& image, const ColorGradingOptions& options);

} // namespace sony2fuji
