#include "photo_color_grading.h"
#include "parallel_pixels.h"
#include "photo_color.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji {
namespace {
float smooth(float value) {
    const float t=std::clamp(value,0.f,1.f);
    return t*t*(3-2*t);
}
float luminance(const RGB& p) {
    return p.g+.2126f*(p.r-p.g)+.0722f*(p.b-p.g);
}
float linear(float value) {
    return value<=.04045f ? value/12.92f : std::pow((value+.055f)/1.055f,2.4f);
}
float encoded(float value) {
    return value<=.0031308f ? 12.92f*value : 1.055f*std::pow(value,1/2.4f)-.055f;
}
RGB wheelCoefficient(const ColorGradingWheel& wheel) {
    if (wheel.saturation == 0.0f) return {};
    const RGB direction = hueUnitRGB(wheel.hue);
    const float y = luminance(direction);
    const float strength = wheel.saturation / 100.0f;
    return RGB((direction.r - y) * strength, (direction.g - y) * strength, (direction.b - y) * strength);
}

RGB applyParameters(const RGB& pixel, const ColorGradingShaderParams& params) {
    const RGB p(linear(pixel.r), linear(pixel.g), linear(pixel.b));
    const float y = luminance(p);
    if (y <= 0.0f || y >= 1.0f) return pixel;
    const auto weights = colorGradingWeights(y, params.blending, params.balance);
    RGB delta;
    for (int zone = 0; zone < 3; ++zone) {
        delta.r += weights[zone] * params.coefficients[zone].r;
        delta.g += weights[zone] * params.coefficients[zone].g;
        delta.b += weights[zone] * params.coefficients[zone].b;
    }
    delta.r += params.coefficients[3].r;
    delta.g += params.coefficients[3].g;
    delta.b += params.coefficients[3].b;
    const float lumDelta = weights[0] * params.luminance[0]
                         + weights[1] * params.luminance[1]
                         + weights[2] * params.luminance[2]
                         + params.luminance[3];
    if (delta.r == 0.0f && delta.g == 0.0f && delta.b == 0.0f && lumDelta == 0.0f) return pixel;
    float targetY = y;
    float yScale = 1.0f;
    if (lumDelta != 0.0f) {
        const float u = encoded(y);
        const float c = std::clamp(0.75f * lumDelta, -0.95f, 0.95f);
        const float nextU = u + c * u * (1.0f - u);
        targetY = linear(nextU);
        yScale = targetY / y;
    }
    const float a = std::clamp(targetY, 0.0f, 1.0f);
    const float amplitude = a * (1.0f - a);
    if (lumDelta == 0.0f && amplitude == 0.0f) return pixel;
    const RGB chroma(
        (p.r - y) * yScale + amplitude * delta.r,
        (p.g - y) * yScale + amplitude * delta.g,
        (p.b - y) * yScale + amplitude * delta.b);
    // 保留旧阶段已有的越界极值，避免微小新强度触发一次不连续的 SDR 裁切。
    const float low = std::min({0.f, p.r, p.g, p.b});
    const float high = std::max({1.f, p.r, p.g, p.b});
    float gain = 1.0f;
    for (float c : {chroma.r, chroma.g, chroma.b}) {
        if (c > 0.0f) gain = std::min(gain, (high - targetY) / c);
        else if (c < 0.0f) gain = std::min(gain, (low - targetY) / c);
    }
    return RGB(encoded(std::clamp(targetY + gain * chroma.r, low, high)),
               encoded(std::clamp(targetY + gain * chroma.g, low, high)),
               encoded(std::clamp(targetY + gain * chroma.b, low, high)));
}
} // namespace

bool ColorGradingOptions::valid() const {
    auto validWheel = [](const ColorGradingWheel& w) {
        return std::isfinite(w.hue) && w.hue >= 0 && w.hue < 360 &&
               std::isfinite(w.saturation) && w.saturation >= 0 && w.saturation <= 100 &&
               std::isfinite(w.luminance) && w.luminance >= -100 && w.luminance <= 100;
    };
    for (const auto& w : wheels) {
        if (!validWheel(w)) return false;
    }
    if (!validWheel(global)) return false;
    if (!std::isfinite(blending) || blending < 0 || blending > 100) return false;
    if (!std::isfinite(balance) || balance < -100 || balance > 100) return false;
    return true;
}
bool ColorGradingOptions::active() const {
    for (const auto& w : wheels) {
        if (w.saturation != 0 || w.luminance != 0) return true;
    }
    return global.saturation != 0 || global.luminance != 0;
}
std::array<RGB,3> colorGradingCoefficients(const ColorGradingOptions& options) {
    std::array<RGB,3> result{};
    for (int zone=0;zone<3;++zone) {
        result[zone] = wheelCoefficient(options.wheels[zone]);
    }
    return result;
}
ColorGradingShaderParams colorGradingParameters(const ColorGradingOptions& options) {
    ColorGradingShaderParams params;
    for (int zone = 0; zone < 3; ++zone) {
        params.coefficients[zone] = wheelCoefficient(options.wheels[zone]);
        params.luminance[zone] = options.wheels[zone].luminance / 100.0f;
    }
    params.coefficients[3] = wheelCoefficient(options.global);
    params.luminance[3] = options.global.luminance / 100.0f;
    params.blending = options.blending;
    params.balance = options.balance;
    return params;
}
std::array<float,3> colorGradingWeights(float y) {
    const float shadows=1-smooth((y-.20f)/.35f);
    const float middle=smooth((y-.20f)/.30f)*(1-smooth((y-.50f)/.30f));
    const float highlights=smooth((y-.45f)/.35f);
    const float total=shadows+middle+highlights;
    return {shadows/total,middle/total,highlights/total};
}
std::array<float,3> colorGradingWeights(float y, float blending, float balance) {
    if (blending == 50.0f && balance == 0.0f) {
        return colorGradingWeights(y);
    }
    const float shift = 0.20f * (balance / 100.0f);
    const float sy = y + shift;
    const float scale = 0.05f + 1.90f * (blending / 100.0f);
    const float sW = 0.35f * scale;
    const float mW = 0.30f * scale;
    const float hW = 0.35f * scale;
    const float shadows = 1.0f - smooth((sy - (0.375f - 0.5f * sW)) / sW);
    const float middle = smooth((sy - (0.35f - 0.5f * mW)) / mW)
                       * (1.0f - smooth((sy - (0.65f - 0.5f * mW)) / mW));
    const float highlights = smooth((sy - (0.625f - 0.5f * hW)) / hW);
    const float total = shadows + middle + highlights;
    return {shadows / total, middle / total, highlights / total};
}
RGB applyColorGrading(const RGB& pixel, const ColorGradingOptions& options) {
    if (!options.active()) return pixel;
    return applyParameters(pixel, colorGradingParameters(options));
}
void applyColorGrading(ImageData& image, const ColorGradingOptions& options) {
    if (!options.active()) return;
    const auto params = colorGradingParameters(options);
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            image.pixels[i] = applyParameters(image.pixels[i], params);
        }
    });
}
} // namespace sony2fuji
