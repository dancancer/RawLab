#pragma once

#include "sony2fuji/common.h"
#include <array>

namespace sony2fuji {

struct ColorGradingWheel {
    float hue = 0;
    float saturation = 0;
    float luminance = 0;
};

struct ColorGradingOptions {
    std::array<ColorGradingWheel,3> wheels{};
    ColorGradingWheel global{};
    float blending = 50.0f;
    float balance = 0.0f;
    bool valid() const;
    bool active() const;
};

struct ColorGradingShaderParams {
    std::array<RGB, 4> coefficients{};
    std::array<float, 4> luminance{};
    float blending = 50.0f;
    float balance = 0.0f;
};

std::array<RGB,3> colorGradingCoefficients(const ColorGradingOptions& options);
ColorGradingShaderParams colorGradingParameters(const ColorGradingOptions& options);
std::array<float,3> colorGradingWeights(float linearLuminance);
std::array<float,3> colorGradingWeights(float linearLuminance, float blending, float balance);
RGB applyColorGradingParameters(const RGB& pixel, const ColorGradingShaderParams& params);
RGB applyColorGrading(const RGB& pixel, const ColorGradingOptions& options);
void applyColorGrading(ImageData& image, const ColorGradingOptions& options);

} // namespace sony2fuji
