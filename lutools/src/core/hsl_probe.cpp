#include "core/hsl_probe.h"

#include "core/hdr_rendering.h"
#include "core/photo_color.h"

#include <algorithm>
#include <cmath>

namespace sony2fuji {

HslProbeSampleResult sampleHslProbe(
    const HslProbeData& probe,
    uint64_t sourceRevision,
    uint64_t requestRevision,
    float x,
    float y
) {
    HslProbeSampleResult result;
    result.sourceRevision = probe.sourceRevision;
    result.requestRevision = probe.requestRevision;
    result.width = static_cast<uint32_t>(probe.image.width);
    result.height = static_cast<uint32_t>(probe.image.height);
    result.quality = probe.quality;

    if (sourceRevision != probe.sourceRevision || requestRevision != probe.requestRevision) {
        result.availability = HslProbeAvailability::Stale;
        return result;
    }
    if (!std::isfinite(x) || !std::isfinite(y) || x < 0.0f || x > 1.0f || y < 0.0f || y > 1.0f) {
        result.availability = HslProbeAvailability::Outside;
        return result;
    }

    const auto& image = probe.image;
    const double px = double(x) * (image.width - 1);
    const double py = double(y) * (image.height - 1);
    const int left = static_cast<int>(px);
    const int top = static_cast<int>(py);
    const int right = std::min(left + 1, image.width - 1);
    const int bottom = std::min(top + 1, image.height - 1);
    const float dx = static_cast<float>(px - left);
    const float dy = static_cast<float>(py - top);
    const auto mix = [hdr = probe.hdr](const RGB& a, const RGB& b, float t) {
        if (hdr) {
            const auto channel = [t](float leftVal, float rightVal) {
                return float(leftVal + (double(rightVal) - leftVal) * t);
            };
            return RGB(channel(a.r, b.r), channel(a.g, b.g), channel(a.b, b.b));
        }
        return RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t);
    };
    const auto pixel = mix(
        mix(image.at(left, top), image.at(right, top), dx),
        mix(image.at(left, bottom), image.at(right, bottom), dx),
        dy
    );
    if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b)) {
        result.availability = HslProbeAvailability::NonFinite;
        return result;
    }
    result.rgb = {pixel.r, pixel.g, pixel.b};
    const auto color = probe.hdr ? analyzeHDRColor(pixel) : analyzeHslColor(pixel);
    if (!color.valid || color.spread < 1.0f / 255.0f) {
        result.availability = HslProbeAvailability::NearGray;
        return result;
    }
    result.hsl = {color.hue, std::clamp(color.saturation, 0.0f, 1.0f), color.lightness};
    result.weights = color.weights();
    result.availability = HslProbeAvailability::Available;
    return result;
}

} // namespace sony2fuji
