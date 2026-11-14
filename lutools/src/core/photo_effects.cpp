#include "photo_effects.h"
#include "parallel_pixels.h"
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

float sdrLuminance(const RGB& pixel) {
    return std::clamp(0.2126f * pixel.r + 0.7152f * pixel.g + 0.0722f * pixel.b, 0.f, 1.f);
}

double linearLuminance(const RGB& pixel) {
    return .2126 * pixel.r + .7152 * pixel.g + .0722 * pixel.b;
}

} // namespace

PhotoEffectSampler::PhotoEffectSampler(const PhotoEffectsOptions& options, int width, int height)
    : options_(options), centerX_(width * .5f), centerY_(height * .5f) {
    const float circle = std::max(0.f, options.vignetteRoundness / 100);
    const float shortSide = float(std::min(width, height));
    axisX_ = (width * (1 - circle) + shortSide * circle) * .5f;
    axisY_ = (height * (1 - circle) + shortSide * circle) * .5f;
    power_ = 2 + std::max(0.f, -options.vignetteRoundness / 100) * 6;
    const float radius = 0.35f + options.vignetteMidpoint * 0.01f;
    const float feather = options.vignetteFeather / 100;
    inner_ = radius * (1 - feather * 0.8f);
    const float outer = radius + feather * 0.4f;
    transition_ = std::max(outer - inner_, 2.f / shortSide);
    grainScale_ = 0.7f + options.grainSize * 0.055f;
    rough_ = options.grainRoughness * 0.007f;
    grainNormalization_ = 1 / std::sqrt((1 - rough_) * (1 - rough_) + rough_ * rough_);
}

float PhotoEffectSampler::vignetteGain(int x, int y, float luminance) const {
    const float nx = std::abs((x + .5f - centerX_) / axisX_);
    const float ny = std::abs((y + .5f - centerY_) / axisY_);
    const float distance = power_ == 2 ? std::sqrt(nx * nx + ny * ny) :
        std::pow(std::pow(nx, power_) + std::pow(ny, power_), 1 / power_);
    float mask = smooth((distance - inner_) / transition_);
    if (options_.vignetteAmount < 0)
        mask *= 1 - options_.vignetteHighlights / 100 * smooth((luminance - .5f) * 2);
    return std::exp2(-std::abs(options_.vignetteAmount) * .03f * mask);
}

float PhotoEffectSampler::grainNoise(int x, int y) const {
    const float u = (x + .5f) / grainScale_, v = (y + .5f) / grainScale_;
    const float fine = correlatedNoise(u, v, 0x243f6a88u);
    const float coarse = correlatedNoise(u * .47f + 17.3f, v * .47f + 31.7f, 0x85a308d3u);
    return ((1 - rough_) * fine + rough_ * coarse) * grainNormalization_;
}

RGB PhotoEffectSampler::applySRGB(RGB pixel, int x, int y) const {
    if (options_.vignetteAmount != 0) {
        const float gain = vignetteGain(x, y, sdrLuminance(pixel));
        const auto shade = [&](float value) {
            return options_.vignetteAmount < 0 ? value * gain : 1 - (1 - value) * gain;
        };
        pixel = {shade(pixel.r), shade(pixel.g), shade(pixel.b)};
    }
    if (options_.grainAmount > 0) {
        const float luma = sdrLuminance(pixel);
        const float delta = grainNoise(x, y) * options_.grainAmount * .0012f * std::sqrt(4 * luma * (1 - luma));
        pixel = {std::clamp(pixel.r + delta, 0.f, 1.f),
            std::clamp(pixel.g + delta, 0.f, 1.f), std::clamp(pixel.b + delta, 0.f, 1.f)};
    }
    return pixel;
}

RGB PhotoEffectSampler::applyExtendedLinear(RGB pixel, int x, int y, double peak) const {
    if (options_.vignetteAmount != 0) {
        const double luma = linearLuminance(pixel);
        const float gain = vignetteGain(x, y, float(std::clamp(luma, 0., 1.)));
        if (options_.vignetteAmount < 0) pixel = {pixel.r * gain, pixel.g * gain, pixel.b * gain};
        else if (luma < 1) {
            const float mix = (1 - gain) * (1 - smooth(float((luma - .5) * 2)));
            pixel = {pixel.r * (1 - mix) + mix, pixel.g * (1 - mix) + mix, pixel.b * (1 - mix) + mix};
        }
    }
    if (options_.grainAmount > 0) {
        const double luma = linearLuminance(pixel);
        if (luma > 0) {
            const double envelope = 2 * std::sqrt(luma) / (1 + luma);
            const float gain = float(std::exp2(grainNoise(x, y) * options_.grainAmount * .002 * envelope));
            pixel = {pixel.r * gain, pixel.g * gain, pixel.b * gain};
        }
    }
    if (peak > 0) {
        const double luma = linearLuminance(pixel);
        if (luma > peak) {
            const double gain = peak / luma;
            pixel = {float(pixel.r * gain), float(pixel.g * gain), float(pixel.b * gain)};
        }
    }
    return pixel;
}

void applyPhotoEffects(ImageData& image, const PhotoEffectsOptions& options) {
    if (!options.active() || image.width <= 0 || image.height <= 0) return;
    const PhotoEffectSampler sampler(options, image.width, image.height);
    parallelRowRanges(image.height, image.width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            for (int x = 0; x < image.width; ++x) {
                image.at(x, y) = sampler.applySRGB(image.at(x, y), x, y);
            }
        }
    });
}

} // namespace sony2fuji
