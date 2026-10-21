#include "core/wavelet_denoise.h"
#include "gpu/denoise.h"
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <random>

using namespace sony2fuji;

// 测试可重复触发失败，不依赖本机 GPU 是否可用，也不改变正式后端。
bool sony2fuji::gpuWaveletFilter(const float*, int, int, const WaveletFilterSettings&, float*) { return false; }

int main() {
    WaveletDenoiseDiagnostics info;
    ImageData image(256, 256);
    for (auto& pixel : image.pixels) pixel = {.18f, .18f, .18f};
    assert(applyWaveletDenoise(image, {}, &info) == ErrorCode::Success);
    assert(info.outcome == WaveletDenoiseOutcome::Disabled && !info.applied);
    assert(applyWaveletDenoise(image, {true, 0, 0, 50}, &info) == ErrorCode::Success);
    assert(info.outcome == WaveletDenoiseOutcome::ZeroStrength);
    assert(applyWaveletDenoise(image, {true, -1, 0, 50}, &info) == ErrorCode::InvalidFormat);
    assert(info.outcome == WaveletDenoiseOutcome::InvalidOptions && info.flatTiles == 0);
    const WaveletDenoiseOptions settings{true, 10, 72, 0};
    if (!waveletDenoiseAvailable()) {
        assert(applyWaveletDenoise(image, settings, &info) == ErrorCode::InvalidFormat);
        assert(info.outcome == WaveletDenoiseOutcome::UnsupportedBuild);
        std::cout << "PASS: disabled-build outcomes\n";
        return 0;
    }
    auto invalid = image;
    invalid.pixels.pop_back();
    assert(applyWaveletDenoise(invalid, settings, &info) == ErrorCode::InvalidFormat);
    assert(info.outcome == WaveletDenoiseOutcome::InvalidImage);
    invalid = image;
    invalid.pixels[0].r = std::numeric_limits<float>::quiet_NaN();
    assert(applyWaveletDenoise(invalid, settings, &info) == ErrorCode::InvalidFormat);
    assert(info.outcome == WaveletDenoiseOutcome::InvalidImage);
    auto clean = image;
    WaveletDenoiseAnalysisCache cleanCache;
    assert(applyWaveletDenoise(clean, settings, &info, GpuMode::Off, &cleanCache, "clean") == ErrorCode::Success);
    assert(info.outcome == WaveletDenoiseOutcome::LowNoise);
    assert(info.estimate.candidateTiles == 16 && info.estimate.rejectedLowNoise == 16);
    assert(!info.estimate.fitAvailable && info.flatTiles == 0);
    assert(applyWaveletDenoise(clean, settings, &info, GpuMode::Off, &cleanCache, "clean") == ErrorCode::Success);
    assert(info.analysisReused && info.estimate.rejectedLowNoise == 16 && info.outcome == WaveletDenoiseOutcome::LowNoise);
    ImageData small(32, 32);
    assert(applyWaveletDenoise(small, settings, &info) == ErrorCode::Success);
    assert(info.outcome == WaveletDenoiseOutcome::SmallImage && info.estimate.rejectedSmall == 1);
    auto periodic = image;
    auto gradient = image;
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x) {
        const float stripe = .18f + .01f * std::sin(x * 1.7f);
        periodic.at(x, y) = {stripe, stripe, stripe};
        const float ramp = .02f + .65f * x / image.width;
        gradient.at(x, y) = {ramp, ramp, ramp};
    }
    assert(applyWaveletDenoise(periodic, settings, &info) == ErrorCode::Success);
    assert(!info.applied && info.estimate.rejectedPeriodic > 0);
    assert(applyWaveletDenoise(gradient, settings, &info) == ErrorCode::Success);
    assert(!info.applied && info.estimate.rejectedStructure > 0);

    std::mt19937 random(137);
    std::normal_distribution<float> noise(.18f, .014f);
    for (auto& pixel : image.pixels) pixel = {noise(random), noise(random), noise(random)};
    ImageData insufficient(64, 64);
    for (auto& pixel : insufficient.pixels) pixel = {noise(random), noise(random), noise(random)};
    assert(applyWaveletDenoise(insufficient, settings, &info) == ErrorCode::Success);
    assert(info.outcome == WaveletDenoiseOutcome::InsufficientSamples && info.flatTiles == 1);
    assert(info.estimate.sampleMeanMin[0] > .1f && !info.estimate.fitAvailable);

    WaveletDenoiseAnalysisCache cache;
    auto output = image;
    assert(applyWaveletDenoise(output, settings, &info, GpuMode::Off, &cache, "noise") == ErrorCode::Success);
    const auto cold = info;
    assert(info.outcome == WaveletDenoiseOutcome::Applied && info.applied && !info.gpuUsed);
    assert(info.estimate.fitAvailable && info.flatTiles >= 8 && !info.analysisReused);
    assert(info.estimate.candidateTiles == info.flatTiles + info.estimate.rejectedSmall +
        info.estimate.rejectedStructure + info.estimate.rejectedLowNoise + info.estimate.rejectedPeriodic);
    for (int c = 0; c < 3; ++c) {
        assert(info.estimate.constantVarianceFallback[c]);
        assert(info.estimate.sampleMeanMin[c] <= info.estimate.sampleMeanMax[c]);
        assert(std::isfinite(info.estimate.relativeFitRmse[c]) && info.estimate.relativeFitRmse[c] >= 0);
        assert(info.estimate.sampleVarianceMedian[c] > 0 && info.estimate.fitRmse[c] >= 0);
        assert(info.estimate.relativeFitMedianAbsResidual[c] >= 0);
        assert(info.estimate.fitTopDecileErrorFraction[c] >= 0 && info.estimate.fitTopDecileErrorFraction[c] <= 1);
        assert(std::abs(info.estimate.fitRmse[c] / info.estimate.sampleVarianceMedian[c] -
            info.estimate.relativeFitRmse[c]) < 1e-12);
        assert(info.a[c] == 0 && info.b[c] > 0);
    }
    auto cached = image;
    assert(applyWaveletDenoise(cached, settings, &info, GpuMode::Off, &cache, "noise") == ErrorCode::Success);
    assert(info.analysisReused && info.outcome == WaveletDenoiseOutcome::Applied);
    assert(info.estimate.candidateTiles == cold.estimate.candidateTiles);
    for (int c = 0; c < 3; ++c) {
        assert(info.estimate.sampleMeanMin[c] == cold.estimate.sampleMeanMin[c]);
        assert(info.estimate.sampleMeanMax[c] == cold.estimate.sampleMeanMax[c]);
        assert(info.estimate.relativeFitRmse[c] == cold.estimate.relativeFitRmse[c]);
        assert(info.estimate.sampleVarianceMedian[c] == cold.estimate.sampleVarianceMedian[c]);
        assert(info.estimate.fitRmse[c] == cold.estimate.fitRmse[c]);
        assert(info.estimate.relativeFitMedianAbsResidual[c] == cold.estimate.relativeFitMedianAbsResidual[c]);
        assert(info.estimate.fitTopDecileErrorFraction[c] == cold.estimate.fitTopDecileErrorFraction[c]);
    }
    assert(std::memcmp(output.pixels.data(), cached.pixels.data(), output.pixels.size() * sizeof(RGB)) == 0);
    auto noReport = image;
    assert(applyWaveletDenoise(noReport, settings) == ErrorCode::Success);
    assert(std::memcmp(output.pixels.data(), noReport.pixels.data(), output.pixels.size() * sizeof(RGB)) == 0);
    auto forced = image;
    assert(applyWaveletDenoise(forced, settings, &info, GpuMode::Force, &cache, "noise") == ErrorCode::ProcessingError);
    assert(info.outcome == WaveletDenoiseOutcome::GpuFailure && !info.applied && !info.gpuUsed);
    assert(info.estimate.fitAvailable && info.analysisReused);
    assert(std::memcmp(image.pixels.data(), forced.pixels.data(), image.pixels.size() * sizeof(RGB)) == 0);
    auto automatic = image;
    assert(applyWaveletDenoise(automatic, settings, &info, GpuMode::Auto, &cache, "noise") == ErrorCode::Success);
    assert(info.outcome == WaveletDenoiseOutcome::Applied && !info.gpuUsed);
    assert(std::memcmp(output.pixels.data(), automatic.pixels.data(), output.pixels.size() * sizeof(RGB)) == 0);
    assert(applyWaveletDenoise(automatic, {}, &info) == ErrorCode::Success);
    assert(!info.estimate.fitAvailable && info.flatTiles == 0 && !info.applied && !info.analysisReused);
    std::cout << "PASS: outcomes, sampling/fit evidence, cache parity, diagnostics pixel parity, Force failure and Auto fallback\n";
}
