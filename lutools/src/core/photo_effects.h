#pragma once

#include "sony2fuji/common.h"

namespace sony2fuji {

struct PhotoEffectsOptions {
    float vignetteAmount = 0;
    float vignetteMidpoint = 50;
    float vignetteRoundness = 0;
    float vignetteFeather = 50;
    float vignetteHighlights = 0;
    float grainAmount = 0;
    float grainSize = 25;
    float grainRoughness = 50;

    bool active() const { return vignetteAmount != 0 || grainAmount != 0; }
    bool valid() const;
};

// Display-sRGB finishing at source resolution, after sharpening and before resize.
void applyPhotoEffects(ImageData& image, const PhotoEffectsOptions& options);

} // namespace sony2fuji
