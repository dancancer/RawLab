// 直接验证内部估计器，不为测试向公共渲染接口增加入口。
#include "../src/core/wavelet_denoise.cpp"
#include "denoise_residual_metrics.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <random>

namespace {
void near(double actual, double expected, double tolerance = 1e-6) {
    if (!std::isfinite(actual) || std::abs(actual - expected) > tolerance)
        std::cerr << "actual=" << actual << " expected=" << expected << " tolerance=" << tolerance << '\n';
    assert(std::isfinite(actual) && std::abs(actual - expected) <= tolerance);
}

void residualAccounting() {
    std::vector<Sample> samples(10, {0, 0, {1, 1, 1}, {1, 1, 1}});
    samples.back().variance = {11, 11, 11};
    NoiseModel model{};
    model.b = {1, 1, 1};
    sony2fuji::WaveletNoiseEstimateDiagnostics info;
    describeFit(samples, model, info);
    for (int c = 0; c < 3; ++c) {
        near(info.sampleVarianceMedian[c], 1);
        near(info.fitRmse[c], std::sqrt(10.));
        near(info.relativeFitRmse[c], std::sqrt(10.));
        near(info.relativeFitMedianAbsResidual[c], 0);
        near(info.fitTopDecileErrorFraction[c], 1);
    }
    samples.back().variance = {1, 1, 1};
    describeFit(samples, model, info);
    for (int c = 0; c < 3; ++c) {
        near(info.fitRmse[c], 0);
        near(info.fitTopDecileErrorFraction[c], 0);
    }
    samples.push_back(samples.back());
    samples[0].variance = {4, 4, 4};
    samples[1].variance = {5, 5, 5};
    describeFit(samples, model, info);
    for (int c = 0; c < 3; ++c) {
        near(info.fitRmse[c], std::sqrt(25. / 11.));
        near(info.fitTopDecileErrorFraction[c], 1);
    }
    samples = {{0, 0, {-1, -1, -1}, {1, 1, 1}},
               {0, 0, {0, 0, 0}, {1, 1, 1}},
               {0, 0, {1, 1, 1}, {3, 3, 3}}};
    model.a = {2, 2, 2};
    describeFit(samples, model, info);
    for (int c = 0; c < 3; ++c) near(info.fitRmse[c], 0);
    samples = {{0, 0, {}, {2, 2, 2}}, {0, 0, {}, {4, 4, 4}}};
    model.a = {0, 0, 0};
    describeFit(samples, model, info);
    for (int c = 0; c < 3; ++c) {
        near(info.sampleVarianceMedian[c], 3);
        near(info.relativeFitMedianAbsResidual[c], 2. / 3.);
        near(info.fitTopDecileErrorFraction[c], .9);
    }
    samples = {{0, 0, {}, {1e-14f, 1e-14f, 1e-14f}}};
    model.b = {1e-12f, 1e-12f, 1e-12f};
    describeFit(samples, model, info);
    for (int c = 0; c < 3; ++c) {
        near(info.sampleVarianceMedian[c], 1e-14, 1e-20);
        near(info.fitRmse[c], 9.9e-13, 1e-20);
        near(info.relativeFitRmse[c], .99);
        near(info.relativeFitMedianAbsResidual[c], .99);
    }
}

void robustFitWithContamination() {
    std::vector<Sample> samples;
    for (int i = 0; i < 40; ++i) {
        const float mean = .01f + .02f * i;
        const float variance = .002f * mean + .0001f;
        samples.push_back({i, 0, {mean, mean, mean}, {variance, variance, variance}});
    }
    const auto clean = fitNoise(samples);
    for (int c = 0; c < 3; ++c) {
        near(clean.a[c], .002, 1e-7);
        near(clean.b[c], .0001, 1e-7);
    }
    // 少数高方差图案不应把稳健拟合拉成普通最小二乘的结果。
    for (int i = 0; i < 4; ++i)
        samples.push_back({i, 1, {.2f, .2f, .2f}, {.2f, .2f, .2f}});
    const auto contaminated = fitNoise(samples);
    for (int c = 0; c < 3; ++c) {
        near(contaminated.a[c] * .2 + contaminated.b[c], .0005, .000125);
        near(contaminated.a[c] * .6 + contaminated.b[c], .0013, .000325);
    }
}

cv::Mat broadbandPatternFixture(bool pattern) {
    cv::Mat rgb(512, 512, CV_32FC3);
    std::mt19937 random(7129);
    std::normal_distribution<float> normal(0, .0005f);
    for (int y = 0; y < rgb.rows; ++y) for (int x = 0; x < rgb.cols; ++x) {
        const float base = .06f + .08f * (x / 64);
        cv::Vec3f value(base + normal(random), base + normal(random), base + normal(random));
        if (pattern && x / 64 == 4 && y / 64 == 4) {
            const float px = x % 64, py = y % 64;
            const float texture = std::sin(.3f * px + .03f * px * py) * std::cos(.5f * py + .01f * px * px);
            value += cv::Vec3f(.06f, .05f, .04f) * texture;
        }
        rgb.at<cv::Vec3f>(y, x) = value;
    }
    return rgb;
}

void patternCannotSetItsOwnNoiseAllowance() {
    sony2fuji::WaveletNoiseEstimateDiagnostics cleanInfo, patternInfo;
    const auto clean = flatSamples(broadbandPatternFixture(false), cleanInfo);
    assert(clean.size() == 64);
    const auto contaminated = flatSamples(broadbandPatternFixture(true), patternInfo);
    // 宽带图案没有单一频峰；不能靠它自身抬高的 MAD 放宽结构门。
    assert(contaminated.size() == 63);
    for (const auto& sample : contaminated) assert(sample.x != 256 || sample.y != 256);
    assert(patternInfo.rejectedStructure == 1);
    assert(patternInfo.candidateTiles == contaminated.size() + patternInfo.rejectedStructure);

    const auto strip = broadbandPatternFixture(true).rowRange(256, 320).clone();
    sony2fuji::ImageData image(512, 64);
    std::memcpy(image.pixels.data(), strip.ptr<float>(), image.pixels.size() * sizeof(sony2fuji::RGB));
    const auto original = image;
    sony2fuji::WaveletDenoiseDiagnostics info;
    sony2fuji::WaveletDenoiseAnalysisCache cache;
    for (int run = 0; run < 2; ++run) {
        assert(sony2fuji::applyWaveletDenoise(image, {true, 10, 72, 0}, &info,
            sony2fuji::GpuMode::Off, &cache, "seven-after-structure") == sony2fuji::ErrorCode::Success);
        assert(info.flatTiles == 7 && info.estimate.rejectedStructure == 1);
        assert(info.outcome == sony2fuji::WaveletDenoiseOutcome::InsufficientSamples);
        assert(!info.applied && !info.estimate.fitAvailable && info.analysisReused == (run == 1));
        assert(std::memcmp(image.pixels.data(), original.pixels.data(), image.pixels.size() * sizeof(sony2fuji::RGB)) == 0);
    }
}

void constrainedFloorCannotRejectNegativeNoise() {
    cv::Mat rgb(512, 512, CV_32FC3);
    std::mt19937 random(2094);
    std::normal_distribution<float> normal(0, 1);
    for (int y = 0; y < rgb.rows; ++y) for (int x = 0; x < rgb.cols; ++x) {
        const bool negative = x < 64 && y < 64;
        const float mean = negative ? -.01f : .1f + .1f * (x / 64);
        const float sigma = negative ? .005f : std::sqrt(.004f * (mean - .04f));
        rgb.at<cv::Vec3f>(y, x) = {mean + sigma * normal(random), mean + sigma * normal(random), mean + sigma * normal(random)};
    }
    sony2fuji::WaveletNoiseEstimateDiagnostics info;
    const auto samples = flatSamples(rgb, info);
    assert(samples.size() == 64 && info.rejectedStructure == 0);
    const auto model = fitNoise(samples);
    assert(model.b[0] <= 1e-12f || model.b[1] <= 1e-12f || model.b[2] <= 1e-12f);
}

void samplingKeepsNoiseControls() {
    for (int mode = 0; mode < 4; ++mode) {
        cv::Mat rgb(512, 512, CV_32FC3);
        std::mt19937 random(8201 + mode);
        std::normal_distribution<float> normal(0, 1);
        for (int y = 0; y < rgb.rows; ++y) for (int x = 0; x < rgb.cols; ++x) {
            const float mean = mode == 2 ? .18f : mode == 3 ? 0 : .01f + .1f * (x / 64);
            const float sigma = std::sqrt(.0001f + .004f * mean);
            const float r = normal(random), g = normal(random), b = normal(random);
            cv::Vec3f value = mode == 1 ? cv::Vec3f(r, r + .1f * g, r + .1f * b) : cv::Vec3f(r, g, b);
            value = cv::Vec3f(mean, mean, mean) + sigma * value;
            if (mode == 3) for (int c = 0; c < 3; ++c) value[c] = std::max(0.f, value[c]);
            rgb.at<cv::Vec3f>(y, x) = value;
        }
        if (mode == 2) cv::GaussianBlur(rgb, rgb, {}, 1.25);
        sony2fuji::WaveletNoiseEstimateDiagnostics info;
        const auto samples = flatSamples(rgb, info);
        assert(samples.size() == 64);
    }
    for (int count : {7, 8}) {
        cv::Mat rgb(64, 64 * count, CV_32FC3);
        cv::RNG random(9637);
        random.fill(rgb, cv::RNG::NORMAL, .02, .003);
        sony2fuji::WaveletNoiseEstimateDiagnostics info;
        const auto samples = flatSamples(rgb, info);
        assert(samples.size() == static_cast<size_t>(count));
        assert(info.rejectedStructure == 0);
    }
}

cv::Mat filterWithConstantModel(const cv::Mat& source, float variance) {
    NoiseModel model{};
    model.b = {variance, variance, variance};
    sony2fuji::WaveletNoiseEstimateDiagnostics info;
    const auto samples = flatSamples(source, info);
    assert(samples.size() >= 8);
    cv::Mat transformed;
    cv::transform(normalize(source, model), transformed, opponent());
    calibrateBands(model, transformed, samples);
    calibrateCoarseBands(model, transformed, samples);
    std::atomic<bool> gpuUsed{false};
    const sony2fuji::WaveletDenoiseOptions options{true, 10, 72, 100};
    auto filtered = filter(transformed, model, options, sony2fuji::GpuMode::Off, gpuUsed);
    auto output = source.clone();
    restore(output, std::move(filtered), model);
    return output;
}

void constantModelScaleCancelsThroughCalibration() {
    cv::Mat source(192, 192, CV_32FC3);
    cv::RNG random(5391);
    random.fill(source, cv::RNG::NORMAL, 0, .014);
    cv::max(source, 0, source);
    const auto original = filterWithConstantModel(source, .0001f);
    const auto rescaled = filterWithConstantModel(source, .0016f);
    // b 的共同倍率会在归一化、band 校准和恢复之间抵消，不是降噪强度旋钮。
    assert(cv::norm(original, rescaled, cv::NORM_INF) < 2e-6);
}

void nearBlackNoiseAndTexture() {
    for (int mode = 0; mode < 4; ++mode) {
        sony2fuji::ImageData source(256, 256);
        std::mt19937 random(5401 + mode);
        std::normal_distribution<float> normal(0, .014f);
        std::bernoulli_distribution tail(.02);
        const double mean = mode == 0 ? 0 : .014 / std::sqrt(2 * CV_PI) * (mode == 2 ? 1.14 : 1);
        double inputError = 0, inputChroma = 0;
        cv::Vec3d inputMean{};
        for (int y = 0; y < 256; ++y) for (int x = 0; x < 256; ++x) {
            const float texture = mode == 3 && x >= 64 && x < 192 && y >= 64 && y < 192 ?
                .012f * std::sin(1.1f * x) * std::cos(.7f * y) : 0;
            cv::Vec3f value;
            for (int c = 0; c < 3; ++c) {
                float noise = normal(random) * (mode == 2 && tail(random) ? 8 : 1);
                if (mode != 0) noise = std::max(0.f, noise);
                value[c] = noise + texture;
                inputError += (value[c] - mean - texture) * (value[c] - mean - texture);
                inputMean[c] += value[c] / double(source.pixels.size());
            }
            inputChroma += (value[0] - value[1]) * (value[0] - value[1]) +
                (value[2] - value[1]) * (value[2] - value[1]);
            source.at(x, y) = {value[0], value[1], value[2]};
        }
        auto output = source;
        sony2fuji::WaveletDenoiseDiagnostics info;
        assert(sony2fuji::applyWaveletDenoise(output, {true, 10, 72, 100}, &info) == sony2fuji::ErrorCode::Success);
        assert(info.applied);
        double outputError = 0, outputChroma = 0, projection = 0, texturePower = 0;
        cv::Vec3d outputMean{};
        for (int y = 0; y < 256; ++y) for (int x = 0; x < 256; ++x) {
            const float texture = mode == 3 && x >= 64 && x < 192 && y >= 64 && y < 192 ?
                .012f * std::sin(1.1f * x) * std::cos(.7f * y) : 0;
            const auto& pixel = output.at(x, y);
            const cv::Vec3f value(pixel.r, pixel.g, pixel.b);
            for (int c = 0; c < 3; ++c) {
                assert(std::isfinite(value[c]));
                outputError += (value[c] - mean - texture) * (value[c] - mean - texture);
                outputMean[c] += value[c] / double(source.pixels.size());
            }
            outputChroma += (value[0] - value[1]) * (value[0] - value[1]) +
                (value[2] - value[1]) * (value[2] - value[1]);
            if (mode == 3 && x >= 80 && x < 176 && y >= 80 && y < 176) {
                projection += texture * ((value[0] + value[1] + value[2]) / 3 - mean);
                texturePower += texture * texture;
            }
        }
        std::cout << "Near-black mode " << mode << " mse=" << outputError / inputError
                  << " chroma-energy=" << outputChroma / inputChroma
                  << " texture=" << (texturePower ? projection / texturePower : 0) << '\n';
        assert(outputError < inputError);
        assert(outputChroma < inputChroma * .8);
        for (int c = 0; c < 3; ++c) near(outputMean[c], inputMean[c], .0005);
        if (mode == 3) assert(projection / texturePower > .75);
    }
}

void correlationControls() {
    cv::Mat ramp(32, 32, CV_32FC3);
    for (int y = 0; y < ramp.rows; ++y) for (int x = 0; x < ramp.cols; ++x) {
        const float value = x + y;
        ramp.at<cv::Vec3f>(y, x) = {value, 2 * value, -value};
    }
    const auto literal = denoise_quality::residualCorrelations(ramp);
    assert(literal.rgb[0].has_value());
    near(*literal.rgb[0], 1);
    near(*literal.rgb[1], -1);
    near(*literal.rgb[2], -1);
    for (const auto& lag : literal.spatial) for (const auto& value : lag) {
        assert(value.has_value());
        near(*value, 1);
    }
    const cv::Mat constant(32, 32, CV_32FC3, cv::Scalar(0, 0, 0));
    const auto empty = denoise_quality::residualCorrelations(constant);
    for (const auto& value : empty.rgb) assert(!value.has_value());
    for (const auto& lag : empty.spatial) for (const auto& value : lag) assert(!value.has_value());

    cv::Mat independent(256, 256, CV_32FC3), correlated(independent.size(), independent.type());
    std::mt19937 random(7321);
    std::normal_distribution<float> normal(0, 1);
    for (int y = 0; y < independent.rows; ++y) for (int x = 0; x < independent.cols; ++x) {
        const float r = normal(random), g = normal(random), b = normal(random);
        independent.at<cv::Vec3f>(y, x) = {r, g, b};
        correlated.at<cv::Vec3f>(y, x) = {r, r + .1f * g, r + .1f * b};
    }
    const auto white = denoise_quality::residualCorrelations(independent);
    const auto mixed = denoise_quality::residualCorrelations(correlated);
    for (int c = 0; c < 3; ++c) {
        assert(white.rgb[c] && std::abs(*white.rgb[c]) < .03);
        // 这是真实随机噪声的线性混合，不能仅凭相关性接近 1 就判成图案。
        assert(mixed.rgb[c] && *mixed.rgb[c] > .98);
    }
    for (const auto& lag : mixed.spatial) for (const auto& value : lag)
        assert(value && std::abs(*value) < .03);
}
}

int main() {
    residualAccounting();
    robustFitWithContamination();
    patternCannotSetItsOwnNoiseAllowance();
    constrainedFloorCannotRejectNegativeNoise();
    samplingKeepsNoiseControls();
    constantModelScaleCancelsThroughCalibration();
    nearBlackNoiseAndTexture();
    correlationControls();
    std::cout << "PASS: literal residual accounting and minority-contamination fit\n";
}
