#include "noise_profile.h"
#include "sony2fuji/raw_processor.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <numeric>
#include <vector>

namespace sony2fuji::ai {
namespace {
struct Sample { double mean, variance; int phase; };
float quantile(std::vector<float> values, float q) {
    if (values.empty()) throw NoiseEstimateUnavailable("No reliable RAW noise samples");
    const size_t index = std::min(values.size() - 1, static_cast<size_t>(q * (values.size() - 1)));
    std::nth_element(values.begin(), values.begin() + index, values.end());
    return values[index];
}
float sigma(const std::vector<float>& values) {
    const float center = quantile(values, .5f);
    std::vector<float> deviations; deviations.reserve(values.size());
    for (float value : values) deviations.push_back(std::abs(value - center));
    return quantile(std::move(deviations), .5f) / .67448975f;
}

std::vector<Sample> sampleNoise(const RAWBayerSource& source) {
    std::vector<Sample> result;
    const int columns = std::min(32, source.width / 64), rows = std::min(24, source.height / 64);
    for (int gy = 0; gy < rows; ++gy) for (int gx = 0; gx < columns; ++gx) {
        const int left = columns == 1 ? 0 : ((source.width - 64) * gx / (columns - 1)) & ~1;
        const int top = rows == 1 ? 0 : ((source.height - 64) * gy / (rows - 1)) & ~1;
        for (int py = 0; py < 2; ++py) for (int px = 0; px < 2; ++px) {
            const int phase = source.pattern[py * 2 + px];
            const float black = source.black[phase], range = source.white - black;
            std::array<float, 256> means{};
            std::vector<float> detail; detail.reserve(256);
            int clipped = 0;
            for (int y = 0; y < 16; ++y) for (int x = 0; x < 16; ++x) {
                float v[4];
                for (int dy = 0; dy < 2; ++dy) for (int dx = 0; dx < 2; ++dx) {
                    const auto dn = source.pixels[size_t(top + py + y * 4 + dy * 2) * source.width + left + px + x * 4 + dx * 2];
                    // 黑位以下的读出噪声保留；只剔除 ADC 下限和接近白位的截断区域。
                    clipped += dn == 0 || dn >= source.white - range * .01f;
                    v[dy * 2 + dx] = (dn - black) / range;
                }
                means[y * 16 + x] = (v[0] + v[1] + v[2] + v[3]) * .25f;
                // 系数平方和为 1，方差仍是原始同相位像素方差。
                detail.push_back((v[0] - v[1] - v[2] + v[3]) * .5f);
            }
            if (clipped > 10) continue;
            const float spread = sigma(detail);
            const float quantization = 1.f / (range * std::sqrt(12.f));
            if (spread < quantization * .5f || std::abs(quantile(detail, .5f)) > spread) continue;
            std::vector<float> coarse; coarse.reserve(64);
            for (int y = 0; y < 16; y += 2) for (int x = 0; x < 16; x += 2)
                coarse.push_back((means[y * 16 + x] - means[y * 16 + x + 1] -
                    means[(y + 1) * 16 + x] + means[(y + 1) * 16 + x + 1]) * .5f);
            if (sigma(coarse) > spread * .9f) continue;
            double correlation = 0, energy = 0;
            const float center = quantile(detail, .5f);
            for (size_t i = 1; i < detail.size(); ++i) {
                correlation += (detail[i] - center) * (detail[i - 1] - center);
                energy += (detail[i] - center) * (detail[i] - center);
            }
            if (energy > 0 && std::abs(correlation / energy) > .3) continue;
            result.push_back({std::accumulate(means.begin(), means.end(), 0.) / means.size(),
                              double(spread) * spread, phase});
        }
    }
    return result;
}

std::pair<double, double> fit(const std::vector<Sample>& samples) {
    std::array<int, 4> counts{};
    for (const auto& sample : samples) ++counts[sample.phase];
    double k = 0, b = 0;
    for (const auto& sample : samples) b += sample.variance / samples.size();
    for (int pass = 0; pass < 8; ++pass) {
        double sum = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
        for (const auto& sample : samples) {
            const double predicted = std::max(1e-12, k * sample.mean + b);
            const double relative = (sample.variance - predicted) / predicted;
            const double weight = 1. / (counts[sample.phase] * predicted * predicted *
                std::sqrt(1 + relative * relative / .09));
            sum += weight; sx += weight * sample.mean; sy += weight * sample.variance;
            sxx += weight * sample.mean * sample.mean; sxy += weight * sample.mean * sample.variance;
        }
        const double determinant = sum * sxx - sx * sx;
        k = determinant > 1e-16 ? std::max(0., (sum * sxy - sx * sy) / determinant) : 0.;
        b = std::max(0., (sy - k * sx) / sum);
        if (b == 0 && sxx > 0) k = std::max(0., sxy / sxx);
    }
    return {k, b};
}
}

NoiseParameters estimateRawNoise(const RAWBayerSource& source) {
    auto pattern = source.pattern; std::sort(pattern.begin(), pattern.end());
    if (source.width < 2 || source.height < 2 || uint64_t(source.width) * source.height > 128000000 ||
        source.pixels.size() != size_t(source.width) * source.height || pattern != std::array<int,4>{0,1,2,3} ||
        !std::isfinite(source.white) || source.white > 65535 ||
        !std::all_of(source.black.begin(), source.black.end(), [&](float black) {
            return std::isfinite(black) && black >= 0 && source.white > black;
        })) throw std::invalid_argument("Invalid Bayer noise-estimation input");
    auto samples = sampleNoise(source);
    std::array<int, 4> counts{};
    std::vector<float> means;
    for (const auto& sample : samples) { ++counts[sample.phase]; means.push_back(float(sample.mean)); }
    if (*std::min_element(counts.begin(), counts.end()) < 8)
        throw NoiseEstimateUnavailable("Insufficient independent RAW noise samples");
    NoiseParameters result;
    result.samples = static_cast<int>(samples.size());
    result.signalSpan = quantile(means, .9f) - quantile(means, .1f);
    if (result.signalSpan < .02f) {
        std::vector<float> variances;
        for (const auto& sample : samples) variances.push_back(float(sample.variance));
        result.k = 1e-10f; result.b = quantile(variances, .5f);
        result.calibrationID = "estimated-constant-variance-v1";
    } else {
        const auto [k, b] = fit(samples);
        result.k = static_cast<float>(std::max(k, 1e-10)); result.b = static_cast<float>(b);
        result.calibrationID = "estimated-haar-mad-v1";
    }
    std::array<std::vector<float>, 4> phaseRatios;
    std::vector<float> errors;
    for (const auto& sample : samples) {
        const double predicted = std::max(1e-12, result.k * sample.mean + result.b);
        phaseRatios[sample.phase].push_back(float(sample.variance / predicted));
        errors.push_back(float(std::abs(sample.variance / predicted - 1)));
    }
    result.relativeError = quantile(errors, .5f);
    if (!std::isfinite(result.k + result.b) || result.relativeError > .35f)
        throw NoiseEstimateUnavailable("RAW noise does not fit an affine variance model");
    for (const auto& ratios : phaseRatios) {
        const float ratio = quantile(ratios, .5f);
        if (ratio < .5f || ratio > 2.f) throw NoiseEstimateUnavailable("RAW phases require different noise models");
    }
    return result;
}
}
