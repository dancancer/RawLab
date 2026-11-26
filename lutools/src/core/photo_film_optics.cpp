#include "photo_film_optics.h"
#include <cmath>

namespace sony2fuji {

bool FilmOpticsOptions::valid() const {
    for (float v : {halationAmount, halationThreshold, halationRadius, bloomAmount, bloomThreshold, bloomRadius}) {
        if (!std::isfinite(v) || v < 0.0f || v > 100.0f) return false;
    }
    if (!std::isfinite(halationHue) || halationHue < -100.0f || halationHue > 100.0f) return false;
    return true;
}

void applyFilmOptics(ImageData&, const FilmOpticsOptions& options) {
    // Wave 0 contract freeze: exact zero-value bypass and no-op stub until Wave 1 math.
    if (!options.valid() || !options.active()) return;
}

} // namespace sony2fuji
