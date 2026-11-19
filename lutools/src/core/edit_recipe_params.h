#pragma once

#include "core/photo_atmosphere.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_effects.h"
#include "core/photo_geometry.h"
#include "core/photo_tone_controls.h"
#include "core/photo_tone_curve.h"
#include "core/pipeline.h"
#include "core/render_params.h"
#include "core/wavelet_denoise.h"
#include "sony2fuji/processing_version.h"
#include "sony2fuji/raw_processor.h"

#include <array>
#include <cstdint>
#include <string>

namespace sony2fuji {

struct CanonicalSdrRecipe {
    uint32_t schemaVersion = 1;
    ProcessingVersion processingVersion = ProcessingVersion::Legacy;
    X3fMode x3fMode = X3fMode::Legacy;
    std::string inputPath;
    bool rasterInput = false;
    std::string outputPath;
    std::string lookPath;
    RawExposureMode exposureMode = RawExposureMode::Preview;
    float exposureEv = 0.0f;
    float brightness = 1.0f;
    RenderWhiteBalanceMode whiteBalanceMode = RenderWhiteBalanceMode::Camera;
    float temperatureKelvin = 6500.0f;
    float tint = 0.0f;
    float lookStrength = 1.0f;
    float contrast = 1.0f;
    float saturation = 1.0f;
    float highlights = 0.0f;
    float shadows = 0.0f;
    float sCurve = 0.0f;
    ToneCurveConfig toneCurve{};
    std::array<ToneCurveConfig, 3> channelCurves{};
    ToneControlsOptions toneControls{};
    AtmosphereOptions atmosphere{};
    ColorGradingOptions colorGrading{};
    float sharpening = 0.0f;
    int32_t rawNoiseReduction = 0;
    int32_t chromaDenoise = 0;
    WaveletDenoiseOptions wavelet{false, 0.0f, 46.0f, 50.0f, ProcessingVersion::Legacy};
    HslOptions hsl{};
    PhotoEffectsOptions effects{};
    bool lensDistortion = false;
    bool lensTca = false;
    bool lensVignetting = false;
    bool lensAutoCrop = true;
    std::string lensProfileId;
    RenderOutputFormat outputFormat = RenderOutputFormat::JPEG;
    uint32_t jpegQuality = 95;
    uint32_t outputLongEdge = 0;
    GeometryOptions geometry{};

    RenderParams toRenderParams() const;
};

bool validProfileId(const std::string& id);

// Parses canonical SDR recipe JSON (schema_version 1..5 or 7).
// When allowRasterLensCorrection is false (CLI/Agent JSON contract), active lens
// correction on raster inputs is rejected. Invalid documents leave out unchanged.
bool parseCanonicalSdrRecipe(
    const std::string& document,
    CanonicalSdrRecipe& out,
    std::string& error,
    bool allowRasterLensCorrection = false
);

} // namespace sony2fuji
