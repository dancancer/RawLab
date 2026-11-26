#include "photo_defringe.h"
#include "parallel_pixels.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace sony2fuji {
namespace {

inline float smoothstep01(float x) {
    x = std::clamp(x, 0.0f, 1.0f);
    return x * x * (3.0f - 2.0f * x);
}

inline float srgbEncode01(float x) {
    x = std::clamp(x, 0.0f, 1.0f);
    return x <= 0.0031308f ? 12.92f * x : 1.055f * std::pow(x, 1.0f / 2.4f) - 0.055f;
}

inline float luminanceLinear(const RGB& p) {
    return 0.2126f * p.r + 0.7152f * p.g + 0.0722f * p.b;
}

inline float hueDistanceDeg(float a, float b) {
    const float d = std::abs(a - b);
    return std::min(d, 360.0f - d);
}

} // namespace

bool DefringeOptions::valid() const {
    for (float v : {purpleAmount, greenAmount}) {
        if (!std::isfinite(v) || v < 0.0f || v > 20.0f) return false;
    }
    for (float v : {purpleHue, greenHue}) {
        if (!std::isfinite(v) || v < 0.0f || v > 100.0f) return false;
    }
    return true;
}

void applyDefringe(ImageData& image, const DefringeOptions& options) {
    // Exact zero-value bypass when both purple and green amounts are 0.
    if (!options.valid() || !options.active()) return;
    const int w = image.width;
    const int h = image.height;
    if (w <= 0 || h <= 0) return;
    const size_t count = static_cast<size_t>(w) * static_cast<size_t>(h);
    if (image.pixels.size() != count) return;

    std::vector<float> pLuma(count, 0.0f);
    parallelPixelRanges(count, [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            const auto& p = image.pixels[i];
            if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b)) continue;
            pLuma[i] = std::sqrt(std::clamp(luminanceLinear(p), 0.0f, 4.0f));
        }
    });

    // Separable 7x7 local min/max perceptual luminance detects high-contrast edges cleanly.
    constexpr int kRadius = 3;
    std::vector<float> minH(count, 0.0f), maxH(count, 0.0f);
    parallelRowRanges(h, w, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const size_t row = static_cast<size_t>(y) * static_cast<size_t>(w);
            for (int x = 0; x < w; ++x) {
                float lo = pLuma[row + static_cast<size_t>(x)];
                float hi = lo;
                for (int k = -kRadius; k <= kRadius; ++k) {
                    const float v = pLuma[row + static_cast<size_t>(std::clamp(x + k, 0, w - 1))];
                    lo = std::min(lo, v);
                    hi = std::max(hi, v);
                }
                minH[row + static_cast<size_t>(x)] = lo;
                maxH[row + static_cast<size_t>(x)] = hi;
            }
        }
    });

    const float purpleNorm = std::clamp(options.purpleAmount / 20.0f, 0.0f, 1.0f);
    const float greenNorm = std::clamp(options.greenAmount / 20.0f, 0.0f, 1.0f);
    const float purpleCenter = 270.0f + (std::clamp(options.purpleHue, 0.0f, 100.0f) / 100.0f) * 40.0f;
    const float greenCenter = 95.0f + (std::clamp(options.greenHue, 0.0f, 100.0f) / 100.0f) * 50.0f;
    constexpr float kHueHalfWidth = 45.0f;

    parallelRowRanges(h, w, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const size_t row = static_cast<size_t>(y) * static_cast<size_t>(w);
            for (int x = 0; x < w; ++x) {
                const size_t idx = row + static_cast<size_t>(x);
                auto& p = image.pixels[idx];
                if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b)) continue;

                float pMin = minH[idx], pMax = maxH[idx];
                for (int ky = -kRadius; ky <= kRadius; ++ky) {
                    const size_t sy = static_cast<size_t>(std::clamp(y + ky, 0, h - 1)) * static_cast<size_t>(w) +
                                      static_cast<size_t>(x);
                    pMin = std::min(pMin, minH[sy]);
                    pMax = std::max(pMax, maxH[sy]);
                }
                const float contrast = pMax - pMin;
                const float edgeWeight = smoothstep01((contrast - 0.08f) / 0.18f);
                if (edgeWeight <= 0.0f) continue;

                const float sr = srgbEncode01(p.r);
                const float sg = srgbEncode01(p.g);
                const float sb = srgbEncode01(p.b);
                const float hi = std::max({sr, sg, sb});
                const float lo = std::min({sr, sg, sb});
                const float delta = hi - lo;
                if (delta <= 1e-4f || hi <= 1e-4f) continue;

                float hue = (hi == sr) ? 60.0f * (sg - sb) / delta
                          : (hi == sg) ? 60.0f * ((sb - sr) / delta + 2.0f)
                                       : 60.0f * ((sr - sg) / delta + 4.0f);
                if (hue < 0.0f) hue += 360.0f;

                const float sat = delta / hi;
                const float satWeight = smoothstep01((sat - 0.05f) / 0.15f);
                if (satWeight <= 0.0f) continue;

                const float wPurple = purpleNorm > 0.0f
                    ? purpleNorm * (1.0f - smoothstep01(hueDistanceDeg(hue, purpleCenter) / kHueHalfWidth))
                    : 0.0f;
                const float wGreen = greenNorm > 0.0f
                    ? greenNorm * (1.0f - smoothstep01(hueDistanceDeg(hue, greenCenter) / kHueHalfWidth))
                    : 0.0f;
                const float suppress = std::clamp(edgeWeight * satWeight * std::max(wPurple, wGreen), 0.0f, 1.0f);
                if (suppress <= 0.0f) continue;

                const float yLum = luminanceLinear(p);
                p.r += (yLum - p.r) * suppress;
                p.g += (yLum - p.g) * suppress;
                p.b += (yLum - p.b) * suppress;
            }
        }
    });
}

} // namespace sony2fuji
