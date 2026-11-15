#include "gpu/compute_denoise.h"
#include "d3d11_test_hooks.h"
#undef RGB
#include <algorithm>
#include <cmath>
#include <iostream>
#include <vector>

using namespace sony2fuji;
namespace {
void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
void guided(FilterDevice* device, int width, int height, float value) {
    const size_t n = size_t(width) * height;
    std::vector<float> guide(n * 3, .4f), input(n * 2), output(n * 2, -7);
    for (size_t i = 0; i < n; ++i) { input[2 * i] = value; input[2 * i + 1] = -value * .5f; }
    const bool ok = device ? computeGuidedFilter(*device, guide.data(), input.data(), width, height, 2, .01f, output.data())
        : gpuGuidedFilter(guide.data(), input.data(), width, height, 2, .01f, output.data());
    require(ok, "C21: native guided filter failed");
    for (size_t i = 0; i < n * 2; ++i)
        require(std::isfinite(output[i]) && std::abs(output[i] - input[i]) < 1e-4f,
            "C21: reused buffer retained stale values or corrupted its tail");
}
}
int main() {
    try {
        auto device = createD3D11FilterDevice();
        {
            auto scope = device->activate();
            guided(device.get(), 64, 48, .1f);
            const auto warm = d3d11_test::filterAllocations;
            require(warm >= 6, "D3D11 allocation instrumentation did not observe native buffers");
            guided(device.get(), 64, 48, .7f);
            guided(device.get(), 23, 17, .3f);
            guided(device.get(), 64, 48, .2f);
            require(d3d11_test::filterAllocations == warm, "C21: guided tiles reallocated warmed buffers");
        }
        const int initializations = d3d11_test::filterInitializations;
        guided(nullptr, 64, 48, .2f);
        const auto warm = d3d11_test::filterAllocations;
        guided(nullptr, 23, 17, .6f);
        guided(nullptr, 64, 48, .4f);
        require(d3d11_test::filterInitializations == initializations + 1,
            "C21: process-level filter owner recreated the device");
        require(d3d11_test::filterAllocations == warm, "C21: process-level pool did not survive calls");
        {
            auto scope = device->activate();
            std::vector<FilterBufferPtr> held;
            for (int i = 0; i < 24; ++i) held.push_back(device->allocate(9 * 1024 * 1024 / sizeof(float)));
            held.clear();
        }
        require(d3d11_test::idleFilterFloats > 0 && d3d11_test::idleFilterFloats <= 16 * 1024 * 1024,
            "C21: D3D11 idle pool exceeds 64 MiB after context release");
        {
            auto scope = device->activate();
            const auto warm = d3d11_test::filterAllocations;
            constexpr size_t count = 1024 * 1024 / sizeof(float);
            std::vector<float> input(count, 6.25f), output(count, -1);
            auto buffer = device->allocate(count, input.data());
            device->read(*buffer, count, output.data());
            require(output == input, "C21: best-fit buffer prefix upload/readback corrupted data");
            require(d3d11_test::filterAllocations == warm, "C21: best-fit reuse allocated a new buffer");
        }
        std::cout << "PASS: D3D11 guided reuse, tail overwrite, shared owner and 64 MiB idle budget (WARP)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
