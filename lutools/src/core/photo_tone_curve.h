#pragma once

#include <array>
#include <cstdint>

namespace sony2fuji {

inline constexpr uint32_t kToneCurveMaxPoints = 33u;

enum class ToneCurveMode : uint32_t {
    Legacy = 0,
    Custom = 1
};

struct ToneCurvePoint {
    double x = 0.0;
    double y = 0.0;
};

struct ToneCurveConfig {
    ToneCurveMode mode = ToneCurveMode::Legacy;
    uint32_t count = 0;
    std::array<ToneCurvePoint, kToneCurveMaxPoints> points{};
};

bool validToneCurve(const ToneCurveConfig& config);

// 归一化区间切线避免把很窄区间展开成溢出的三次多项式系数。
struct ToneCurveSegment {
    double x0 = 0, x1 = 1, y0 = 0, y1 = 1, tangent0 = 1, tangent1 = 1;
};

class ToneCurve {
public:
    ToneCurve() = default;
    explicit ToneCurve(const ToneCurveConfig& config);
    bool custom() const { return custom_; }
    bool active() const { return active_; }
    bool gpuSupported() const { return gpuSupported_; }
    uint32_t count() const { return count_; }
    const ToneCurveSegment& segment(uint32_t index) const { return segments_[index]; }
    double evaluate(double value) const;

private:
    std::array<ToneCurveSegment, kToneCurveMaxPoints - 1> segments_{};
    uint32_t count_ = 0;
    bool custom_ = false, active_ = false, gpuSupported_ = true;
};

} // namespace sony2fuji
