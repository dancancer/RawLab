#include "photo_color_grading.h"
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
RGB hueDirection(float hue) {
    const float sector=hue/60;
    const float x=1-std::abs(std::fmod(sector,2)-1);
    switch (static_cast<int>(sector)) {
        case 0:return RGB(1,x,0);
        case 1:return RGB(x,1,0);
        case 2:return RGB(0,1,x);
        case 3:return RGB(0,x,1);
        case 4:return RGB(x,0,1);
        default:return RGB(1,0,x);
    }
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
        const RGB direction=hueDirection(wheel.hue);
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
RGB applyColorGrading(const RGB& pixel, const ColorGradingOptions& options) {
    if (!options.active()) return pixel;
    return applyCoefficients(pixel,colorGradingCoefficients(options));
}
void applyColorGrading(ImageData& image, const ColorGradingOptions& options) {
    if (!options.active()) return;
    const auto coefficients=colorGradingCoefficients(options);
    for (auto& pixel : image.pixels) pixel=applyCoefficients(pixel,coefficients);
}
} // namespace sony2fuji
