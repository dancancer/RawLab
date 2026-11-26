#include "photo_defringe.h"
#include <cmath>

namespace sony2fuji {

bool DefringeOptions::valid() const {
    for (float v : {purpleAmount, greenAmount}) {
        if (!std::isfinite(v) || v < 0.0f || v > 20.0f) return false;
    }
    for (float v : {purpleHue, greenHue}) {
        if (!std::isfinite(v) || v < 0.0f || v > 100.0f) return false;
    }
    return true;
}

void applyDefringe(ImageData&, const DefringeOptions& options) {
    // Wave 0 contract freeze: exact zero-value bypass and no-op stub until Wave 1 math.
    if (!options.valid() || !options.active()) return;
}

} // namespace sony2fuji
