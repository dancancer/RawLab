#include "photo_selective_color.h"
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

void applySelectiveColor(ImageData&, const SelectiveColorOptions& options) {
    // Wave 0 contract freeze: zero-value exact bypass and no-op stub until Wave 1 math.
    if (!options.valid() || !options.active()) return;
}

} // namespace sony2fuji
