#include "gpu/metal_denoise.h"
#include "core/wavelet_denoise.h"
#include "core/chroma_denoise.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/ximgproc/edge_filter.hpp>
#include <wavelib.h>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <random>
#include <vector>

using namespace sony2fuji;

static void compare(const std::vector<float>& expected, const std::vector<float>& actual,
                    float absolute, float relative, const char* label) {
    assert(expected.size() == actual.size());
    double square = 0;
    float maximum = 0;
    for (size_t i = 0; i < expected.size(); ++i) {
        const float error = std::abs(expected[i] - actual[i]);
        if (!std::isfinite(actual[i]) || error > absolute + relative * std::abs(expected[i])) {
            std::cerr << label << " index=" << i << " CPU=" << expected[i] << " GPU=" << actual[i] << '\n';
            std::abort();
        }
        maximum = std::max(maximum, error); square += double(error) * error;
    }
    std::cout << "PASS " << label << " max=" << maximum << " RMSE=" << std::sqrt(square / expected.size()) << std::endl;
}

static std::vector<float> waveletReference(const std::vector<float>& input, int width, int height,
                                          const WaveletFilterSettings& settings) {
    const size_t count = input.size();
    auto wave = wave_init("db2");
    auto transform = wt2_init(wave, "swt", height, width, settings.depth);
    std::vector<double> source(input.begin(), input.end()), result(count);
    double* coefficients = swt2(transform, source.data());
    for (int scale = 0; scale < settings.depth; ++scale) {
        const int level = settings.depth - scale;
        const float divisor = float(1 << level);
        const int window = level > 4 ? (1 << (level - 1)) + 1 : 7;
        for (int direction = 0; direction < 3; ++direction) {
            double* block = coefficients + (1 + scale * 3 + direction) * count;
            cv::Mat band(height, width, CV_32F), power;
            for (size_t i = 0; i < count; ++i) band.ptr<float>()[i] = float(block[i] / divisor);
            cv::boxFilter(band.mul(band), power, -1, {window, window});
            const float variance = std::pow(settings.sigma[scale * 3 + direction], 2);
            for (size_t i = 0; i < count; ++i) {
                const float value = band.ptr<float>()[i];
                const float threshold = settings.thresholdScale[scale] * variance /
                    std::sqrt(std::max(power.ptr<float>()[i] - variance, .05f * variance));
                block[i] = std::copysign(std::max(std::abs(value) - threshold, 0.f), value) * divisor;
            }
        }
    }
    iswt2(transform, coefficients, result.data());
    std::free(coefficients); wt2_free(transform); wave_free(wave);
    return std::vector<float>(result.begin(), result.end());
}

static void waveletTests() {
    std::mt19937 random(42);
    std::normal_distribution<float> noise(0, .7f);
    for (int depth : {4, 6}) for (bool shrink : {false, true}) {
        const int width = depth == 6 ? 320 : 192, height = depth == 6 ? 256 : 128;
        std::vector<float> input(width * height), result(input.size(), -999);
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x)
            input[y * width + x] = noise(random) + x * .001f + (x >= 97 ? 1.f : 0.f);
        input[0] = 25; input.back() = -20;
        WaveletFilterSettings settings;
        settings.depth = depth;
        std::fill(std::begin(settings.sigma), std::end(settings.sigma), .4f);
        std::fill(std::begin(settings.thresholdScale), std::end(settings.thresholdScale), shrink ? 1.5f : 0.f);
        assert(metalWaveletFilter(input.data(), width, height, settings, result.data()));
        compare(waveletReference(input, width, height, settings), result, 5e-5f, 5e-5f, "db2 tiled filter");
        if (!shrink) compare(input, result, 5e-5f, 5e-5f, "db2 reconstruction");
        auto repeated = result;
        assert(metalWaveletFilter(input.data(), width, height, settings, repeated.data()));
        assert(repeated == result);
        settings.depth = 7;
        assert(!metalWaveletFilter(input.data(), width, height, settings, repeated.data()));
        assert(repeated == result);
    }
}

static void guidedTests() {
    std::mt19937 random(73);
    std::normal_distribution<float> noise(0, 2);
    for (const auto size : {cv::Size(1, 1), cv::Size(3, 7), cv::Size(193, 129), cv::Size(801, 797)}) {
        cv::Mat guide(size, CV_32FC3), source(size, CV_32FC2);
        for (int y = 0; y < size.height; ++y) for (int x = 0; x < size.width; ++x) {
            guide.at<cv::Vec3f>(y, x) = {float(x < size.width / 2 ? 30 : 70) + noise(random),
                12 + noise(random), -8 + noise(random)};
            source.at<cv::Vec2f>(y, x) = {guide.at<cv::Vec3f>(y, x)[1] + noise(random), noise(random)};
        }
        for (int radius : {4, 8}) for (float epsilon : {.05f, 64.f}) {
            cv::Mat reference;
            cv::ximgproc::guidedFilter(guide, source, reference, radius, epsilon);
            std::vector<float> output(source.total() * 2);
            assert(metalGuidedFilter(guide.ptr<float>(), source.ptr<float>(), size.width, size.height,
                                     radius, epsilon, output.data()));
            compare(std::vector<float>(reference.ptr<float>(), reference.ptr<float>() + output.size()),
                    output, 0.003f, 0.0001f, "RGB-guide chroma filter");
        }
    }
}

static std::vector<float> pixels(const ImageData& image) {
    std::vector<float> result;
    for (const auto& p : image.pixels) { result.push_back(p.r); result.push_back(p.g); result.push_back(p.b); }
    return result;
}

static void denoiserTests() {
    ImageData image(597, 389);
    std::mt19937 random(93);
    std::normal_distribution<float> noise(0, .014f);
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x) {
        const float level = x < 280 ? .18f : .4f;
        image.at(x, y) = {level + noise(random), level + noise(random), level + noise(random)};
    }
    for (const WaveletDenoiseOptions settings : {WaveletDenoiseOptions{true, 60, 0, 0},
         WaveletDenoiseOptions{true, 0, 70, 100}, WaveletDenoiseOptions{true, 100, 100, 0}}) {
        auto cpu = image, gpu = image;
        WaveletDenoiseDiagnostics diagnostics;
        assert(applyWaveletDenoise(cpu, settings) == ErrorCode::Success);
        assert(applyWaveletDenoise(gpu, settings, &diagnostics, GpuMode::Force) == ErrorCode::Success);
        assert(diagnostics.applied && diagnostics.gpuUsed);
        compare(pixels(cpu), pixels(gpu), 5e-5f, 5e-5f, "complete wavelet denoiser");
    }
    for (int mode : {1, 2}) {
        auto cpu = image, gpu = image;
        ChromaDenoiseDiagnostics diagnostics;
        assert(applyChromaDenoise(cpu, mode) == ErrorCode::Success);
        assert(applyChromaDenoise(gpu, mode, &diagnostics, GpuMode::Force) == ErrorCode::Success);
        assert(diagnostics.applied && diagnostics.gpuUsed);
        compare(pixels(cpu), pixels(gpu), .0002f, .0002f, "complete chroma denoiser");
    }
    auto unchanged = image;
    assert(applyWaveletDenoise(unchanged, {false, 50, 50, 50}, nullptr, GpuMode::Force) == ErrorCode::Success);
    assert(applyChromaDenoise(unchanged, 0, nullptr, GpuMode::Force) == ErrorCode::Success);
    assert(pixels(unchanged) == pixels(image));
    ImageData small(1, 1); small.at(0, 0) = {0, .5f, 2};
    const auto original = pixels(small);
    assert(applyWaveletDenoise(small, {true, 100, 100, 100}, nullptr, GpuMode::Force) == ErrorCode::Success);
    assert(applyChromaDenoise(small, 2, nullptr, GpuMode::Force) == ErrorCode::Success);
    assert(pixels(small) == original);
}

int main() {
    waveletTests();
    guidedTests();
    denoiserTests();
}
