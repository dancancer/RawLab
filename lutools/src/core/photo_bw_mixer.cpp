#include "photo_bw_mixer.h"
#include "core/parallel_pixels.h"
#include <algorithm>
#include <array>
#include <cmath>

namespace sony2fuji {

namespace {

constexpr std::array<float, kBwMixerChannelCount + 1> kHueCenters = {
    0.0f, 30.0f, 60.0f, 120.0f, 180.0f, 240.0f, 270.0f, 300.0f, 360.0f
};

} // namespace

bool BwMixerOptions::valid() const {
    for (float w : weights) {
        if (!std::isfinite(w) || w < -100.0f || w > 100.0f) return false;
    }
    return true;
}

bool BwMixerOptions::isDefault() const {
    if (enabled) return false;
    for (float w : weights) {
        if (w != 0.0f) return false;
    }
    return true;
}

RGB applyBwMixerPixel(const RGB& pixel, const BwMixerOptions& options) {
    if (!options.active()) return pixel;

    const float r = pixel.r;
    const float g = pixel.g;
    const float b = pixel.b;
    const float baseY = 0.2126f * r + 0.7152f * g + 0.0722f * b;

    const float maxC = std::max({r, g, b});
    const float minC = std::min({r, g, b});
    const float delta = maxC - minC;
    if (delta <= 1e-5f) {
        const float y = std::clamp(baseY, 0.0f, 1.0f);
        return RGB(y, y, y);
    }

    float hue = 0.0f;
    if (maxC == r) {
        hue = 60.0f * std::fmod((g - b) / delta + 6.0f, 6.0f);
    } else if (maxC == g) {
        hue = 60.0f * ((b - r) / delta + 2.0f);
    } else {
        hue = 60.0f * ((r - g) / delta + 4.0f);
    }
    if (hue < 0.0f) hue += 360.0f;
    if (hue >= 360.0f) hue -= 360.0f;

    size_t lower = 0;
    while (lower < kBwMixerChannelCount - 1 && hue >= kHueCenters[lower + 1]) ++lower;
    const size_t upper = (lower + 1) % kBwMixerChannelCount;
    float t = (hue - kHueCenters[lower]) / (kHueCenters[lower + 1] - kHueCenters[lower]);
    t = t * t * (3.0f - 2.0f * t);

    const float channelWeight = options.weights[lower] * (1.0f - t) + options.weights[upper] * t;
    const float shiftedY = baseY + (channelWeight * 0.01f) * std::min(1.0f, delta) * 0.5f;
    const float outY = std::clamp(shiftedY, 0.0f, 1.0f);
    return RGB(outY, outY, outY);
}

void applyBwMixer(ImageData& image, const BwMixerOptions& options) {
    if (!options.valid() || !options.active()) return;

    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            image.pixels[i] = applyBwMixerPixel(image.pixels[i], options);
        }
    });
}

} // namespace sony2fuji
