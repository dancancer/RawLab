#include "photo_sharpen_v2.h"
#include <cmath>

namespace sony2fuji {

bool SharpenV2Options::valid() const {
    if (!std::isfinite(radius) || radius < 0.5f || radius > 3.0f) return false;
    if (!std::isfinite(detail) || detail < 0.0f || detail > 100.0f) return false;
    if (!std::isfinite(masking) || masking < 0.0f || masking > 100.0f) return false;
    return true;
}

void applySharpenV2(ImageData&, float amount, const SharpenV2Options& options) {
    // Wave 0 contract freeze: exact bypass when luminanceV2 is off or amount == 0.
    if (!options.valid() || !options.active() || !std::isfinite(amount) || amount <= 0.0f) return;
}

} // namespace sony2fuji
