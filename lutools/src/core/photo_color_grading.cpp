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
    if (value <= .04045f) return value / 12.92f;
    if (value > 1.f) return std::pow((value + .055f) / 1.055f, 2.4f);
    static const auto& table = []() -> const std::array<float, 4097>& {
        static std::array<float, 4097> t{};
        constexpr double kMin = 0.04045;
        constexpr double kSpan = 1.0 - kMin;
        for (size_t i = 0; i < t.size(); ++i) {
            const double x = kMin + (static_cast<double>(i) / 4096.0) * kSpan;
            t[i] = static_cast<float>(std::pow((x + 0.055) / 1.055, 2.4));
        }
        return t;
    }();
    constexpr float kMin = .04045f;
    constexpr float kScale = 4096.f / (1.f - kMin);
    const float s = (value - kMin) * kScale;
    const size_t idx = std::min<size_t>(4095, static_cast<size_t>(s));
    const float frac = s - static_cast<float>(idx);
    return table[idx] + (table[idx + 1] - table[idx]) * frac;
}
float encoded(float value) {
    if (value <= .0031308f) return 12.92f * value;
    if (value > 1.f) return 1.055f * std::pow(value, 1.f / 2.4f) - .055f;
    static const auto& tables = []() {
        struct Tables {
            std::array<float, 4097> low{};
            std::array<float, 4097> high{};
        };
        static Tables t;
        constexpr double kSplit = 0.05;
        constexpr double kMin = 0.0031308;
        for (size_t i = 0; i <= 4096; ++i) {
            const double xLo = kMin + (static_cast<double>(i) / 4096.0) * (kSplit - kMin);
            t.low[i] = static_cast<float>(1.055 * std::pow(xLo, 1.0 / 2.4) - 0.055);
            const double xHi = kSplit + (static_cast<double>(i) / 4096.0) * (1.0 - kSplit);
            t.high[i] = static_cast<float>(1.055 * std::pow(xHi, 1.0 / 2.4) - 0.055);
        }
        return &t;
    }();
    if (value <= .05f) {
        constexpr float kScale = 4096.f / (.05f - .0031308f);
        const float s = (value - .0031308f) * kScale;
        const size_t idx = std::min<size_t>(4095, static_cast<size_t>(s));
        const float frac = s - static_cast<float>(idx);
        return tables->low[idx] + (tables->low[idx + 1] - tables->low[idx]) * frac;
    }
    constexpr float kScale = 4096.f / (1.f - .05f);
    const float s = (value - .05f) * kScale;
    const size_t idx = std::min<size_t>(4095, static_cast<size_t>(s));
    const float frac = s - static_cast<float>(idx);
    return tables->high[idx] + (tables->high[idx + 1] - tables->high[idx]) * frac;
}
RGB applyCoefficients(const RGB& pixel, const std::array<RGB,3>& coefficients) {
    const RGB p(linear(pixel.r),linear(pixel.g),linear(pixel.b));
    const float y=luminance(p);
    const float a=std::clamp(y,0.f,1.f);
    const float amplitude=a*(1-a);
    if (amplitude==0) return pixel;
    const auto weights=colorGradingWeights(y);
    RGB delta;
    for (int zone=0;zone<3;++zone) {
        delta.r+=weights[zone]*coefficients[zone].r;
        delta.g+=weights[zone]*coefficients[zone].g;
        delta.b+=weights[zone]*coefficients[zone].b;
    }
    if (delta.r==0 && delta.g==0 && delta.b==0) return pixel;
    const RGB chroma(p.r-y+amplitude*delta.r,p.g-y+amplitude*delta.g,p.b-y+amplitude*delta.b);
    // 保留旧阶段已有的越界极值，避免微小新强度触发一次不连续的 SDR 裁切。
    const float low=std::min({0.f,p.r,p.g,p.b});
    const float high=std::max({1.f,p.r,p.g,p.b});
    float gain=1;
    for (float c : {chroma.r,chroma.g,chroma.b}) {
        if (c>0) gain=std::min(gain,(high-y)/c);
        else if (c<0) gain=std::min(gain,(low-y)/c);
    }
    return RGB(encoded(std::clamp(y+gain*chroma.r,low,high)),
               encoded(std::clamp(y+gain*chroma.g,low,high)),
               encoded(std::clamp(y+gain*chroma.b,low,high)));
}
} // namespace

bool ColorGradingOptions::valid() const {
    for (const auto& w : wheels)
        if (!std::isfinite(w.hue) || w.hue<0 || w.hue>=360 ||
            !std::isfinite(w.saturation) || w.saturation<0 || w.saturation>100) return false;
    return true;
}
bool ColorGradingOptions::active() const {
    for (const auto& w : wheels) if (w.saturation!=0) return true;
    return false;
}
std::array<RGB,3> colorGradingCoefficients(const ColorGradingOptions& options) {
    std::array<RGB,3> result{};
    for (int zone=0;zone<3;++zone) {
        const auto& wheel=options.wheels[zone];
        if (wheel.saturation==0) continue;
        const RGB direction=hueUnitRGB(wheel.hue);
        const float y=luminance(direction),strength=wheel.saturation/100;
        result[zone]=RGB((direction.r-y)*strength,(direction.g-y)*strength,(direction.b-y)*strength);
    }
    return result;
}
std::array<float,3> colorGradingWeights(float y) {
    const float shadows=1-smooth((y-.20f)/.35f);
    const float middle=smooth((y-.20f)/.30f)*(1-smooth((y-.50f)/.30f));
    const float highlights=smooth((y-.45f)/.35f);
    const float total=shadows+middle+highlights;
    return {shadows/total,middle/total,highlights/total};
}
RGB applyColorGradingCoefficients(const RGB& pixel, const std::array<RGB,3>& coefficients) {
    return applyCoefficients(pixel, coefficients);
}
RGB applyColorGrading(const RGB& pixel, const ColorGradingOptions& options) {
    if (!options.active()) return pixel;
    return applyCoefficients(pixel,colorGradingCoefficients(options));
}
void applyColorGrading(ImageData& image, const ColorGradingOptions& options) {
    if (!options.active()) return;
    const auto coefficients=colorGradingCoefficients(options);
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            image.pixels[i] = applyCoefficients(image.pixels[i], coefficients);
        }
    });
}
} // namespace sony2fuji
