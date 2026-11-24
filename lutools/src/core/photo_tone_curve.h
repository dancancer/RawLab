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

struct ToneCurveParametricConfig {
    float highlights = 0.0f;
    float lights = 0.0f;
    float darks = 0.0f;
    float shadows = 0.0f;
    float splitShadow = 0.25f;
    float splitMidtone = 0.50f;
    float splitHighlight = 0.75f;

    bool valid() const noexcept;
    bool active() const noexcept;
};

// 端点放开的程度随持久化版本递进：v1 固定 (0,0)/(1,1)；SDR v17 / HDR v9 只放开端点 y；
// SDR v18 / HDR v10 起端点 x 也可内移，超出 [x0, x_{n-1}] 的输入平直截断。
enum class ToneCurveEndpoints : uint8_t {
    Pinned = 0,
    FreeY = 1,
    Free = 2
};

bool validToneCurve(const ToneCurveConfig& config, ToneCurveEndpoints endpoints = ToneCurveEndpoints::Pinned);

// 归一化区间切线避免把很窄区间展开成溢出的三次多项式系数。
struct ToneCurveSegment {
    double x0 = 0, x1 = 1, y0 = 0, y1 = 1, tangent0 = 1, tangent1 = 1;
};

class ToneCurve {
public:
    ToneCurve() = default;
    explicit ToneCurve(const ToneCurveConfig& config, ToneCurveEndpoints endpoints = ToneCurveEndpoints::Pinned);
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

class ToneCurveParametric {
public:
    ToneCurveParametric() = default;
    explicit ToneCurveParametric(const ToneCurveParametricConfig& config);
    bool active() const noexcept { return active_; }
    const std::array<double, 4>& amplitudes() const noexcept { return amps_; }
    const std::array<double, 3>& splits() const noexcept { return splits_; }
    double evaluate(double value) const noexcept;

private:
    std::array<double, 4> amps_{}; // shadows, darks, lights, highlights
    std::array<double, 3> splits_{0.25, 0.50, 0.75};
    bool active_ = false;
};

} // namespace sony2fuji
