#pragma once

#include "core/photo_effects.h"

namespace sony2fuji {

struct WaveletFilterSettings {
    int depth = 4;
    float sigma[18] = {};
    float thresholdScale[6] = {};
};

// Native backend filtering. A failed operation leaves caller output unchanged.
bool gpuWaveletFilter(const float* input, int width, int height,
                      const WaveletFilterSettings& settings, float* output);
bool gpuGuidedFilter(const float* guide, const float* input, int width, int height,
                     int radius, float epsilon, float* output);
bool gpuPhotoEffects(ImageData& image, const PhotoEffectsOptions& settings);
bool gpuDetailFilter(ImageData& image, float noiseReduction, float sharpening);

} // namespace sony2fuji
