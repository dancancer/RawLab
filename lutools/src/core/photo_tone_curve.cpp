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

bool validToneCurve(const sony2fuji_tone_curve_config& config) {
    if (config.version != SONY2FUJI_TONE_CURVE_CONFIG_VERSION || config.struct_size != sizeof(config)) return false;
    if (config.mode == SONY2FUJI_CURVE_LEGACY) return config.count == 0;
    if (config.mode != SONY2FUJI_CURVE_CUSTOM || config.count < 2 || config.count > SONY2FUJI_TONE_CURVE_MAX_POINTS) return false;
    for (uint32_t i = 0; i < config.count; ++i) {
        const auto p = config.points[i];
        if (!std::isfinite(p.x) || !std::isfinite(p.y) || p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return false;
        if (i && (p.x <= config.points[i - 1].x || p.y < config.points[i - 1].y)) return false;
    }
    const auto first = config.points[0], last = config.points[config.count - 1];
    return first.x == 0 && first.y == 0 && last.x == 1 && last.y == 1;
}

ToneCurve::ToneCurve(const sony2fuji_tone_curve_config& config) {
    if (!validToneCurve(config)) throw std::invalid_argument("invalid tone curve");
    custom_ = config.mode == SONY2FUJI_CURVE_CUSTOM;
    if (!custom_) return;
    count_ = config.count - 1;
    double h[32]{}, dy[32]{};
    for (uint32_t i = 0; i < count_; ++i) {
        h[i] = config.points[i + 1].x - config.points[i].x;
        dy[i] = config.points[i + 1].y - config.points[i].y;
        active_ |= config.points[i].x != config.points[i].y;
    }
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
    if (value <= 0) return 0;
    if (value >= 1) return 1;
    uint32_t index = 0;
    while (index + 1 < count_ && value > segments_[index].x1) ++index;
    const auto& s = segments_[index];
    const double t = (value - s.x0) / (s.x1 - s.x0), u = 1 - t;
    const double result = (1 + 2 * t) * u * u * s.y0 + t * u * u * s.tangent0
        + t * t * (3 - 2 * t) * s.y1 - t * t * u * s.tangent1;
    return std::clamp(result, s.y0, s.y1);
}

} // namespace sony2fuji
