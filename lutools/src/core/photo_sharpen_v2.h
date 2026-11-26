#pragma once

#include "sony2fuji/common.h"

namespace sony2fuji {

struct SharpenV2Options {
    bool luminanceV2 = false;
    float radius = 1.0f;   // [0.5, 3.0]
    float detail = 25.0f;  // [0, 100]
    float masking = 0.0f;  // [0, 100]

    bool valid() const;
    bool active() const { return luminanceV2; }
    bool isDefault() const {
        return !luminanceV2 && radius == 1.0f && detail == 25.0f && masking == 0.0f;
    }

    bool operator==(const SharpenV2Options& other) const {
        return luminanceV2 == other.luminanceV2 && radius == other.radius &&
               detail == other.detail && masking == other.masking;
    }
};

void applySharpenV2(ImageData& image, float amount, const SharpenV2Options& options);

} // namespace sony2fuji
