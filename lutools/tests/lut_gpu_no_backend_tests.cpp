#include "sony2fuji/gpu/lut_gpu.h"
#include "sony2fuji/lut_parser.h"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
#error "lut_gpu_no_backend_tests must compile without Metal, GLES, or D3D11"
#endif

namespace {

int failures = 0;

void require(bool condition, const char* message) {
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

bool pixelsEqual(const std::vector<sony2fuji::RGB>& a, const std::vector<sony2fuji::RGB>& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (a[i].r != b[i].r || a[i].g != b[i].g || a[i].b != b[i].b) return false;
    }
    return true;
}

bool nearPixel(const sony2fuji::RGB& actual, const sony2fuji::RGB& expected, float tol = 1e-4f) {
    return std::fabs(actual.r - expected.r) <= tol &&
           std::fabs(actual.g - expected.g) <= tol &&
           std::fabs(actual.b - expected.b) <= tol;
}

std::shared_ptr<sony2fuji::LUT3D> makeCubeLUT(const std::string& header, bool vlt) {
    const int grid = vlt ? 17 : 2;
    std::string data = header;
    data += "LUT_3D_SIZE " + std::to_string(grid) + "\n";
    for (int b = 0; b < grid; ++b) {
        for (int g = 0; g < grid; ++g) {
            for (int r = 0; r < grid; ++r) {
                if (vlt) {
                    data += std::to_string(std::min(r * 256, 4095)) + " " +
                            std::to_string(std::min(g * 256, 4095)) + " " +
                            std::to_string(std::min(b * 256, 4095)) + "\n";
                } else {
                    data += std::to_string(b) + " " + std::to_string(g) + " " + std::to_string(r) + "\n";
                }
            }
        }
    }
    auto lut = std::make_shared<sony2fuji::LUT3D>();
    require(lut->loadFromData(data, vlt) == sony2fuji::ErrorCode::Success, "Load synthetic LUT from memory");
    return lut;
}

} // namespace

int main() {
    const auto gpuEligibleLut = makeCubeLUT("", false);
    require(gpuEligibleLut && gpuEligibleLut->isValid() && !gpuEligibleLut->requiresCPU(),
            "Plain 3D cube does not require CPU");

    sony2fuji::ImageData image;
    image.width = 2;
    image.height = 1;
    image.pixels = {{0.2f, 0.5f, 0.8f}, {0.9f, 0.1f, 0.3f}};
    const auto originalPixels = image.pixels;

    require(sony2fuji::applyLUTWithConfig(gpuEligibleLut, image, {sony2fuji::GpuMode::Force}) ==
                sony2fuji::ErrorCode::Unsupported,
            "No-backend build returns Unsupported under Force for standalone LUT");
    require(pixelsEqual(image.pixels, originalPixels),
            "Unsupported Force leaves image pixels unchanged");

    auto autoImage = image;
    require(sony2fuji::applyLUTWithConfig(gpuEligibleLut, autoImage, {sony2fuji::GpuMode::Auto}) ==
                sony2fuji::ErrorCode::Success,
            "No-backend build falls back to CPU under Auto");
    auto cpuRef = image;
    require(sony2fuji::applyLUTWithConfig(gpuEligibleLut, cpuRef, {sony2fuji::GpuMode::Off}) ==
                sony2fuji::ErrorCode::Success,
            "CPU Off mode succeeds");
    require(nearPixel(autoImage.pixels[0], {0.8f, 0.5f, 0.2f}) &&
                nearPixel(autoImage.pixels[1], {0.3f, 0.1f, 0.9f}) &&
                pixelsEqual(autoImage.pixels, cpuRef.pixels),
            "Auto fallback matches CPU reference");

    const auto cpuOnlyLut = makeCubeLUT("# panasonic vlt file version 1.0\n# source vlt file \"\"\n", true);
    require(cpuOnlyLut && cpuOnlyLut->isValid() && cpuOnlyLut->requiresCPU(),
            "VLT LUT marks requiresCPU()");

    auto cpuOnlyForce = image;
    require(sony2fuji::applyLUTWithConfig(cpuOnlyLut, cpuOnlyForce, {sony2fuji::GpuMode::Force}) ==
                sony2fuji::ErrorCode::Unsupported,
            "CPU-only LUT returns Unsupported under Force");
    require(pixelsEqual(cpuOnlyForce.pixels, originalPixels),
            "CPU-only LUT Force failure leaves pixels unchanged");

    auto cpuOnlyAuto = image;
    require(sony2fuji::applyLUTWithConfig(cpuOnlyLut, cpuOnlyAuto, {sony2fuji::GpuMode::Auto}) ==
                sony2fuji::ErrorCode::Success,
            "CPU-only LUT succeeds under Auto");

    return failures ? 1 : 0;
}
