#include "core/hdr_detail.h"
#include "core/parallel_pixels.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace sony2fuji {
namespace {

double luminance(const RGB& p) { return .2126 * p.r + .7152 * p.g + .0722 * p.b; }

double darkVeil(int width, int height, const GeometryPixelReader& read) {
    const int step = std::max(1, (std::max(width, height) + 127) / 128);
    std::vector<double> samples;
    for (int y = 0; y < height; y += step) {
        checkProcessingCancellation();
        for (int x = 0; x < width; x += step) {
            const double value = luminance(read(x, y));
            if (!std::isfinite(value)) throw std::overflow_error("HDR detail analysis requires finite luminance");
            samples.push_back(std::clamp(value, 0., .3));
        }
    }
    const auto percentile = samples.begin() + (samples.size() - 1) / 10;
    std::nth_element(samples.begin(), percentile, samples.end());
    return *percentile;
}

} // namespace

bool HDRDetailOptions::valid() const {
    return sharpening >= 0 && sharpening <= 2 && clarity >= -1 && clarity <= 1 &&
        dehaze >= -1 && dehaze <= 1 && denoise >= 0 && denoise <= 1;
}

int HDRDetailOptions::halo(int width, int height) const {
    if (clarity != 0) return std::max((std::max(width, height) + 100) / 200, 2);
    return sharpening != 0 || denoise != 0 ? 1 : 0;
}

HDRDetailPlan planHDRDetail(int width, int height, const HDRDetailOptions& settings,
    double peak, const GeometryPixelReader& read) {
    return {settings, width, height, settings.halo(width, height),
        settings.dehaze == 0 ? 0 : darkVeil(width, height, read), peak};
}

void renderHDRDetailBand(const HDRDetailPlan& plan, const RGB* input, int inputTop, int inputRows,
    RGB* output, int outputTop, int outputRows) {
    const auto& settings = plan.settings;
    const int width = plan.width;
    std::vector<float> stops;
    if (plan.halo > 0) {
        stops.resize(size_t(width) * inputRows);
        parallelPixelRanges(stops.size(), [&](size_t begin, size_t end) {
            for (size_t i = begin; i < end; ++i)
                stops[i] = float(std::log2(std::max(luminance(input[i]), 1.0 / 65536)));
        });
    }
    const auto index = [&](int x, int y) {
        return size_t(std::clamp(y, 0, plan.height - 1) - inputTop) * width + std::clamp(x, 0, width - 1);
    };
    constexpr int weights[] = {1, 2, 1};
    const auto localDetail = [&](int x, int y, int radius, float center) {
        float sum = 0;
        for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx)
            sum += stops[index(x + dx * radius, y + dy * radius)] * weights[dx + 1] * weights[dy + 1];
        return center - sum / 16;
    };
    std::atomic<bool> overflow{false};
    parallelPixelRanges(size_t(width) * outputRows, [&](size_t begin, size_t end) {
        for (size_t i = begin; i < end; ++i) {
            const int x = int(i % width), y = outputTop + int(i / width);
            const size_t centerIndex = index(x, y);
            RGB pixel = input[centerIndex];
            if (luminance(pixel) > 0) {
                if (settings.denoise > 0) {
                    const float center = stops[centerIndex];
                    double red = 0, green = 0, blue = 0, total = 0;
                    for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
                        const size_t sample = index(x + dx, y + dy);
                        const double difference = stops[sample] - center;
                        const double weight = weights[dx + 1] * weights[dy + 1] / (1 + 24 * difference * difference);
                        const auto& p = input[sample];
                        red += p.r * weight; green += p.g * weight; blue += p.b * weight; total += weight;
                    }
                    const double mix = .65 * settings.denoise;
                    pixel = {float(pixel.r + (red / total - pixel.r) * mix),
                        float(pixel.g + (green / total - pixel.g) * mix),
                        float(pixel.b + (blue / total - pixel.b) * mix)};
                }
                float shift = 0;
                if (settings.sharpening > 0) {
                    const float detail = localDetail(x, y, 1, stops[centerIndex]);
                    const float weight = std::clamp((std::abs(detail) - .012f) / .06f, 0.f, 1.f);
                    shift += std::clamp(detail * weight * settings.sharpening * .5f, -.45f, .45f);
                }
                if (settings.clarity != 0) {
                    const float detail = localDetail(x, y, plan.halo, stops[centerIndex]);
                    shift += std::clamp(detail * settings.clarity * .7f, -.8f, .8f);
                }
                const double luma = luminance(pixel);
                if (luma > 0 && (shift != 0 || settings.dehaze != 0 || plan.peak > 0)) {
                    double target = luma * std::exp2(double(shift));
                    if (settings.dehaze != 0) {
                        const double position = target / .7;
                        const double veil = settings.dehaze < 0 ? std::max(plan.veil, .03) : plan.veil;
                        const double change = .45 * settings.dehaze * veil / (1 + position * position);
                        target = std::max(target / 4, target - change);
                    }
                    if (plan.peak > 0) target = std::min(target, plan.peak);
                    const double gain = target / luma;
                    pixel = {float(pixel.r * gain), float(pixel.g * gain), float(pixel.b * gain)};
                }
            }
            if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b))
                overflow.store(true, std::memory_order_relaxed);
            output[i] = pixel;
        }
    });
    if (overflow.load(std::memory_order_relaxed)) throw std::overflow_error("HDR detail exceeded finite float range");
}

} // namespace sony2fuji
