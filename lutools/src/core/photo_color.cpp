#include "photo_color.h"
#include "sony2fuji/color_converter.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace sony2fuji {

bool HslOptions::valid() const {
    for (const auto* values : {&hue, &saturation, &lightness})
        for (float value : *values)
            if (!std::isfinite(value) || std::abs(value) > 100) return false;
    return true;
}

bool HslOptions::active() const {
    for (const auto* values : {&hue, &saturation, &lightness})
        for (float value : *values)
            if (value != 0) return true;
    return false;
}

HslColor analyzeHslColor(const RGB& pixel) {
    HslColor color;
    if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b)) return color;
    color.maximum = std::max({pixel.r, pixel.g, pixel.b});
    color.minimum = std::min({pixel.r, pixel.g, pixel.b});
    color.spread = color.maximum - color.minimum;
    if (color.spread <= 1e-6f) return color;
    if (color.maximum == pixel.r) color.hue = 60 * std::fmod((pixel.g-pixel.b)/color.spread, 6);
    else if (color.maximum == pixel.g) color.hue = 60 * ((pixel.b-pixel.r)/color.spread + 2);
    else color.hue = 60 * ((pixel.r-pixel.g)/color.spread + 4);
    if (color.hue < 0) color.hue += 360;
    constexpr float centers[] = {0,30,60,120,180,240,270,300,360};
    while (color.lower < 7 && color.hue >= centers[color.lower+1]) ++color.lower;
    color.upper = (color.lower+1) % 8;
    color.blend = (color.hue-centers[color.lower])/(centers[color.lower+1]-centers[color.lower]);
    color.blend = color.blend*color.blend*(3-2*color.blend);
    color.lightness = std::clamp((color.maximum+color.minimum)*.5f, 0.0f, 1.0f);
    color.saturation = color.spread / std::max(1e-6f, 1-std::abs(2*color.lightness-1));
    color.valid = true;
    return color;
}

std::array<float, 8> HslColor::weights() const {
    std::array<float, 8> result{};
    if (valid) { result[lower] = 1-blend; result[upper] = blend; }
    return result;
}

float HslColor::value(const std::array<float, 8>& values) const {
    return values[lower]*(1-blend) + values[upper]*blend;
}

RGB applyHsl(const RGB& pixel, const HslOptions& options) {
    if (!options.active()) return pixel;
    const auto color = analyzeHslColor(pixel);
    if (!color.valid) return pixel;
    const float maximum = color.maximum, minimum = color.minimum, delta = color.spread;
    float hue = color.hue;
    const float dh = color.value(options.hue), ds = color.value(options.saturation);
    float dl = color.value(options.lightness);
    // 近灰色的色相不稳定，避免浮点误差被放大为分色明度跳变。
    const float colorWeight = std::clamp(delta * 255.f, 0.f, 1.f);
    dl *= colorWeight * colorWeight * (3 - 2 * colorWeight);
    if (dh == 0 && ds == 0 && dl == 0) return pixel;
    float lightness = color.lightness;
    float saturation = color.saturation;
    RGB residual;
    if (minimum < 0 || maximum > 1) {
        // HSL 限幅会改变越界像素的无调整基准；只叠加调整量，避免未调整色相边界跳变。
        const float baseChroma = (1-std::abs(2*lightness-1)) * std::clamp(saturation, 0.0f, 1.0f);
        const float scale = baseChroma / delta;
        const float offset = lightness - baseChroma*.5f;
        residual = RGB(pixel.r - ((pixel.r-minimum)*scale+offset),
            pixel.g - ((pixel.g-minimum)*scale+offset), pixel.b - ((pixel.b-minimum)*scale+offset));
    }
    hue = std::fmod(hue + dh*.3f + 360, 360);
    saturation = std::clamp(saturation*(1+ds*.01f), 0.0f, 1.0f);
    lightness = std::clamp(lightness+dl*.005f, 0.0f, 1.0f);
    const float chroma = (1-std::abs(2*lightness-1))*saturation;
    const float x = chroma*(1-std::abs(std::fmod(hue/60,2)-1));
    const float offset = lightness-chroma*.5f;
    RGB rgb;
    if (hue < 60) rgb = RGB(chroma,x,0);
    else if (hue < 120) rgb = RGB(x,chroma,0);
    else if (hue < 180) rgb = RGB(0,chroma,x);
    else if (hue < 240) rgb = RGB(0,x,chroma);
    else if (hue < 300) rgb = RGB(x,0,chroma);
    else rgb = RGB(chroma,0,x);
    return RGB(rgb.r+offset+residual.r,rgb.g+offset+residual.g,rgb.b+offset+residual.b);
}

void applyHsl(ImageData& image, const HslOptions& options) {
    if (!options.active()) return;
    for (auto& pixel : image.pixels) pixel = applyHsl(pixel, options);
}

bool estimateAutoExposure(const ImageData& image, ColorSpace space, const RGB& whiteBalance, float& ev) {
    if (image.width <= 0 || image.height <= 0 || image.pixels.empty()) return false;
    const int columns = std::min(256, image.width), rows = std::min(256, image.height);
    std::vector<float> samples;
    samples.reserve(static_cast<size_t>(columns)*rows);
    ColorConverter converter;
    const auto matrix = ColorConverter::getConversionMatrix(space, ColorSpace::sRGB);
    for (int y=0; y<rows; ++y) {
        const int sy = static_cast<int>((int64_t(2*y+1)*image.height)/(2*rows));
        for (int x=0; x<columns; ++x) {
            const int sx = static_cast<int>((int64_t(2*x+1)*image.width)/(2*columns));
            const auto pixel = converter.applyMatrix(image.pixels[static_cast<size_t>(sy)*image.width+sx], matrix);
            const float luminance = .2126f*pixel.r*whiteBalance.r + .7152f*pixel.g*whiteBalance.g + .0722f*pixel.b*whiteBalance.b;
            if (std::isfinite(luminance)) samples.push_back(std::max(0.0f,luminance));
        }
    }
    if (samples.empty()) return false;
    std::sort(samples.begin(), samples.end());
    const float median = samples[samples.size()/2];
    const float highlights = samples[static_cast<size_t>((samples.size()-1)*.995)];
    if (highlights <= 1e-6f) return false;
    float result = std::log2(.1845f/std::max(median,1e-6f));
    if (result > 0 && highlights > 0) result = std::min(result,std::log2(4/highlights));
    ev = std::clamp(result,-4.0f,4.0f);
    return true;
}

} // namespace sony2fuji
