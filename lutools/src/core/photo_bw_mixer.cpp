#include "photo_bw_mixer.h"
#include <cmath>

namespace sony2fuji {

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

void applyBwMixer(ImageData&, const BwMixerOptions& options) {
    // Wave 0 contract freeze: disabled bypass and no-op stub until Wave 1 math.
    if (!options.valid() || !options.active()) return;
}

} // namespace sony2fuji
