#pragma once

#include "core/photo_effects.h"
#include "sony2fuji/processing_version.h"
#include <algorithm>

namespace sony2fuji {

struct WaveletFilterSettings {
    int depth = 4;
    bool luminance = false;
    ProcessingVersion processingVersion = ProcessingVersion::C5V2;
    float sigma[18] = {};
    float thresholdScale[6] = {};
};

inline int waveletEnergyWindow(int level, bool luminance, ProcessingVersion version = ProcessingVersion::C5V2) {
    if (version == ProcessingVersion::Legacy) return level > 4 ? (1 << (level - 1)) + 1 : 7;
    // 六层 db2 的双向支撑半径为 189；能量窗口半径不超过 56，保持在 256 像素 halo 内。
    return luminance || level <= 4 ? std::min(113, (7 << (level - 1)) | 1) :
        (1 << (level - 1)) + 1;
}

inline bool waveletUsesFirmThreshold(int level, bool luminance, ProcessingVersion version = ProcessingVersion::C5V2) {
    return version != ProcessingVersion::Legacy && !luminance && level >= 2 && level <= 4;
}

// Native backend filtering. A failed operation leaves caller output unchanged.
bool gpuWaveletFilter(const float* input, int width, int height,
                      const WaveletFilterSettings& settings, float* output);
bool gpuGuidedFilter(const float* guide, const float* input, int width, int height,
                     int radius, float epsilon, float* output);
bool gpuPhotoEffects(ImageData& image, const PhotoEffectsOptions& settings);
bool gpuDetailFilter(ImageData& image, float noiseReduction, float sharpening);

} // namespace sony2fuji
