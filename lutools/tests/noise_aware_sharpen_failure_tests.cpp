#include "core/noise_aware_sharpen.h"
#include "gpu/metal_sharpen.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>

namespace {
int calls = 0;
bool firstTileSucceeds = false;
}

// 链接替身仅验证调用方的回退和提交时机，不作为 GPU 画质或硬件证据。
namespace sony2fuji {
bool metalNoiseAwareSharpen(const float*, const float*, const float*, const float*,
                           int width, int height, float, float* output) {
    ++calls;
    if (!firstTileSucceeds || calls > 1) return false;
    std::fill_n(output, static_cast<size_t>(width) * height * 3, .123f);
    return true;
}
}

int main() {
    using namespace sony2fuji;
    ImageData source(1553, 65);
    for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x) {
        const float value = .5f + .3f * std::erf((x - 768.f) / 1.41421356f);
        source.at(x, y) = RGB(value, value, value);
    }
    auto cpu = source, automatic = source, forced = source;
    assert(applyNoiseAwareSharpen(cpu, 2) == ErrorCode::Success);
    NoiseAwareSharpenDiagnostics info;
    assert(applyNoiseAwareSharpen(automatic, 2, &info, GpuMode::Auto) == ErrorCode::Success);
    assert(calls == 3 && info.applied && !info.gpuUsed);
    assert(std::memcmp(cpu.pixels.data(), automatic.pixels.data(), cpu.pixels.size() * sizeof(RGB)) == 0);
    calls = 0;
    firstTileSucceeds = true;
    assert(applyNoiseAwareSharpen(forced, 2, &info, GpuMode::Force) == ErrorCode::ProcessingError);
    assert(calls == 2 && !info.applied && !info.gpuUsed);
    assert(std::memcmp(source.pixels.data(), forced.pixels.data(), source.pixels.size() * sizeof(RGB)) == 0);
}
