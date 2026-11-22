#pragma once
#include "core/photo_tone_curve.h"
#include <string>

namespace sony2fuji {

struct ToneCurveGpuParameters {
    uint32_t count = 0;
    float ranges[32][4]{};
    float tangents[32][4]{};
};

struct ToneCurveParametricGpuParameters {
    uint32_t active = 0;
    float amps[4]{};
    float splits[4]{0.25f, 0.50f, 0.75f, 0.0f};
};

inline ToneCurveGpuParameters toneCurveGpuParameters(const ToneCurve& curve) {
    ToneCurveGpuParameters result;
    if (!curve.active()) return result;
    result.count = curve.count();
    for (uint32_t i = 0; i < result.count; ++i) {
        const auto& s = curve.segment(i);
        result.ranges[i][0] = static_cast<float>(s.x0); result.ranges[i][1] = static_cast<float>(s.x1);
        result.ranges[i][2] = static_cast<float>(s.y0); result.ranges[i][3] = static_cast<float>(s.y1);
        result.tangents[i][0] = static_cast<float>(s.tangent0); result.tangents[i][1] = static_cast<float>(s.tangent1);
    }
    return result;
}

inline ToneCurveParametricGpuParameters toneCurveParametricGpuParameters(
    const ToneCurveParametricConfig& config
) {
    ToneCurveParametricGpuParameters result;
    if (!config.valid() || !config.active()) return result;
    const ToneCurveParametric parametric(config);
    if (!parametric.active()) return result;
    result.active = 1u;
    const auto& amps = parametric.amplitudes();
    const auto& splits = parametric.splits();
    for (size_t i = 0; i < 4; ++i) result.amps[i] = static_cast<float>(amps[i]);
    for (size_t i = 0; i < 3; ++i) result.splits[i] = static_cast<float>(splits[i]);
    return result;
}

#define RAWLAB_TONE_CURVE_LUMINOSITY_BODY \
TCV_FN float tcLuminosityLinearY(TCV_RGB pL) { \
    return pL.g + 0.2126 * (pL.r - pL.g) + 0.0722 * (pL.b - pL.g); \
} \
TCV_FN TCV_RGB tcLuminosityFinish(TCV_RGB pL, float Y, float uPrime, float Y0) { \
    float Yp = TCV_SRGB_TO_LINEAR(uPrime); \
    if (Yp <= 0.0) return TCV_RGB3(0.0, 0.0, 0.0); \
    if (Yp >= 1.0) return TCV_RGB3(1.0, 1.0, 1.0); \
    if (Y <= 1e-7) return TCV_RGB3(uPrime, uPrime, uPrime); \
    float s = TCV_MAX(0.0, Yp - Y0) / Y; \
    TCV_RGB delta = TCV_RGB3((pL.r - Y) * s, (pL.g - Y) * s, (pL.b - Y) * s); \
    float t = 1.0; \
    if (delta.r > 0.0) t = TCV_MIN(t, (1.0 - Yp) / delta.r); \
    else if (delta.r < 0.0) t = TCV_MIN(t, -Yp / delta.r); \
    if (delta.g > 0.0) t = TCV_MIN(t, (1.0 - Yp) / delta.g); \
    else if (delta.g < 0.0) t = TCV_MIN(t, -Yp / delta.g); \
    if (delta.b > 0.0) t = TCV_MIN(t, (1.0 - Yp) / delta.b); \
    else if (delta.b < 0.0) t = TCV_MIN(t, -Yp / delta.b); \
    TCV_RGB outL = TCV_RGB3( \
        TCV_CLAMP01(Yp + delta.r * t), \
        TCV_CLAMP01(Yp + delta.g * t), \
        TCV_CLAMP01(Yp + delta.b * t)); \
    return TCV_RGB3(TCV_LINEAR_TO_SRGB(outL.r), TCV_LINEAR_TO_SRGB(outL.g), TCV_LINEAR_TO_SRGB(outL.b)); \
}

#define RAWLAB_TC_SHADER_STR(...) #__VA_ARGS__
#define RAWLAB_TC_SHADER_TEXT(body) RAWLAB_TC_SHADER_STR(body)

// 三个 shader 后端共用同一个归一化 Hermite、参数化平滑阶梯与亮度模式色域保护公式。
inline const std::string kToneCurveShader = R"shader(
float pchipSegment(float x, float x0, float x1, float y0, float y1, float m0, float m1) {
    float t = clamp((x - x0) / (x1 - x0), 0.0, 1.0), u = 1.0 - t;
    float y = (1.0 + 2.0 * t) * u * u * y0 + t * u * u * m0
        + t * t * (3.0 - 2.0 * t) * y1 - t * t * u * m1;
    return clamp(y, y0, y1);
}
float tcBump(float x, float left, float center, float right) {
    if (x <= left || x >= right) return 0.0;
    float t = x < center ? (x - left) / (center - left) : (right - x) / (right - center);
    return t * t * (3.0 - 2.0 * t);
}
float tcParametric(float x, float a0, float a1, float a2, float a3, float s0, float s1, float s2) {
    x = clamp(x, 0.0, 1.0);
    float dx = a0 * tcBump(x, 0.0, 0.5 * s0, s1)
             + a1 * tcBump(x, 0.0, 0.5 * (s0 + s1), s2)
             + a2 * tcBump(x, s0, 0.5 * (s1 + s2), 1.0)
             + a3 * tcBump(x, s1, 0.5 * (s2 + 1.0), 1.0);
    return clamp(x + dx, 0.0, 1.0);
}
float tcSrgbToLinear(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}
float tcLinearToSrgb(float v) {
    return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}
)shader";

inline std::string toneCurveShader(const char* vectorType) {
    return kToneCurveShader + std::string("\n#define TCV_FN\n#define TCV_RGB ") + vectorType + R"shader(
#define TCV_RGB3(r, g, b) TCV_RGB((r), (g), (b))
#define TCV_MAX(a, b) max((a), (b))
#define TCV_MIN(a, b) min((a), (b))
#define TCV_CLAMP01(x) clamp((x), 0.0, 1.0)
#define TCV_SRGB_TO_LINEAR(x) tcSrgbToLinear((x))
#define TCV_LINEAR_TO_SRGB(x) tcLinearToSrgb((x))
)shader" + RAWLAB_TC_SHADER_TEXT(RAWLAB_TONE_CURVE_LUMINOSITY_BODY) + R"shader(
#undef TCV_FN
#undef TCV_RGB
#undef TCV_RGB3
#undef TCV_MAX
#undef TCV_MIN
#undef TCV_CLAMP01
#undef TCV_SRGB_TO_LINEAR
#undef TCV_LINEAR_TO_SRGB
)shader";
}

#undef RAWLAB_TC_SHADER_TEXT
#undef RAWLAB_TC_SHADER_STR

} // namespace sony2fuji
