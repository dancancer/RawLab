#include "core/noise_aware_sharpen.h"
#include "gpu/metal_sharpen.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <vector>
#import <Metal/Metal.h>

namespace {
int readbacks = 0, failReadback = 0, injected = 0, position = 0;
float nonfinite = 0;

void reset(int fail = 0) {
    readbacks = injected = 0;
    failReadback = fail;
}

bool identical(const sony2fuji::ImageData& a, const sony2fuji::ImageData& b) {
    return a.width == b.width && a.height == b.height &&
        std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(sony2fuji::RGB)) == 0;
}

void readbackFailure() {
    using namespace sony2fuji;
    constexpr int width = 13, height = 9, count = width * height;
    std::vector<float> rgb(3 * count, .5f), luma(count, .5f), residual(count, 0), noise(count, 0);
    std::vector<float> output(3 * count, -23.f);
    reset();
    assert(metalNoiseAwareSharpen(rgb.data(), luma.data(), residual.data(), noise.data(),
        width, height, 2, output.data()));
    assert(readbacks == 1 && injected == 0);
    for (float value : output) assert(value == .5f);

    for (position = 0; position < 3; ++position) {
        std::fill(output.begin(), output.end(), -23.f);
        const auto original = output;
        reset(1);
        assert(!metalNoiseAwareSharpen(rgb.data(), luma.data(), residual.data(), noise.data(),
            width, height, 2, output.data()));
        assert(readbacks == 1 && injected == 1);
        assert(std::memcmp(output.data(), original.data(), output.size() * sizeof(float)) == 0);
    }
}

void tiledFailure(const sony2fuji::ImageData& source, const sony2fuji::ImageData& cpu,
                  const sony2fuji::ImageData& metal, const sony2fuji::NoiseAwareSharpenDiagnostics& cpuInfo) {
    using namespace sony2fuji;
    auto image = source;
    NoiseAwareSharpenDiagnostics info{false, false, 7, 9};
    position = 2;
    reset(2);
    assert(applyNoiseAwareSharpen(image, 2, &info, GpuMode::Auto) == ErrorCode::Success);
    assert(readbacks == 3 && injected == 1 && info.applied && info.gpuUsed);
    assert(info.noiseSigmaMedian == cpuInfo.noiseSigmaMedian && info.noiseSigmaMax == cpuInfo.noiseSigmaMax);
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x) {
        const auto& expected = (x >= 768 && x < 1536 ? cpu : metal).at(x, y);
        assert(std::memcmp(&image.at(x, y), &expected, sizeof(RGB)) == 0);
    }

    image = source;
    info = {true, true, 7, 9};
    reset(2);
    assert(applyNoiseAwareSharpen(image, 2, &info, GpuMode::Force) == ErrorCode::ProcessingError);
    assert(readbacks == 2 && injected == 1 && identical(image, source));
    assert(!info.applied && !info.gpuUsed && info.noiseSigmaMedian == 0 && info.noiseSigmaMax == 0);
    reset();
    assert(applyNoiseAwareSharpen(image, 2, &info, GpuMode::Force) == ErrorCode::Success);
    assert(readbacks == 3 && injected == 0 && info.applied && info.gpuUsed && identical(image, metal));
    assert(info.noiseSigmaMedian == cpuInfo.noiseSigmaMedian && info.noiseSigmaMax == cpuInfo.noiseSigmaMax);
}
}

// 仅独立测试目标启用；真实 command 完成后污染其读回缓冲，不替换 finite 检查。
namespace sony2fuji {
void testNoiseAwareSharpenReadback(float* values, size_t count) {
    ++readbacks;
    if (readbacks != failReadback) return;
    ++injected;
    const size_t index = position == 0 ? 0 : position == 1 ? count / 2 : count - 1;
    values[index] = nonfinite;
}
}

int main() {
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
            if (!MTLCreateSystemDefaultDevice()) {
                std::cout << "SKIP: no Metal device\n";
                return 77;
            }
        } else {
            std::cout << "SKIP: P3 Metal requires macOS 15 / iOS 18\n";
            return 77;
        }
    }
    using namespace sony2fuji;
    ImageData source(1553, 65);
    for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x) {
        const float value = .5f + .3f * std::erf(((x % 192) - 96.f) / 1.41421356f) +
            .0005f * std::sin(float(x * 17 + y * 31));
        source.at(x, y) = RGB(value, value * .9f, value * .8f);
    }
    auto cpu = source, metal = source;
    NoiseAwareSharpenDiagnostics info, cpuInfo;
    assert(applyNoiseAwareSharpen(cpu, 2, &cpuInfo) == ErrorCode::Success);
    assert(cpuInfo.noiseSigmaMedian > 0 && std::isfinite(cpuInfo.noiseSigmaMax) &&
        cpuInfo.noiseSigmaMax >= cpuInfo.noiseSigmaMedian);
    assert(!identical(cpu, source));
    reset();
    assert(applyNoiseAwareSharpen(metal, 2, &info, GpuMode::Force) == ErrorCode::Success);
    assert(readbacks == 3 && injected == 0 && info.applied && info.gpuUsed);
    for (const float value : {std::numeric_limits<float>::quiet_NaN(),
                             std::numeric_limits<float>::infinity(),
                             -std::numeric_limits<float>::infinity()}) {
        nonfinite = value;
        readbackFailure();
        tiledFailure(source, cpu, metal, cpuInfo);
    }
    std::cout << "Metal NaN/+Inf/-Inf: 9 direct readback rejections, 3 Auto mixed fallbacks, "
                 "3 Force atomic failures and 3 recoveries passed\n";
}
