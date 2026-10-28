#include "core/wavelet_denoise.h"
#include <opencv2/core.hpp>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <random>
#include <stdexcept>
#include <sys/resource.h>

namespace {
uint64_t peakRssBytes() {
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) != 0) throw std::runtime_error("Cannot read peak RSS");
#if defined(__APPLE__)
    return static_cast<uint64_t>(usage.ru_maxrss);
#else
    return static_cast<uint64_t>(usage.ru_maxrss) * 1024;
#endif
}

uint64_t fingerprint(const sony2fuji::ImageData& image) {
    uint64_t result = 14695981039346656037ULL;
    for (const auto& pixel : image.pixels) {
        uint32_t bits[3];
        static_assert(sizeof(bits) == sizeof(pixel));
        std::memcpy(bits, &pixel, sizeof(bits));
        for (auto value : bits) result = (result ^ value) * 1099511628211ULL;
    }
    return result;
}
}

int main(int argc, char** argv) {
    try {
        const int threads = argc > 1 ? std::stoi(argv[1]) : 4;
        if (threads < 1) throw std::runtime_error("Thread count must be positive");
        cv::setNumThreads(threads);
        // 包含调用方实际保留的原图和工作图；独立进程避免其他测试污染峰值。
        sony2fuji::ImageData source(8192, 7680);
        std::mt19937 rng(7381);
        std::normal_distribution<float> noise(.18f, .014f);
        for (auto& pixel : source.pixels) pixel = {noise(rng), noise(rng), noise(rng)};
        const auto original = fingerprint(source);
        auto image = source;
        const uint64_t imageBytes = source.pixels.size() * sizeof(sony2fuji::RGB);
        const uint64_t baseline = peakRssBytes();
        // 两份整图之外，容纳六层 SWT tile、行带及 OpenCV/分配器保留的页。
        // 余量固定，不随像素数增长；额外整图变换/输出会超出预算。
        const uint64_t budget = 2 * imageBytes + 1280ULL * 1024 * 1024;
        std::cout << "Legacy memory: pixels=" << source.pixels.size() << " threads=" << threads
            << " baseline_rss_bytes=" << baseline << " budget_bytes=" << budget << std::endl;
        const auto start = std::chrono::steady_clock::now();
        sony2fuji::WaveletDenoiseDiagnostics diagnostics;
        const auto result = sony2fuji::applyWaveletDenoise(image,
            {true, 40, 46, 100, sony2fuji::ProcessingVersion::Legacy}, &diagnostics,
            sony2fuji::GpuMode::Off, nullptr, {}, &source);
        const auto peak = peakRssBytes();
        const auto seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        std::cout << "peak_rss_bytes=" << peak << " seconds=" << seconds
            << " applied=" << diagnostics.applied << " flat_tiles=" << diagnostics.flatTiles << std::endl;
        if (result != sony2fuji::ErrorCode::Success || !diagnostics.applied || diagnostics.gpuUsed)
            throw std::runtime_error("Large Legacy fixture must execute CPU denoising");
        if (fingerprint(source) != original || fingerprint(image) == original)
            throw std::runtime_error("Denoising must change the work image and preserve its source");
        for (const auto& pixel : image.pixels)
            if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b))
                throw std::runtime_error("Denoising produced non-finite pixels");
        if (peak > budget) throw std::runtime_error("Legacy exceeds two full images plus bounded tile scratch");
        std::cout << "PASS: 62.9 MP Legacy peak RSS and immutable source\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
