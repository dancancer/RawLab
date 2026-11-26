#pragma once

#include "core/hdr_pipeline.h"
#include "core/hdr_rendering.h"
#include "core/hdr_types.h"
#include "core/photo_atmosphere.h"
#include "core/photo_bw_mixer.h"
#include "core/photo_calibration.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_defringe.h"
#include "core/photo_effects.h"
#include "core/photo_film_optics.h"
#include "core/photo_geometry.h"
#include "core/photo_point_color.h"
#include "core/photo_selective_color.h"
#include "core/photo_sharpen_v2.h"
#include "core/photo_tone_controls.h"
#include "core/photo_tone_curve.h"
#include "core/render_params.h"
#include "core/wavelet_denoise.h"
#include "sony2fuji/processing_version.h"
#include "sony2fuji/raw_processor.h"

#include <array>
#include <cstdint>
#include <string>

namespace sony2fuji {

enum class UncalibratedWbPolicy : uint32_t {
    Error = 0,
    FallbackCamera = 1
};

struct MasterRecipeWbConfig {
    bool active = false;
    float strength = 1.0f;
    bool customWb = false;
    float temperatureKelvin = 6500.0f;
    float tint = 0.0f;
    UncalibratedWbPolicy uncalibratedFallback = UncalibratedWbPolicy::Error;
};

enum class CameraDevelopmentWbMode : uint32_t {
    AsShot = 0,
    Temperature = 1
};

enum class CameraDevelopmentExposureRef : uint32_t {
    Metadata = 0,
    Sensor = 1
};

struct CanonicalCameraDevelopment {
    CameraDevelopmentWbMode whiteBalance = CameraDevelopmentWbMode::AsShot;
    float temperature = 0.0f;
    float tint = 0.0f;
    CameraDevelopmentExposureRef exposureReference = CameraDevelopmentExposureRef::Metadata;
    uint32_t fbddLevel = 0;
    bool lensDistortion = false;
    bool lensTca = false;
    bool lensVignetting = false;
    bool lensAutoCrop = true;
    std::string lensProfileId;
    std::string cameraProfilePath;
    std::string cameraProfileSha256;
    bool useAi = false;
    bool hasProcessingVersion = false;
    ProcessingVersion processingVersion = ProcessingVersion::Legacy;

    uint32_t lensFlags() const noexcept {
        uint32_t flags = (lensDistortion ? kHdrCameraLensDistortion : 0u) |
                         (lensTca ? kHdrCameraLensTca : 0u) |
                         (lensVignetting ? kHdrCameraLensVignetting : 0u);
        if (flags != 0u && lensAutoCrop) {
            flags |= kHdrCameraLensAutoCrop;
        }
        return flags;
    }
};

enum class HdrBaseColor : uint32_t {
    Srgb = 1,
    DisplayP3 = 2
};

struct CanonicalHdrSettings {
    uint32_t processingVersion = kHdrProcessingV2GradingCurveVersion;
    std::string inputType = "hdr_raster";
    float relativeTemperature = 6500.0f;
    float relativeTint = 0.0f;
    float peakLimitEV = 0.0f;
    float sdrExposureEV = 0.0f;
    float sdrContrast = 0.0f;
    float sdrSaturation = 0.0f;
    float sharpening = 0.0f;
    float clarity = 0.0f;
    float dehaze = 0.0f;
    float denoise = 0.0f;
    std::string lookSha256;
    bool hasCameraDevelopment = false;
    CanonicalCameraDevelopment cameraDevelopment{};
    bool hdrOutput = true;
    HdrBaseColor baseColor = HdrBaseColor::Srgb;
};

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
    bool curveApplyToLuminosity = false;
    ToneCurveParametricConfig parametricCurve{};
    ToneControlsOptions toneControls{};
    AtmosphereOptions atmosphere{};
    ColorGradingOptions colorGrading{};
    CameraCalibrationOptions calibration{};
    PointColorOptions pointColor{};
    SelectiveColorOptions selectiveColor{};
    BwMixerOptions bw{};
    float sharpening = 0.0f;
    SharpenV2Options sharpenV2{};
    int32_t rawNoiseReduction = 0;
    int32_t chromaDenoise = 0;
    WaveletDenoiseOptions wavelet{false, 0.0f, 46.0f, 50.0f, ProcessingVersion::Legacy};
    HslOptions hsl{};
    PhotoEffectsOptions effects{};
    FilmOpticsOptions filmOptics{};
    bool lensDistortion = false;
    bool lensTca = false;
    bool lensVignetting = false;
    bool lensAutoCrop = true;
    std::string lensProfileId;
    DefringeOptions defringe{};
    bool hasAiDenoiseBlend = false;
    float aiDenoiseBlend = 1.0f;
    MasterRecipeWbConfig masterRecipe{};
    RenderOutputFormat outputFormat = RenderOutputFormat::JPEG;
    uint32_t jpegQuality = 95;
    uint32_t outputLongEdge = 0;
    OutputSharpening outputSharpening = OutputSharpening::Off;
    GeometryOptions geometry{};

    RenderParams toRenderParams() const;
};

struct CanonicalEditState {
    bool isHdr = false;
    uint32_t schemaVersion = 17;
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
    bool curveApplyToLuminosity = false;
    ToneCurveParametricConfig parametricCurve{};
    ToneControlsOptions toneControls{};
    AtmosphereOptions atmosphere{};
    ColorGradingOptions colorGrading{};
    CameraCalibrationOptions calibration{};
    PointColorOptions pointColor{};
    SelectiveColorOptions selectiveColor{};
    BwMixerOptions bw{};
    float sharpening = 0.0f;
    SharpenV2Options sharpenV2{};
    int32_t rawNoiseReduction = 0;
    int32_t chromaDenoise = 0;
    WaveletDenoiseOptions wavelet{false, 0.0f, 46.0f, 50.0f, ProcessingVersion::Legacy};
    HslOptions hsl{};
    PhotoEffectsOptions effects{};
    FilmOpticsOptions filmOptics{};
    bool lensDistortion = false;
    bool lensTca = false;
    bool lensVignetting = false;
    bool lensAutoCrop = true;
    std::string lensProfileId;
    DefringeOptions defringe{};
    bool hasAiDenoiseBlend = false;
    float aiDenoiseBlend = 1.0f;
    MasterRecipeWbConfig masterRecipe{};
    RenderOutputFormat outputFormat = RenderOutputFormat::JPEG;
    uint32_t jpegQuality = 95;
    uint32_t outputLongEdge = 0;
    OutputSharpening outputSharpening = OutputSharpening::Off;
    GeometryOptions geometry{};
    CanonicalHdrSettings hdr{};

    CanonicalSdrRecipe toCanonicalSdrRecipe() const;
    RenderParams toRenderParams() const;
    HDRRenderOptions toHdrRenderOptions(
        HDRQuality intent = HDRQuality::Final,
        uint32_t longEdge = 0,
        bool loadLook = true
    ) const;
    hdr::CameraRawDevelopmentSpec toCameraRawDevSpec(
        bool preview,
        uint32_t longEdge,
        bool defaultLegacySonyCrop
    ) const;
};

enum class RecipeParseMode : uint32_t {
    FileRecipe = 0,
    SessionState = 1
};

struct EditStateParseOptions {
    RecipeParseMode mode = RecipeParseMode::FileRecipe;
    bool allowRasterLensCorrection = false;
};

uint32_t hdrProcessingVersionForSchema(uint32_t schema) noexcept;
uint32_t schemaVersionForHdrProcessing(uint32_t processingVersion) noexcept;
bool validProfileId(const std::string& id);

bool parseCanonicalEditState(
    const std::string& document,
    CanonicalEditState& out,
    std::string& error,
    const EditStateParseOptions& options = {}
);

// Parses canonical SDR recipe JSON (schema_version 1..5, 7, 17, or 18).
// When allowRasterLensCorrection is false (CLI/Agent JSON contract), active lens
// correction on raster inputs is rejected. Invalid documents leave out unchanged.
bool parseCanonicalSdrRecipe(
    const std::string& document,
    CanonicalSdrRecipe& out,
    std::string& error,
    bool allowRasterLensCorrection = false
);

} // namespace sony2fuji
