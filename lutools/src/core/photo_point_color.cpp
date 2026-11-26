#include "photo_point_color.h"
#include <cmath>

namespace sony2fuji {

bool PointColorSwatch::valid() const {
    if (!std::isfinite(srcHue) || srcHue < 0.0f || srcHue >= 360.0f) return false;
    for (float v : {srcSaturation, srcLuminance}) {
        if (!std::isfinite(v) || v < 0.0f || v > 1.0f) return false;
    }
    for (float v : {hueShift, saturationShift, luminanceShift, variance}) {
        if (!std::isfinite(v) || v < -100.0f || v > 100.0f) return false;
    }
    for (float v : {range, hueRange, satRange, lumRange}) {
        if (!std::isfinite(v) || v < 0.0f || v > 100.0f) return false;
    }
    return true;
}

bool PointColorOptions::valid() const {
    if (swatchCount > kPointColorMaxSwatches) return false;
    for (uint32_t i = 0; i < swatchCount; ++i) {
        if (!swatches[i].valid()) return false;
    }
    return true;
}

bool PointColorOptions::active() const {
    for (uint32_t i = 0; i < swatchCount; ++i) {
        if (swatches[i].active()) return true;
    }
    return false;
}

void applyPointColor(ImageData&, const PointColorOptions& options) {
    // Wave 0 contract freeze: zero-value exact bypass and no-op stub until Wave 1 math.
    if (!options.valid() || !options.active()) return;
}

} // namespace sony2fuji
