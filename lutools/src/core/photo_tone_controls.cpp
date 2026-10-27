#include "photo_tone_controls.h"
#include "parallel_pixels.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji {
namespace {
float smooth(float t) {
    t = std::clamp(t, 0.f, 1.f);
    return t*t*(3-2*t);
}

float luminance(const RGB& p) {
    // 差值形式令灰色的亮度严格等于其通道值，避免系数求和误差。
    return p.g + .2126f*(p.r-p.g) + .0722f*(p.b-p.g);
}

RGB bounded(const RGB& p) {
    return RGB(std::clamp(p.r,0.f,1.f),std::clamp(p.g,0.f,1.f),std::clamp(p.b,0.f,1.f));
}

float skinMask(const RGB& p, float maximum, float chroma, float y) {
    float hue;
    if (maximum == p.r) hue = 60*std::fmod((p.g-p.b)/chroma,6);
    else if (maximum == p.g) hue = 60*((p.b-p.r)/chroma+2);
    else hue = 60*((p.r-p.g)/chroma+4);
    if (hue < 0) hue += 360;
    float distance = std::abs(hue-35);
    distance = std::min(distance,360-distance);
    const float hueWeight = 1-smooth(distance/45);
    const float lightWeight = smooth((y-.08f)/.12f)*(1-smooth((y-.75f)/.20f));
    const float chromaWeight = smooth((chroma-.02f)/.08f)*(1-smooth((chroma-.6f)/.25f));
    return hueWeight*lightWeight*chromaWeight;
}
} // namespace

bool ToneControlsOptions::valid() const {
    for (float value : {blackPoint,whitePoint,vibrance})
        if (!std::isfinite(value) || std::abs(value)>1) return false;
    return true;
}

float blackWhiteOffset(float y, const ToneControlsOptions& options) {
    return .20f*(options.blackPoint*(1-smooth(y/.35f)) +
                 options.whitePoint*smooth((y-.65f)/.35f));
}

RGB applyBlackWhite(const RGB& pixel, const ToneControlsOptions& options) {
    if (options.blackPoint == 0 && options.whitePoint == 0) return pixel;
    const float offset = blackWhiteOffset(luminance(pixel),options);
    return bounded(RGB(pixel.r+offset,pixel.g+offset,pixel.b+offset));
}

RGB applyVibrance(const RGB& pixel, const ToneControlsOptions& options) {
    if (options.vibrance == 0) return pixel;
    const RGB& p = pixel;
    const float maximum = std::max({p.r,p.g,p.b});
    const float minimum = std::min({p.r,p.g,p.b});
    const float chroma = maximum-minimum;
    if (chroma == 0) return p;
    const bool inGamut = minimum >= 0 && maximum <= 1;
    // 已越界的旧 tone 工作值不能先截断，否则微小鲜艳度也会改变后续 HSL。
    // 正向在色域边界停止增强；负向沿原色度向量连续收敛到原亮度灰色。
    if (options.vibrance > 0 && !inGamut) return p;
    const float y = luminance(p);
    float gain;
    if (options.vibrance < 0) gain = 1+options.vibrance;
    else {
        const float saturation = chroma/maximum;
        const float lowSaturation = (1-saturation)*(1-saturation);
        gain = 1+options.vibrance*lowSaturation*(1-.75f*skinMask(p,maximum,chroma,y));
        // 沿恒亮度色度向量收敛到色域边界，不逐通道截断增强后的颜色。
        for (float channel : {p.r,p.g,p.b}) {
            const float difference = channel-y;
            if (difference > 0) gain = std::min(gain,(1-y)/difference);
            else if (difference < 0) gain = std::min(gain,-y/difference);
        }
    }
    if (gain == 1) return p;
    const RGB result(y+(p.r-y)*gain,y+(p.g-y)*gain,y+(p.b-y)*gain);
    return inGamut ? bounded(result) : result;
}

void applyBlackWhite(ImageData& image, const ToneControlsOptions& options) {
    if (options.blackPoint == 0 && options.whitePoint == 0) return;
    for (auto& p : image.pixels) p = applyBlackWhite(p,options);
}

void applyVibrance(ImageData& image, const ToneControlsOptions& options) {
    if (options.vibrance == 0) return;
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i=first;i<last;++i) image.pixels[i]=applyVibrance(image.pixels[i],options);
    });
}
} // namespace sony2fuji
