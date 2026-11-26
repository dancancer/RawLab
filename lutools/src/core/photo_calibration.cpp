#include "photo_calibration.h"
#include <cmath>

namespace sony2fuji {

bool CameraCalibrationOptions::valid() const {
    for (float v : {shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation}) {
        if (!std::isfinite(v) || v < -100.0f || v > 100.0f) return false;
    }
    return true;
}

void applyCameraCalibration(ImageData&, const CameraCalibrationOptions& options) {
    // Wave 0 contract freeze: zero-value exact bypass and no-op stub until Wave 1 math.
    if (!options.valid() || !options.active()) return;
}

} // namespace sony2fuji
