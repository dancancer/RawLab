#include "core/photo_tone_curve.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace sony2fuji {
namespace {

double productRatio(double a, double b, double c) {
    if (a == 0 || b == 0) return 0;
    int ea, eb, ec;
    const double ma = std::frexp(a, &ea), mb = std::frexp(b, &eb), mc = std::frexp(c, &ec);
    return std::ldexp(ma * mb / mc, ea + eb - ec);
}

double innerTangent(double target, double left, double right, double dyLeft, double dyRight) {
    if (dyLeft == 0 || dyRight == 0) return 0;
    const double scale = std::max(left, right), a = left / scale, b = right / scale;
    const double w1 = 2 * b + a, w2 = b + 2 * a;
    int el, er, eyl, eyr, et;
    const double ml = std::frexp(left, &el), mr = std::frexp(right, &er);
    const double myl = std::frexp(dyLeft, &eyl), myr = std::frexp(dyRight, &eyr);
    const double mt = std::frexp(target, &et);
    const int exponent = std::max(el - eyl, er - eyr);
    // 先在共同指数下相加，避免无穷中间量吞掉仍可表示的 subnormal 切线。
    const double denominator = std::ldexp(w1 * ml / myl, el - eyl - exponent)
        + std::ldexp(w2 * mr / myr, er - eyr - exponent);
    return std::ldexp(mt * (w1 + w2) / denominator, et - exponent);
}

double endTangent(double h0, double h1, double dy0, double dy1) {
    if (dy0 == 0) return 0;
    const double fraction = h0 / (h0 + h1);
    const double tangent = (1 + fraction) * dy0 - fraction * productRatio(h0, dy1, h1);
    return std::clamp(tangent, 0.0, 3 * dy0);
}

} // namespace

bool ToneCurveParametricConfig::valid() const noexcept {
    const float bands[] = {highlights, lights, darks, shadows};
    for (float v : bands) {
        if (!std::isfinite(v) || v < -100.0f || v > 100.0f) return false;
    }
    if (!std::isfinite(splitShadow) || !std::isfinite(splitMidtone) || !std::isfinite(splitHighlight)) {
        return false;
    }
    if (splitShadow < 0.05f || splitShadow > 0.45f ||
        splitMidtone < 0.25f || splitMidtone > 0.75f ||
        splitHighlight < 0.55f || splitHighlight > 0.95f) {
        return false;
    }
    return (splitShadow + 0.02f <= splitMidtone + 1e-6f) &&
           (splitMidtone + 0.02f <= splitHighlight + 1e-6f);
}

bool ToneCurveParametricConfig::active() const noexcept {
    return highlights != 0.0f || lights != 0.0f || darks != 0.0f || shadows != 0.0f;
}

bool validToneCurve(const ToneCurveConfig& config, ToneCurveEndpoints endpoints) {
    if (config.mode == ToneCurveMode::Legacy) return config.count == 0;
    if (config.mode != ToneCurveMode::Custom || config.count < 2 || config.count > kToneCurveMaxPoints) return false;
    for (uint32_t i = 0; i < config.count; ++i) {
        const auto p = config.points[i];
        if (!std::isfinite(p.x) || !std::isfinite(p.y) || p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return false;
        if (i && (p.x <= config.points[i - 1].x || p.y < config.points[i - 1].y)) return false;
    }
    const auto first = config.points[0], last = config.points[config.count - 1];
    if (endpoints == ToneCurveEndpoints::Free) return true;
    if (first.x != 0 || last.x != 1) return false;
    return endpoints == ToneCurveEndpoints::FreeY || (first.y == 0 && last.y == 1);
}

ToneCurve::ToneCurve(const ToneCurveConfig& config, ToneCurveEndpoints endpoints) {
    if (!validToneCurve(config, endpoints)) throw std::invalid_argument("invalid tone curve");
    custom_ = config.mode == ToneCurveMode::Custom;
    if (!custom_) return;
    count_ = config.count - 1;
    double h[32]{}, dy[32]{};
    active_ = config.points[0].x != 0.0 || config.points[count_].x != 1.0;
    for (uint32_t i = 0; i < count_; ++i) {
        h[i] = config.points[i + 1].x - config.points[i].x;
        dy[i] = config.points[i + 1].y - config.points[i].y;
        active_ |= config.points[i].x != config.points[i].y;
    }
    active_ |= config.points[count_].x != config.points[count_].y;
    if (!active_) return;
    for (uint32_t i = 0; i < count_; ++i) {
        auto& s = segments_[i];
        s = {config.points[i].x, config.points[i + 1].x, config.points[i].y, config.points[i + 1].y, dy[i], dy[i]};
        if (count_ > 1) {
            s.tangent0 = i == 0 ? endTangent(h[0], h[1], dy[0], dy[1])
                : innerTangent(h[i], h[i - 1], h[i], dy[i - 1], dy[i]);
            s.tangent1 = i + 1 == count_ ? endTangent(h[i], h[i - 1], dy[i], dy[i - 1])
                : innerTangent(h[i], h[i], h[i + 1], dy[i], dy[i + 1]);
        }
        // 三次 Bezier 导数的保守上界；坐标舍入引起的误差受同一上界约束。
        const float gpuWidth = static_cast<float>(s.x1) - static_cast<float>(s.x0);
        if (gpuWidth < std::numeric_limits<float>::min() || 3 * dy[i] / h[i] > 16)
            gpuSupported_ = false;
    }
}

double ToneCurve::evaluate(double value) const {
    if (!active_) return value;
    if (value <= segments_[0].x0) return segments_[0].y0;
    if (value >= segments_[count_ - 1].x1) return segments_[count_ - 1].y1;
    uint32_t index = 0;
    while (index + 1 < count_ && value > segments_[index].x1) ++index;
    const auto& s = segments_[index];
    const double t = (value - s.x0) / (s.x1 - s.x0), u = 1 - t;
    const double result = (1 + 2 * t) * u * u * s.y0 + t * u * u * s.tangent0
        + t * t * (3 - 2 * t) * s.y1 - t * t * u * s.tangent1;
    return std::clamp(result, s.y0, s.y1);
}

namespace {

double smoothstepBump(double x, double left, double center, double right) noexcept {
    if (x <= left || x >= right) return 0.0;
    const double t = x < center
        ? (x - left) / (center - left)
        : (right - x) / (right - center);
    return t * t * (3.0 - 2.0 * t);
}

} // namespace

ToneCurveParametric::ToneCurveParametric(const ToneCurveParametricConfig& config) {
    if (!config.valid()) throw std::invalid_argument("invalid parametric tone curve");
    splits_ = {
        static_cast<double>(config.splitShadow),
        static_cast<double>(config.splitMidtone),
        static_cast<double>(config.splitHighlight)
    };
    if (!config.active()) return;

    active_ = true;
    const double s0 = splits_[0];
    const double s1 = splits_[1];
    const double s2 = splits_[2];
    const double c0 = 0.5 * s0;
    const double c1 = 0.5 * (s0 + s1);
    const double c2 = 0.5 * (s1 + s2);
    const double c3 = 0.5 * (s2 + 1.0);

    const std::array<double, 4> lefts{0.0, 0.0, s0, s1};
    const std::array<double, 4> centers{c0, c1, c2, c3};
    const std::array<double, 4> rights{s1, s2, 1.0, 1.0};
    constexpr std::array<double, 4> kNominal{0.12, 0.15, 0.15, 0.12};
    const std::array<double, 4> desired{
        (static_cast<double>(config.shadows) / 100.0) * kNominal[0],
        (static_cast<double>(config.darks) / 100.0) * kNominal[1],
        (static_cast<double>(config.lights) / 100.0) * kNominal[2],
        (static_cast<double>(config.highlights) / 100.0) * kNominal[3]
    };

    const std::array<double, 9> knots{0.0, c0, s0, c1, s1, c2, s2, c3, 1.0};
    double minDeriv = 0.0;
    for (size_t m = 0; m < 8; ++m) {
        const double x0 = knots[m];
        const double x1 = knots[m + 1];
        const double mid = 0.5 * (x0 + x1);
        double A = 0.0, B = 0.0, C = 0.0;
        for (size_t i = 0; i < 4; ++i) {
            if (desired[i] == 0.0) continue;
            if (lefts[i] < mid && mid < centers[i]) {
                const double w = centers[i] - lefts[i];
                const double k = desired[i] * 6.0 / (w * w * w);
                A += -k;
                B += k * (lefts[i] + centers[i]);
                C += -k * (lefts[i] * centers[i]);
            } else if (centers[i] < mid && mid < rights[i]) {
                const double w = rights[i] - centers[i];
                const double k = -desired[i] * 6.0 / (w * w * w);
                A += -k;
                B += k * (centers[i] + rights[i]);
                C += -k * (centers[i] * rights[i]);
            }
        }
        auto evalQ = [&](double x) { return (A * x + B) * x + C; };
        minDeriv = std::min(minDeriv, evalQ(x0));
        minDeriv = std::min(minDeriv, evalQ(x1));
        if (A > 0.0) {
            const double xv = -B / (2.0 * A);
            if (xv > x0 && xv < x1) {
                minDeriv = std::min(minDeriv, evalQ(xv));
            }
        }
    }

    const double scale = minDeriv < -0.95 ? 0.95 / (-minDeriv) : 1.0;
    for (size_t i = 0; i < 4; ++i) {
        amps_[i] = desired[i] * scale;
    }
}

double ToneCurveParametric::evaluate(double value) const noexcept {
    if (!active_) return value;
    const double x = std::clamp(value, 0.0, 1.0);
    const double s0 = splits_[0];
    const double s1 = splits_[1];
    const double s2 = splits_[2];
    const double dx =
        amps_[0] * smoothstepBump(x, 0.0, 0.5 * s0, s1) +
        amps_[1] * smoothstepBump(x, 0.0, 0.5 * (s0 + s1), s2) +
        amps_[2] * smoothstepBump(x, s0, 0.5 * (s1 + s2), 1.0) +
        amps_[3] * smoothstepBump(x, s1, 0.5 * (s2 + 1.0), 1.0);
    return std::clamp(x + dx, 0.0, 1.0);
}

} // namespace sony2fuji
