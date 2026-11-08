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

// The coordinate field is shared by the display-sRGB and extended-linear
// finishers. A strip uses the full output dimensions and absolute coordinates.
class PhotoEffectSampler {
    PhotoEffectsOptions options_;
    float centerX_, centerY_, axisX_, axisY_, power_, inner_, transition_;
    float grainScale_, rough_, grainNormalization_;
    float vignetteGain(int x, int y, float luminance) const;
    float grainNoise(int x, int y) const;
public:
    PhotoEffectSampler(const PhotoEffectsOptions& options, int width, int height);
    RGB applySRGB(RGB pixel, int x, int y) const;
    RGB applyExtendedLinear(RGB pixel, int x, int y, double peak) const;
};

// Display-sRGB finishing at source resolution, after sharpening and before resize.
void applyPhotoEffects(ImageData& image, const PhotoEffectsOptions& options);

} // namespace sony2fuji
