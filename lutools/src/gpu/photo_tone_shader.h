#pragma once

#include "sony2fuji/common.h"

#include <algorithm>
#include <cmath>
#include <string>

namespace sony2fuji {

#define RAWLAB_HIGHLIGHTS_SHADOWS_BODY \
RAWLAB_HS_FN float hsLuminance(RAWLAB_HS_RGB pixel) { \
    return 0.2126f * pixel.r + 0.7152f * pixel.g + 0.0722f * pixel.b; \
} \
RAWLAB_HS_FN float hsShadows(float value, float shadows) { \
    if (shadows == 0.0f) { \
        return value; \
    } \
    float t = RAWLAB_HS_CLAMP(shadows, -1.0f, 1.0f); \
    float gamma = t > 0.0f ? (1.0f - t * 0.5f) : (1.0f + (-t) * 0.5f); \
    return RAWLAB_HS_POW(RAWLAB_HS_CLAMP01(value), gamma); \
} \
RAWLAB_HS_FN float hsHighlights(float value, float highlights) { \
    if (highlights == 0.0f) { \
        return value; \
    } \
    float t = RAWLAB_HS_CLAMP(highlights, -1.0f, 1.0f); \
    float inv = 1.0f - RAWLAB_HS_CLAMP01(value); \
    float gamma = t > 0.0f ? (1.0f - t * 0.5f) : (1.0f + (-t) * 0.5f); \
    return 1.0f - RAWLAB_HS_POW(inv, gamma); \
} \
RAWLAB_HS_FN RAWLAB_HS_RGB hsApplyHighlightsShadows(RAWLAB_HS_RGB pixel, float highlights, float shadows) { \
    if (highlights == 0.0f && shadows == 0.0f) { \
        return pixel; \
    } \
    float luminance = hsLuminance(pixel); \
    float adjusted = hsHighlights(hsShadows(luminance, shadows), highlights); \
    if (luminance > 0.0f) { \
        float ratio = adjusted / luminance; \
        return RAWLAB_HS_RGB3(pixel.r * ratio, pixel.g * ratio, pixel.b * ratio); \
    } \
    return RAWLAB_HS_RGB3(adjusted, adjusted, adjusted); \
}

#define RAWLAB_HS_FN inline
#define RAWLAB_HS_RGB sony2fuji::RGB
#define RAWLAB_HS_RGB3(r, g, b) sony2fuji::RGB((r), (g), (b))
#define RAWLAB_HS_CLAMP(x, low, high) std::max((low), std::min((high), (x)))
#define RAWLAB_HS_CLAMP01(x) std::max(0.0f, std::min(1.0f, (x)))
#define RAWLAB_HS_POW(x, y) std::pow((x), (y))

namespace detail {
RAWLAB_HIGHLIGHTS_SHADOWS_BODY
} // namespace detail

#undef RAWLAB_HS_FN
#undef RAWLAB_HS_RGB
#undef RAWLAB_HS_RGB3
#undef RAWLAB_HS_CLAMP
#undef RAWLAB_HS_CLAMP01
#undef RAWLAB_HS_POW

#define RAWLAB_TONE_SHADER_STR(...) #__VA_ARGS__
#define RAWLAB_TONE_SHADER_TEXT(body) RAWLAB_TONE_SHADER_STR(body)

// 三种 shader 共用同一公式和常量；只替换语言的向量类型。
inline std::string toneControlsShader(const char* vectorType) {
    return std::string("\n#define TC_RGB ") + vectorType + R"shader(
float tcSmooth(float t) {
    t=clamp(t,0.0,1.0); return t*t*(3.0-2.0*t);
}
float tcLuminance(TC_RGB p) {
    return p.g+0.2126*(p.r-p.g)+0.0722*(p.b-p.g);
}
TC_RGB tcBlackWhite(TC_RGB pixel, float blackPoint, float whitePoint) {
    if (blackPoint==0.0 && whitePoint==0.0) return pixel;
    float y=tcLuminance(pixel);
    float offset=0.20*(blackPoint*(1.0-tcSmooth(y/0.35))+whitePoint*tcSmooth((y-0.65)/0.35));
    return clamp(pixel+offset,0.0,1.0);
}
float tcSkinMask(TC_RGB p, float maximum, float chroma, float y) {
    float hue;
    if (maximum==p.r) hue=(p.g-p.b)/chroma;
    else if (maximum==p.g) hue=(p.b-p.r)/chroma+2.0;
    else hue=(p.r-p.g)/chroma+4.0;
    hue*=60.0;
    if (hue<0.0) hue+=360.0;
    float distance=abs(hue-35.0); distance=min(distance,360.0-distance);
    float hueWeight=1.0-tcSmooth(distance/45.0);
    float lightWeight=tcSmooth((y-0.08)/0.12)*(1.0-tcSmooth((y-0.75)/0.20));
    float chromaWeight=tcSmooth((chroma-0.02)/0.08)*(1.0-tcSmooth((chroma-0.60)/0.25));
    return hueWeight*lightWeight*chromaWeight;
}
TC_RGB tcVibrance(TC_RGB p, float vibrance) {
    if (vibrance==0.0) return p;
    float maximum=max(max(p.r,p.g),p.b), minimum=min(min(p.r,p.g),p.b);
    float chroma=maximum-minimum;
    if (chroma==0.0) return p;
    bool inGamut=minimum>=0.0 && maximum<=1.0;
    if (vibrance>0.0 && !inGamut) return p;
    float y=tcLuminance(p), gain;
    if (vibrance<0.0) gain=1.0+vibrance;
    else {
        float saturation=chroma/maximum;
        float lowSaturation=(1.0-saturation)*(1.0-saturation);
        gain=1.0+vibrance*lowSaturation*(1.0-0.75*tcSkinMask(p,maximum,chroma,y));
        for (int channel=0;channel<3;++channel) {
            float difference=p[channel]-y;
            if (difference>0.0) gain=min(gain,(1.0-y)/difference);
            else if (difference<0.0) gain=min(gain,-y/difference);
        }
    }
    if (gain==1.0) return p;
    TC_RGB result=TC_RGB(y,y,y)+(p-TC_RGB(y,y,y))*gain;
    return inGamut ? clamp(result,0.0,1.0) : result;
}
float tcBasicContrastV3(float value, float amount) {
    if (amount == 0.0 || value <= 0.0 || value >= 1.0) return value;
    float exponent = exp2(clamp(amount, -1.0, 1.0) * 0.75);
    float low = pow(value, exponent);
    float high = pow(1.0 - value, exponent);
    return low / (low + high);
}
TC_RGB tcBasicBlackWhiteV3(TC_RGB pixel, float blackPoint, float whitePoint) {
    if (blackPoint == 0.0 && whitePoint == 0.0) return pixel;
    TC_RGB result = pixel;
    if (blackPoint < 0.0) {
        float black = 0.24 * blackPoint * blackPoint;
        float scale = 1.0 / (1.0 - black);
        result = (result - TC_RGB(black, black, black)) * scale;
    } else if (blackPoint > 0.0) {
        float y = clamp(tcLuminance(result), 0.0, 1.0);
        float o = 1.0 - y;
        float o2 = o * o;
        float o7 = o2 * o2 * o2 * o;
        float black = pow(blackPoint, 1.4) * (0.15 * (1.0 - exp(-y / 0.06)) + 0.01 * o7);
        result = result * (1.0 - black) + TC_RGB(black, black, black);
    }
    if (whitePoint < 0.0) {
        float y = max(0.0, tcLuminance(result));
        result *= 1.0 / (1.0 - 0.18 * whitePoint * y);
    } else if (whitePoint > 0.0) {
        float y = max(0.0, tcLuminance(result));
        float scale = y > 0.0 ? 1.0 + 0.18 * pow(whitePoint, 1.4) * tcSmooth(y / 0.8) / y : 1.0;
        result *= scale;
    }
    return result;
}
TC_RGB tcBasicVibranceV3(TC_RGB pixel, float amount) {
    if (amount == 0.0) return pixel;
    float maximum = max(max(pixel.r, pixel.g), pixel.b);
    float minimum = min(min(pixel.r, pixel.g), pixel.b);
    float chroma = maximum - minimum;
    if (chroma <= 0.0 || maximum <= 0.0) return pixel;
    float saturation = clamp(chroma / maximum, 0.0, 1.0);
    float y = tcLuminance(pixel);
    float gain;
    if (amount < 0.0) {
        gain = 1.0 + amount * (0.95 - 0.45 * saturation * saturation);
    } else {
        if (minimum < 0.0 || maximum > 1.0) return pixel;
        float hue;
        if (maximum == pixel.r) hue = 60.0 * ((pixel.g - pixel.b) / chroma);
        else if (maximum == pixel.g) hue = 60.0 * ((pixel.b - pixel.r) / chroma + 2.0);
        else hue = 60.0 * ((pixel.r - pixel.g) / chroma + 4.0);
        if (hue < 0.0) hue += 360.0;
        float distance = min(abs(hue - 35.0), 360.0 - abs(hue - 35.0));
        float skin = (1.0 - tcSmooth(distance / 45.0)) * tcSmooth((y - 0.08) / 0.12) *
            (1.0 - tcSmooth((y - 0.75) / 0.2)) * tcSmooth((chroma - 0.02) / 0.08);
        gain = 1.0 + 2.0 * amount * (1.0 - saturation) * (1.0 - 0.6 * skin);
        for (int channel = 0; channel < 3; ++channel) {
            float difference = pixel[channel] - y;
            if (difference > 0.0) gain = min(gain, (1.0 - y) / difference);
            else if (difference < 0.0) gain = min(gain, -y / difference);
        }
    }
    return TC_RGB(y, y, y) + (pixel - TC_RGB(y, y, y)) * gain;
}
float tcBasicToneV3Gain(float light, float slope, float intercept, float highlights, float shadows) {
    if (!(light > 0.0 && light <= 3.4e38)) return 1.0;
    float sh = clamp(shadows, -1.0, 1.0);
    float hi = clamp(highlights, -1.0, 1.0);
    float logLight = log2(max(light, 1e-7) / 0.1845);
    float base = slope * logLight + intercept;
    float shadowWeight = 1.0 - tcSmooth((base + 6.0) / 7.0);
    float highlightWeight = tcSmooth((base + 1.0) / 6.0);
    return exp2(3.5 * sh * shadowWeight + 3.0 * hi * highlightWeight);
}
#define RAWLAB_HS_FN
#define RAWLAB_HS_RGB TC_RGB
#define RAWLAB_HS_RGB3(r, g, b) TC_RGB((r), (g), (b))
#define RAWLAB_HS_CLAMP(x, low, high) clamp((x), (low), (high))
#define RAWLAB_HS_CLAMP01(x) clamp((x), 0.0f, 1.0f)
#define RAWLAB_HS_POW(x, y) pow((x), (y))
)shader" + RAWLAB_TONE_SHADER_TEXT(RAWLAB_HIGHLIGHTS_SHADOWS_BODY) + R"shader(
#undef RAWLAB_HS_FN
#undef RAWLAB_HS_RGB
#undef RAWLAB_HS_RGB3
#undef RAWLAB_HS_CLAMP
#undef RAWLAB_HS_CLAMP01
#undef RAWLAB_HS_POW
#undef TC_RGB
)shader";
}

#undef RAWLAB_TONE_SHADER_TEXT
#undef RAWLAB_TONE_SHADER_STR
#undef RAWLAB_HIGHLIGHTS_SHADOWS_BODY

} // namespace sony2fuji
