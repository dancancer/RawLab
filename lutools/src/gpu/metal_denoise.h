#pragma once

namespace sony2fuji {

struct WaveletFilterSettings {
    int depth = 4;
    float sigma[18] = {};
    float thresholdScale[6] = {};
};

// Contiguous float planes; coarse-to-fine bands. Failed calls leave output intact.
bool metalWaveletFilter(const float* input, int width, int height,
                       const WaveletFilterSettings& settings, float* output);

// Packed float3 guide / float2 source, matching OpenCV's BORDER_REFLECT means.
bool metalGuidedFilter(const float* guide, const float* input, int width, int height,
                       int radius, float epsilon, float* output);

} // namespace sony2fuji
