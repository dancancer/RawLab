#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/dcp_look.h"
#include "sony2fuji/lut_parser.h"
#include "sony2fuji/processing_version.h"
#include "sony2fuji/sony2fuji.h"
#include "core/pixel_buffer.h"
#include "core/photo_geometry.h"
#include "core/photo_tone_curve.h"
#include "core/render_params.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <memory>

namespace sony2fuji {

struct ClarityField;
struct FilmOpticsField;

inline float clampFloat(float value, float low, float high) {
    return std::max(low, std::min(high, value));
}

inline float clamp01(float value) {
    return clampFloat(value, 0.0f, 1.0f);
}

RGB whiteBalanceForTempTint(float temperature, float tint);

void applyExposureAndWhiteBalance(RGB& pixel, float exposureScale, const RGB& wb);

RGB sampleBilinear(const ImageData& image, double x, double y);

ImageData resizeBilinear(
    const ImageData& source,
    uint32_t targetWidth,
    uint32_t targetHeight
);

void applyToneAdjustments(
    ImageData& image,
    const RenderParams& params,
    const std::array<ToneCurve, 3>& channels,
    bool basicV3 = false
);

void applyPostLookStages(
    ImageData& image,
    const RenderParams& params,
    const ToneControlsOptions& toneControls,
    const HslOptions& hsl,
    const ColorGradingOptions& colorGrading,
    const std::array<ToneCurve, 3>& channels,
    bool basicV3,
    bool applyHslAndGrading
);

void applyDetailAdjustments(
    ImageData& image,
    float noiseReduction,
    float sharpening,
    float clarity,
    int sourceWidth,
    int sourceHeight,
    ProcessingVersion version,
    const ClarityField* clarityField = nullptr,
    const SubRectMap& roiMap = {},
    const FilmOpticsOptions& filmOptics = {},
    const FilmOpticsField* filmOpticsField = nullptr
);

void applyOutputSharpening(ImageData& image, OutputSharpening level);

RenderStatus applyPhotoLook(
    ImageData& image,
    const std::shared_ptr<LUT3D>& lut,
    const std::shared_ptr<const DcpLook>& dcp,
    float strength,
    bool displayInput,
    const GpuConfig& config
);

RenderStatus ensureLinear(
    ImageData& image,
    ColorSpace space,
    bool* isLinear
);

RenderStatus loadLUT(
    const char* lutPath,
    std::shared_ptr<LUT3D>* outLut
);

} // namespace sony2fuji
