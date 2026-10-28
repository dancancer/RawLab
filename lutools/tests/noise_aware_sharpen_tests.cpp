#include "core/noise_aware_sharpen.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>

using namespace sony2fuji;

namespace {
bool identical(const ImageData& a, const ImageData& b) {
    return a.width == b.width && a.height == b.height && a.pixels.size() == b.pixels.size() &&
        std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(RGB)) == 0;
}

ImageData edge(int width = 131, int height = 65) {
    ImageData image(width, height);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        const float value = .5f + .3f * std::erf((x - width / 2.f) / 1.41421356f);
        image.at(x, y) = RGB(value, value, value);
    }
    return image;
}

void validation() {
    ImageData image = edge(), before = image;
    for (float amount : {-1.f, 2.01f, std::numeric_limits<float>::infinity()}) {
        assert(applyNoiseAwareSharpen(image, amount) == ErrorCode::InvalidFormat);
        assert(identical(image, before));
    }
    image.pixels[0].r = std::numeric_limits<float>::quiet_NaN();
    before = image;
    assert(applyNoiseAwareSharpen(image, 0) == ErrorCode::InvalidFormat);
    assert(identical(image, before));
    image = edge(); image.width++;
    before = image;
    assert(applyNoiseAwareSharpen(image, 1) == ErrorCode::InvalidFormat);
    assert(identical(image, before));
    ImageData empty;
    assert(applyNoiseAwareSharpen(empty, 1) == ErrorCode::InvalidFormat);
    image = edge(); before = image;
    assert(applyNoiseAwareSharpen(image, 1, nullptr, static_cast<GpuMode>(99)) == ErrorCode::InvalidFormat);
    assert(identical(image, before));
}

void bypass() {
    ImageData image(2, 1);
    image.pixels = {RGB(-.5f, -0.f, 1.5f), RGB(.125f, .75f, 2.f)};
    const ImageData before = image;
    NoiseAwareSharpenDiagnostics info;
    for (auto mode : {GpuMode::Off, GpuMode::Auto, GpuMode::Force}) {
        assert(applyNoiseAwareSharpen(image, 0, &info, mode) == ErrorCode::Success);
        assert(identical(image, before) && !info.applied && !info.gpuUsed);
    }
}

void behavior(GpuMode mode) {
    for (auto size : {std::pair<int, int>{1, 1}, {1, 9}, {9, 1}, {17, 19}}) {
        ImageData image(size.first, size.second);
        std::fill(image.pixels.begin(), image.pixels.end(), RGB(.3f, .5f, .8f));
        const auto before = image;
        assert(applyNoiseAwareSharpen(image, 2, nullptr, mode) == ErrorCode::Success);
        assert(identical(image, before));
    }
    const auto source = edge();
    auto strong = source, half = source;
    NoiseAwareSharpenDiagnostics info;
    assert(applyNoiseAwareSharpen(strong, 2, &info, mode) == ErrorCode::Success);
    assert(info.applied && info.gpuUsed == (mode == GpuMode::Force));
    assert(!identical(strong, source));
    assert(applyNoiseAwareSharpen(half, 1, nullptr, mode) == ErrorCode::Success);
    for (size_t i = 0; i < source.pixels.size(); ++i) {
        assert(std::abs(half.pixels[i].r - (source.pixels[i].r + strong.pixels[i].r) * .5f) < 1e-7f);
        assert(strong.pixels[i].r >= 0 && strong.pixels[i].r <= 1);
        assert(strong.pixels[i].r == strong.pixels[i].g && strong.pixels[i].r == strong.pixels[i].b);
    }
    auto clipped = source;
    for (auto& pixel : clipped.pixels) pixel.r = 1;
    const auto before = clipped;
    assert(applyNoiseAwareSharpen(clipped, 2, nullptr, mode) == ErrorCode::Success);
    assert(identical(clipped, before));
    auto cpu = source;
    assert(applyNoiseAwareSharpen(cpu, 2) == ErrorCode::Success);
    for (size_t i = 0; i < source.pixels.size(); ++i)
        assert(std::abs(cpu.pixels[i].r - strong.pixels[i].r) <= 2e-6f);
}
} // namespace

int main(int argc, char**) {
    validation(); bypass();
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    assert(noiseAwareSharpenAvailable());
    behavior(GpuMode::Off);
    if (argc > 1) behavior(GpuMode::Force);
#ifndef SONY2FUJI_ENABLE_METAL
    auto source = edge(), cpu = source, automatic = source, forced = source;
    assert(applyNoiseAwareSharpen(cpu, 2) == ErrorCode::Success);
    NoiseAwareSharpenDiagnostics info;
    assert(applyNoiseAwareSharpen(automatic, 2, &info, GpuMode::Auto) == ErrorCode::Success);
    assert(identical(cpu, automatic) && !info.gpuUsed);
    assert(applyNoiseAwareSharpen(forced, 2, &info, GpuMode::Force) == ErrorCode::ProcessingError);
    assert(identical(forced, source) && !info.gpuUsed && !info.applied);
#endif
#else
    assert(!noiseAwareSharpenAvailable());
    auto image = edge(), before = image;
    assert(applyNoiseAwareSharpen(image, 1) == ErrorCode::ProcessingError);
    assert(identical(image, before));
#endif
    std::cout << "noise-aware sharpen contract passed\n";
}
