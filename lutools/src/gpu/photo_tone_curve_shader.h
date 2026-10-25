#pragma once
#include "core/photo_tone_curve.h"
#include <string>

namespace sony2fuji {

struct ToneCurveGpuParameters {
    uint32_t count = 0;
    float ranges[32][4]{};
    float tangents[32][4]{};
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

// 三个 shader 后端使用同一个归一化 Hermite 求值式，斜率只由 CPU 计算。
inline const std::string kToneCurveShader = R"shader(
float pchipSegment(float x, float x0, float x1, float y0, float y1, float m0, float m1) {
    float t = clamp((x - x0) / (x1 - x0), 0.0, 1.0), u = 1.0 - t;
    float y = (1.0 + 2.0 * t) * u * u * y0 + t * u * u * m0
        + t * t * (3.0 - 2.0 * t) * y1 - t * t * u * m1;
    return clamp(y, y0, y1);
}
)shader";

} // namespace sony2fuji
