#pragma once

#include "sony2fuji/common.h"
#include <cmath>
#include <cstdint>

namespace sony2fuji {

struct SubRectMap;

enum class GrainToneCurve : uint32_t {
    Legacy = 0,
    NegativeAsymmetric = 1
};

enum class GrainFormatPreset : uint32_t {
    Custom = 0,
    Film135 = 1,
    Film120 = 2
};

struct PhotoEffectsOptions {
    float vignetteAmount = 0;
    float vignetteMidpoint = 50;
    float vignetteRoundness = 0;
    float vignetteFeather = 50;
    float vignetteHighlights = 0;
    float grainAmount = 0;
    float grainSize = 25;
    float grainRoughness = 50;
    GrainToneCurve grainToneCurve = GrainToneCurve::Legacy;
    GrainFormatPreset grainFormatPreset = GrainFormatPreset::Custom;

    bool active() const { return vignetteAmount != 0 || grainAmount != 0; }
    bool isDefaultGrainCurveOrPreset() const {
        return grainToneCurve == GrainToneCurve::Legacy && grainFormatPreset == GrainFormatPreset::Custom;
    }
    bool valid() const;
};

inline float resolveGrainSize(float grainSize, GrainFormatPreset preset) {
    switch (preset) {
        case GrainFormatPreset::Film135: return 18.0f;
        case GrainFormatPreset::Film120: return 34.0f;
        case GrainFormatPreset::Custom:
        default: return grainSize;
    }
}

inline float resolveGrainRoughness(float grainRoughness, GrainFormatPreset preset) {
    switch (preset) {
        case GrainFormatPreset::Film135: return 65.0f;
        case GrainFormatPreset::Film120: return 22.0f;
        case GrainFormatPreset::Custom:
        default: return grainRoughness;
    }
}

inline float grainToneWeight(float luma, GrainToneCurve curve) {
    luma = luma < 0.0f ? 0.0f : (luma > 1.0f ? 1.0f : luma);
    if (curve == GrainToneCurve::NegativeAsymmetric) {
        auto sm = [](float v) {
            v = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
            return v * v * (3.0f - 2.0f * v);
        };
        const float shadowRise = sm(luma / 0.06f);
        const float hiCut = 1.0f - sm((luma - 0.22f) / 0.75f);
        return shadowRise * std::sqrt(hiCut > 0.0f ? hiCut : 0.0f) * (0.20f + 0.90f * hiCut);
    }
    return std::sqrt(4.0f * luma * (1.0f - luma));
}

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
void applyPhotoEffectsROI(ImageData& image, const PhotoEffectsOptions& options, const SubRectMap& roiMap);

} // namespace sony2fuji
