#include "core/noise_aware_sharpen.h"
#include "gpu/metal_sharpen.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <new>
#include <opencv2/core.hpp>

namespace {
int calls = 0;
std::array<bool, 3> succeeds{};
enum class Fault { None, Allocation, OpenCv };
enum class FaultStage { Initial, BetweenTiles, Fallback };
Fault afterFirstTile = Fault::None;
Fault inFallback = Fault::None;
thread_local bool failAllocation = false;
thread_local bool failOpenCv = false;
int injected = 0;

void arm(Fault fault) {
    failAllocation = fault == Fault::Allocation;
    failOpenCv = fault == Fault::OpenCv;
}

class ScopedFailingAllocator final : public cv::MatAllocator {
public:
    ScopedFailingAllocator() : original(cv::Mat::getDefaultAllocator()) {
        cv::Mat::setDefaultAllocator(this);
    }
    ~ScopedFailingAllocator() override { cv::Mat::setDefaultAllocator(original); }
    cv::UMatData* allocate(int dims, const int* sizes, int type, void* data, size_t* step,
                          cv::AccessFlag flags, cv::UMatUsageFlags usage) const override {
        if (failOpenCv) {
            failOpenCv = false;
            ++injected;
            CV_Error(cv::Error::StsError, "injected P3 OpenCV allocation failure");
        }
        return original->allocate(dims, sizes, type, data, step, flags, usage);
    }
    bool allocate(cv::UMatData* data, cv::AccessFlag flags, cv::UMatUsageFlags usage) const override {
        return original->allocate(data, flags, usage);
    }
    void deallocate(cv::UMatData* data) const override { original->deallocate(data); }
private:
    cv::MatAllocator* original;
};

bool identical(const sony2fuji::ImageData& a, const sony2fuji::ImageData& b) {
    return a.width == b.width && a.height == b.height &&
        std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(sony2fuji::RGB)) == 0;
}

void assertReset(const sony2fuji::NoiseAwareSharpenDiagnostics& info) {
    assert(!info.applied && !info.gpuUsed && info.noiseSigmaMedian == 0 && info.noiseSigmaMax == 0);
}

void mixedFallback(const sony2fuji::ImageData& source, const sony2fuji::ImageData& cpu,
                   const sony2fuji::NoiseAwareSharpenDiagnostics& cpuInfo, std::array<bool, 3> pattern) {
    using namespace sony2fuji;
    calls = 0;
    succeeds = pattern;
    auto image = source;
    NoiseAwareSharpenDiagnostics info{false, false, 7, 9};
    assert(applyNoiseAwareSharpen(image, 2, &info, GpuMode::Auto) == ErrorCode::Success);
    assert(calls == 3 && info.applied && info.gpuUsed);
    assert(info.noiseSigmaMedian == cpuInfo.noiseSigmaMedian && info.noiseSigmaMax == cpuInfo.noiseSigmaMax);
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x) {
        const int tile = x / 768;
        const float sentinel = .123f * (tile + 1);
        const RGB expected = pattern[tile] ? RGB(sentinel, sentinel, sentinel) : cpu.at(x, y);
        assert(std::memcmp(&image.at(x, y), &expected, sizeof(RGB)) == 0);
    }
}

void exceptionFailure(const sony2fuji::ImageData& source, const sony2fuji::ImageData& cpu,
                      Fault fault, sony2fuji::GpuMode mode, FaultStage stage) {
    using namespace sony2fuji;
    auto image = source;
    NoiseAwareSharpenDiagnostics info{true, true, 7, 9};
    calls = injected = 0;
    succeeds = {true, stage != FaultStage::Fallback, true};
    afterFirstTile = stage == FaultStage::BetweenTiles ? fault : Fault::None;
    inFallback = stage == FaultStage::Fallback ? fault : Fault::None;
    arm(stage == FaultStage::Initial ? fault : Fault::None);
    const auto status = applyNoiseAwareSharpen(image, 2, &info, mode);
    arm(Fault::None);
    afterFirstTile = inFallback = Fault::None;
    const int expectedCalls = stage == FaultStage::Initial ? 0 : stage == FaultStage::BetweenTiles ? 1 : 2;
    assert(injected == 1 && calls == expectedCalls);
    assert(status == (fault == Fault::Allocation ? ErrorCode::OutOfMemory : ErrorCode::ProcessingError));
    assert(identical(image, source));
    assertReset(info);
    assert(applyNoiseAwareSharpen(image, 2, &info, GpuMode::Off) == ErrorCode::Success);
    assert(info.applied && !info.gpuUsed && identical(image, cpu));
}
}

// 只替换此独立测试进程的 C++ 分配，不给生产核心增加故障开关。
void* operator new(std::size_t size) {
    if (failAllocation) {
        failAllocation = false;
        ++injected;
        throw std::bad_alloc();
    }
    if (void* result = std::malloc(size ? size : 1)) return result;
    throw std::bad_alloc();
}
void* operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void* value) noexcept { std::free(value); }
void operator delete[](void* value) noexcept { std::free(value); }
void operator delete(void* value, std::size_t) noexcept { std::free(value); }
void operator delete[](void* value, std::size_t) noexcept { std::free(value); }

// 链接替身仅验证调用方的回退和提交时机，不作为 GPU 画质或硬件证据。
namespace sony2fuji {
bool metalNoiseAwareSharpen(const float*, const float*, const float*, const float*,
                           int width, int height, float, float* output) {
    ++calls;
    assert(calls <= 3);
    const bool success = succeeds[calls - 1];
    std::fill_n(output, static_cast<size_t>(width) * height * 3, success ? .123f * calls : -99.f);
    if (calls == 1) arm(afterFirstTile);
    if (calls == 2 && !success) arm(inFallback);
    return success;
}
}

int main() {
    using namespace sony2fuji;
    cv::setNumThreads(1);
    ScopedFailingAllocator allocator;
    ImageData source(1553, 65);
    for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x) {
        const float value = .5f + .3f * std::erf((x - 768.f) / 1.41421356f) +
            .0005f * std::sin(float(x * 17 + y * 31));
        source.at(x, y) = RGB(value, value, value);
    }
    auto cpu = source, automatic = source, forced = source;
    NoiseAwareSharpenDiagnostics cpuInfo;
    assert(applyNoiseAwareSharpen(cpu, 2, &cpuInfo) == ErrorCode::Success);
    assert(cpuInfo.noiseSigmaMedian > 0 && std::isfinite(cpuInfo.noiseSigmaMax) &&
        cpuInfo.noiseSigmaMax >= cpuInfo.noiseSigmaMedian);
    NoiseAwareSharpenDiagnostics info;
    assert(applyNoiseAwareSharpen(automatic, 2, &info, GpuMode::Auto) == ErrorCode::Success);
    assert(calls == 3 && info.applied && !info.gpuUsed);
    assert(std::memcmp(cpu.pixels.data(), automatic.pixels.data(), cpu.pixels.size() * sizeof(RGB)) == 0);
    calls = 0;
    succeeds = {true, false, true};
    info = {true, true, 7, 9};
    assert(applyNoiseAwareSharpen(forced, 2, &info, GpuMode::Force) == ErrorCode::ProcessingError);
    assert(calls == 2 && identical(source, forced));
    assertReset(info);
    mixedFallback(source, cpu, cpuInfo, {true, false, true});
    mixedFallback(source, cpu, cpuInfo, {false, true, false});
    std::cout << "Auto all-failed/mixed fallback and Force partial-failure atomicity passed\n";

    for (const auto fault : {Fault::Allocation, Fault::OpenCv}) {
        for (const auto mode : {GpuMode::Off, GpuMode::Auto, GpuMode::Force})
            exceptionFailure(source, cpu, fault, mode, FaultStage::Initial);
        for (const auto mode : {GpuMode::Auto, GpuMode::Force})
            exceptionFailure(source, cpu, fault, mode, FaultStage::BetweenTiles);
        exceptionFailure(source, cpu, fault, GpuMode::Auto, FaultStage::Fallback);
    }
    std::cout << "12 allocation/OpenCV exception cases passed, including post-tile/fallback failures and recovery\n";
}
