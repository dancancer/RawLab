#include "sony2fuji/color_recipe.h"
#include "sony2fuji/color_converter.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace sony2fuji {
namespace {
constexpr double pi = 3.14159265358979323846;
struct Lab { double l, a, b; };
struct Linear { double r, g, b; };

// Oklab 的公开转换矩阵与现有解析外观实验一致，不包含相机校准。
Lab toLab(const RGB& rgb) {
    const double r = GammaConverter::removeSRGBGamma(rgb.r);
    const double g = GammaConverter::removeSRGBGamma(rgb.g);
    const double b = GammaConverter::removeSRGBGamma(rgb.b);
    const double l = std::cbrt(.4122214708*r + .5363325363*g + .0514459929*b);
    const double m = std::cbrt(.2119034982*r + .6806995451*g + .1073969566*b);
    const double s = std::cbrt(.0883024619*r + .2817188376*g + .6299787005*b);
    return {.2104542553*l + .7936177850*m - .0040720468*s,
            1.9779984951*l - 2.4285922050*m + .4505937099*s,
            .0259040371*l + .7827717662*m - .8086757660*s};
}

Linear toLinear(const Lab& lab) {
    const double l = lab.l + .3963377774*lab.a + .2158037573*lab.b;
    const double m = lab.l - .1055613458*lab.a - .0638541728*lab.b;
    const double s = lab.l - .0894841775*lab.a - 1.2914855480*lab.b;
    return {4.0767416621*l*l*l - 3.3077115913*m*m*m + .2309699292*s*s*s,
            -1.2684380046*l*l*l + 2.6097574011*m*m*m - .3413193965*s*s*s,
            -.0041960863*l*l*l - .7034186147*m*m*m + 1.7076147010*s*s*s};
}

bool inGamut(const Linear& p) {
    constexpr double tolerance = 1e-7;
    return p.r >= -tolerance && p.g >= -tolerance && p.b >= -tolerance &&
           p.r <= 1+tolerance && p.g <= 1+tolerance && p.b <= 1+tolerance;
}

RGB encode(Lab lab) {
    Linear rgb = toLinear(lab);
    if (!inGamut(rgb)) {
        // 线性 RGB 立方体是凸集；沿中性灰方向收敛，避免蓝色附近 Oklab 射线多次进出色域造成跳变。
        const double gray = std::clamp(lab.l*lab.l*lab.l, 0.0, 1.0);
        double scale = 1;
        for (double channel : {rgb.r, rgb.g, rgb.b}) {
            if (channel < 0) scale = std::min(scale, gray/(gray-channel));
            if (channel > 1) scale = std::min(scale, (1-gray)/(channel-gray));
        }
        rgb = {gray + (rgb.r-gray)*scale, gray + (rgb.g-gray)*scale, gray + (rgb.b-gray)*scale};
    }
    return RGB(GammaConverter::applySRGBGamma(float(std::clamp(rgb.r, 0.0, 1.0))),
               GammaConverter::applySRGBGamma(float(std::clamp(rgb.g, 0.0, 1.0))),
               GammaConverter::applySRGBGamma(float(std::clamp(rgb.b, 0.0, 1.0))));
}

double smooth(double lo, double hi, double value) {
    const double t = std::clamp((value-lo)/(hi-lo), 0.0, 1.0);
    return t*t*(3-2*t);
}
}

ColorRecipe ColorRecipe::fromParameters(uint32_t version, const float* values, size_t count) {
    if (!values || !((version == 1 && count == 40) || (version == 2 && count == 44)))
        throw std::invalid_argument("Invalid color recipe version or shape");
    ColorRecipe recipe;
    std::copy_n(values, 40, recipe.values_.begin());
    if (version == 2) {
        std::copy_n(values+40, 4, recipe.regions_.begin());
        const auto& r = recipe.regions_;
        for (double value : r)
            if (!std::isfinite(value) || value < 0 || value > 1)
                throw std::invalid_argument("Invalid tone region boundary");
        // 允许 Float 转换的舍入误差；两条平滑曲线有序才能保证中间调权重非负。
        if (r[1]-r[0] < .05-1e-7 || r[3]-r[2] < .05-1e-7 || r[0] > r[2] || r[1] > r[3])
            throw std::invalid_argument("Invalid tone region ordering or width");
    }
    for (float value : recipe.values_)
        if (!std::isfinite(value)) throw std::invalid_argument("Nonfinite color recipe");
    auto bounded = [&](size_t index, float low, float high) {
        if (values[index] < low || values[index] > high) throw std::invalid_argument("Color recipe value outside range");
    };
    for (int i = 0; i < 9; ++i) {
        bounded(i, 0, 1);
        if (i) {
            const float slope = (values[i]-values[i-1])*8;
            if (slope < .05f || slope > 4) throw std::invalid_argument("Invalid tone curve slope");
        }
    }
    if (values[0] > .1f || values[8] < .9f) throw std::invalid_argument("Invalid tone curve endpoints");
    bounded(9, 0, 2);
    for (int i = 0; i < 8; ++i) {
        bounded(10+i*3, -30, 30);
        bounded(11+i*3, 0, 2);
        bounded(12+i*3, -.08f, .08f);
    }
    for (int i = 34; i < 40; ++i) bounded(i, -.03f, .03f);
    return recipe;
}

RGB ColorRecipe::apply(const RGB& displaySrgb) const {
    const Lab original = toLab(displaySrgb);
    const double position = std::clamp(original.l, 0.0, 1.0)*8;
    const int segment = std::min(7, int(position));
    double lightness = values_[segment] + (values_[segment+1]-values_[segment])*(position-segment);
    const double chroma = std::hypot(original.a, original.b);
    const double hue = std::atan2(original.b, original.a);
    const double colored = chroma*chroma/(chroma*chroma + .035*.035);
    double weightSum = 0, rotation = 0, scale = 0, lift = 0;
    constexpr double width = 35*pi/180;
    for (int i = 0; i < 8; ++i) {
        const double weight = std::exp((std::cos(hue-i*pi/4)-1)/(width*width));
        weightSum += weight;
        rotation += weight*values_[10+i*3];
        scale += weight*values_[11+i*3];
        lift += weight*values_[12+i*3];
    }
    lightness = std::clamp(lightness + lift/weightSum*colored, 0.0, 1.0);
    const double shiftedHue = hue + rotation/weightSum*colored*pi/180;
    const double shiftedChroma = chroma*values_[9]*(1+(scale/weightSum-1)*colored);
    Lab graded{lightness, shiftedChroma*std::cos(shiftedHue), shiftedChroma*std::sin(shiftedHue)};
    const double shadow = 1-smooth(regions_[0],regions_[1],lightness);
    const double highlight = smooth(regions_[2],regions_[3],lightness);
    const double weights[3] = {shadow, 1-shadow-highlight, highlight};
    const double endpointProtection = 4*lightness*(1-lightness);
    for (int i = 0; i < 3; ++i) {
        graded.a += values_[34+i*2]*weights[i]*endpointProtection;
        graded.b += values_[35+i*2]*weights[i]*endpointProtection;
    }
    return encode(graded);
}

} // namespace sony2fuji
