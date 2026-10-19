#include "look_oracle.h"
#include <limits>

namespace sony2fuji::look_oracle {
float GammaConverter::applySRGBGamma(float linear) {
    if (linear <= 0.0031308f) {
        return 12.92f * linear;
    } else {
        return 1.055f * std::pow(linear, 1.0f / 2.4f) - 0.055f;
    }
}

float GammaConverter::applyFLog2(float linear) {
    const float a = 5.555556f;
    const float b = 0.064829f;
    const float c = 0.245281f;
    const float d = 0.384316f;
    const float e = 8.799461f;
    const float f = 0.092864f;
    const float cut = 0.00088899597f;

    float lin = linear;

    if (lin < cut) {
        return std::max(0.0f, std::min(1.0f, e * lin + f));
    }

    float encoded = std::log10(lin * a + b) * c + d;
    return std::max(0.0f, std::min(1.0f, encoded));
}

RGB GammaConverter::applyFLog2ToRGB(const RGB& rgb) {
    return RGB(
        applyFLog2(rgb.r),
        applyFLog2(rgb.g),
        applyFLog2(rgb.b)
    );
}

GammaConverter::FLog2Diagnostics GammaConverter::applyFLog2ToImage(
    ImageData& image,
    const FLog2Options& options
) {
    (void)options;
    FLog2Diagnostics result;
    if (image.pixels.empty()) return result;
    result.min_linear = std::numeric_limits<float>::max();
    result.max_linear = std::numeric_limits<float>::lowest();
    // Encoding must not change exposure based on image content.
    for (auto& pixel : image.pixels) {
        float low = std::min({pixel.r, pixel.g, pixel.b});
        float high = std::max({pixel.r, pixel.g, pixel.b});
        result.min_linear = std::min(result.min_linear, low);
        result.max_linear = std::max(result.max_linear, high);
        result.negative_pixels += low < 0;
        result.over_pixels += high > 1;
        pixel = applyFLog2ToRGB(pixel);
    }
    return result;
}

} // namespace sony2fuji::look_oracle
