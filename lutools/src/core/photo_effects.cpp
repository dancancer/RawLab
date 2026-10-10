#include "photo_effects.h"
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace sony2fuji {

bool PhotoEffectsOptions::valid() const {
    for (float value : {vignetteAmount, vignetteRoundness})
        if (!std::isfinite(value) || value < -100 || value > 100) return false;
    for (float value : {vignetteMidpoint, vignetteFeather, vignetteHighlights,
                       grainAmount, grainSize, grainRoughness})
        if (!std::isfinite(value) || value < 0 || value > 100) return false;
    return true;
}

namespace {

float smooth(float value) {
    value = std::clamp(value, 0.f, 1.f);
    return value * value * (3 - 2 * value);
}

uint32_t hash(uint32_t value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

// Fixed spatial noise: no mutable RNG, frame time, thread order or output-size seed.
float normal(int x, int y, uint32_t seed) {
    const uint32_t a = hash(uint32_t(x) ^ hash(uint32_t(y) + seed));
    const uint32_t b = hash(a ^ 0x9e3779b9u);
    return (float((a & 65535u) + (a >> 16) + (b & 65535u) + (b >> 16)) /
        65535.f - 2.f) * 1.7320508f;
}

float correlatedNoise(float x, float y, uint32_t seed) {
    const int ix = static_cast<int>(std::floor(x)), iy = static_cast<int>(std::floor(y));
    const float fx = smooth(x - ix), fy = smooth(y - iy);
    const float top = normal(ix, iy, seed) * (1 - fx) + normal(ix + 1, iy, seed) * fx;
    const float bottom = normal(ix, iy + 1, seed) * (1 - fx) + normal(ix + 1, iy + 1, seed) * fx;
    // Normalize interpolation variance so cell boundaries do not form a texture grid.
    const float variance = ((1 - fx) * (1 - fx) + fx * fx) * ((1 - fy) * (1 - fy) + fy * fy);
    return (top * (1 - fy) + bottom * fy) / std::sqrt(variance);
}

float luminance(const RGB& pixel) {
    return std::clamp(0.2126f * pixel.r + 0.7152f * pixel.g + 0.0722f * pixel.b, 0.f, 1.f);
}

} // namespace

void applyPhotoEffects(ImageData& image, const PhotoEffectsOptions& options) {
    if (!options.active() || image.width <= 0 || image.height <= 0) return;
    const float circle = std::max(0.f, options.vignetteRoundness / 100);
    const float shortSide = float(std::min(image.width, image.height));
    const float axisX = (image.width * (1 - circle) + shortSide * circle) * 0.5f;
    const float axisY = (image.height * (1 - circle) + shortSide * circle) * 0.5f;
    const float power = 2 + std::max(0.f, -options.vignetteRoundness / 100) * 6;
    const float radius = 0.35f + options.vignetteMidpoint * 0.01f;
    const float feather = options.vignetteFeather / 100;
    const float inner = radius * (1 - feather * 0.8f);
    const float outer = radius + feather * 0.4f;
    const float transition = std::max(outer - inner, 2.f / shortSide);
    const float grainScale = 0.7f + options.grainSize * 0.055f;
    const float rough = options.grainRoughness * 0.007f;
    const float grainNormalization = 1 / std::sqrt((1 - rough) * (1 - rough) + rough * rough);

#ifdef _OPENMP
#pragma omp parallel for if (image.pixels.size() >= (1u << 16))
#endif
    for (int y = 0; y < image.height; ++y) {
        for (int x = 0; x < image.width; ++x) {
            auto& pixel = image.pixels[size_t(y) * image.width + x];
            if (options.vignetteAmount != 0) {
                const float nx = std::abs((x + 0.5f - image.width * 0.5f) / axisX);
                const float ny = std::abs((y + 0.5f - image.height * 0.5f) / axisY);
                const float distance = power == 2 ? std::sqrt(nx * nx + ny * ny) :
                    std::pow(std::pow(nx, power) + std::pow(ny, power), 1 / power);
                float mask = smooth((distance - inner) / transition);
                if (options.vignetteAmount < 0)
                    mask *= 1 - options.vignetteHighlights / 100 * smooth((luminance(pixel) - 0.5f) * 2);
                const float gain = std::exp2(-std::abs(options.vignetteAmount) * 0.03f * mask);
                const auto shade = [&](float value) {
                    return options.vignetteAmount < 0 ? value * gain : 1 - (1 - value) * gain;
                };
                pixel = {shade(pixel.r), shade(pixel.g), shade(pixel.b)};
            }
            if (options.grainAmount > 0) {
                const float u = (x + 0.5f) / grainScale, v = (y + 0.5f) / grainScale;
                const float fine = correlatedNoise(u, v, 0x243f6a88u);
                const float coarse = correlatedNoise(u * 0.47f + 17.3f, v * 0.47f + 31.7f, 0x85a308d3u);
                const float noise = ((1 - rough) * fine + rough * coarse) * grainNormalization;
                const float luma = luminance(pixel);
                const float delta = noise * options.grainAmount * 0.0012f * std::sqrt(4 * luma * (1 - luma));
                pixel = {std::clamp(pixel.r + delta, 0.f, 1.f),
                         std::clamp(pixel.g + delta, 0.f, 1.f), std::clamp(pixel.b + delta, 0.f, 1.f)};
            }
        }
    }
}

} // namespace sony2fuji
