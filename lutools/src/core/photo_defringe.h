#pragma once

#include "sony2fuji/common.h"

namespace sony2fuji {

struct DefringeOptions {
    float purpleAmount = 0.0f; // [0, 20]
    float purpleHue = 50.0f;   // [0, 100]
    float greenAmount = 0.0f;  // [0, 20]
    float greenHue = 50.0f;    // [0, 100]

    bool valid() const;
    bool active() const { return purpleAmount > 0.0f || greenAmount > 0.0f; }
    bool isDefault() const {
        return purpleAmount == 0.0f && purpleHue == 50.0f &&
               greenAmount == 0.0f && greenHue == 50.0f;
    }

    bool operator==(const DefringeOptions& other) const {
        return purpleAmount == other.purpleAmount && purpleHue == other.purpleHue &&
               greenAmount == other.greenAmount && greenHue == other.greenHue;
    }
};

void applyDefringe(ImageData& image, const DefringeOptions& options);

} // namespace sony2fuji
