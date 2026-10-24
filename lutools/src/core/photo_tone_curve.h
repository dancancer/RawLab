#pragma once

#include "sony2fuji/ffi/sony2fuji_c.h"
#include <array>

namespace sony2fuji {

bool validToneCurve(const sony2fuji_tone_curve_config& config);

// 归一化区间切线避免把很窄区间展开成溢出的三次多项式系数。
struct ToneCurveSegment {
    double x0 = 0, x1 = 1, y0 = 0, y1 = 1, tangent0 = 1, tangent1 = 1;
};

class ToneCurve {
public:
    ToneCurve() = default;
    explicit ToneCurve(const sony2fuji_tone_curve_config& config);
    bool custom() const { return custom_; }
    bool active() const { return active_; }
    bool gpuSupported() const { return gpuSupported_; }
    uint32_t count() const { return count_; }
    const ToneCurveSegment& segment(uint32_t index) const { return segments_[index]; }
    double evaluate(double value) const;

private:
    std::array<ToneCurveSegment, SONY2FUJI_TONE_CURVE_MAX_POINTS - 1> segments_{};
    uint32_t count_ = 0;
    bool custom_ = false, active_ = false, gpuSupported_ = true;
};

} // namespace sony2fuji
