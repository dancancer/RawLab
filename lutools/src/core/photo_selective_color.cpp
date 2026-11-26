#include "photo_selective_color.h"
#include "core/parallel_pixels.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji {

bool SelectiveColorBand::valid() const {
    for (float v : {cyan, magenta, yellow, black}) {
        if (!std::isfinite(v) || v < -100.0f || v > 100.0f) return false;
    }
    return true;
}

bool SelectiveColorOptions::valid() const {
    if (method != SelectiveColorMethod::Relative && method != SelectiveColorMethod::Absolute) return false;
    for (const auto& band : bands) {
        if (!band.valid()) return false;
    }
    return true;
}

bool SelectiveColorOptions::active() const {
    for (const auto& band : bands) {
        if (band.active()) return true;
    }
    return false;
}

RGB applySelectiveColorPixel(const RGB& pixel, const SelectiveColorOptions& options) {
    if (!options.active()) return pixel;

    const float r = std::clamp(pixel.r, 0.0f, 1.0f);
    const float g = std::clamp(pixel.g, 0.0f, 1.0f);
    const float b = std::clamp(pixel.b, 0.0f, 1.0f);

    const float maxC = std::max({r, g, b});
    const float minC = std::min({r, g, b});
    const float midC = r + g + b - maxC - minC;

    float weights[kSelectiveColorBandCount]{};
    // 0: reds, 1: yellows, 2: greens, 3: cyans, 4: blues, 5: magentas
    weights[0] = (r >= g && r >= b) ? (r - midC) : 0.0f;
    weights[1] = (b <= r && b <= g) ? (midC - b) : 0.0f;
    weights[2] = (g >= r && g >= b) ? (g - midC) : 0.0f;
    weights[3] = (r <= g && r <= b) ? (midC - r) : 0.0f;
    weights[4] = (b >= r && b >= g) ? (b - midC) : 0.0f;
    weights[5] = (g <= r && g <= b) ? (midC - g) : 0.0f;
    // 6: whites, 7: neutrals, 8: blacks
    weights[6] = minC > 0.5f ? (minC - 0.5f) * 2.0f : 0.0f;
    weights[7] = std::max(0.0f, 1.0f - std::abs(maxC - 0.5f) - std::abs(minC - 0.5f));
    weights[8] = maxC < 0.5f ? (0.5f - maxC) * 2.0f : 0.0f;

    float dC = 0.0f;
    float dM = 0.0f;
    float dY = 0.0f;
    for (size_t i = 0; i < kSelectiveColorBandCount; ++i) {
        const float w = weights[i];
        const auto& band = options.bands[i];
        if (w <= 0.0f || !band.active()) continue;
        const float kc = band.cyan * 0.01f;
        const float km = band.magenta * 0.01f;
        const float ky = band.yellow * 0.01f;
        const float kk = band.black * 0.01f;
        dC -= w * (kc + kk);
        dM -= w * (km + kk);
        dY -= w * (ky + kk);
    }

    if (options.method == SelectiveColorMethod::Relative) {
        dC *= std::min(r, 1.0f - r);
        dM *= std::min(g, 1.0f - g);
        dY *= std::min(b, 1.0f - b);
    }

    return RGB(
        std::clamp(r + dC, 0.0f, 1.0f),
        std::clamp(g + dM, 0.0f, 1.0f),
        std::clamp(b + dY, 0.0f, 1.0f)
    );
}

void applySelectiveColor(ImageData& image, const SelectiveColorOptions& options) {
    if (!options.valid() || !options.active()) return;

    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            image.pixels[i] = applySelectiveColorPixel(image.pixels[i], options);
        }
    });
}

} // namespace sony2fuji
