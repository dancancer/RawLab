#include "core/pipeline.h"
#include "core/edit_recipe_params.h"
#include "core/pipeline_runtime.h"

#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/dcp_look.h"
#include "core/chroma_denoise.h"
#include "core/display_lens_correction.h"
#include "core/gpu_admission.h"
#include "core/hdr_rendering.h"
#include "core/image_header_probe.h"
#include "core/lut_compatibility.h"
#include "core/parallel_pixels.h"
#include "core/photo_basic_controls_v3.h"
#include "core/photo_defringe.h"
#include "core/photo_pipeline_stages.h"
#include "core/x3f_processor.h"
#include "gpu/denoise.h"
#include "gpu/photo_gpu.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <optional>
#include <stdexcept>

namespace sony2fuji {
namespace {
#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
constexpr bool kGpuBackendCompiled = true;
#else
constexpr bool kGpuBackendCompiled = false;
#endif

GpuFallbackReason fallbackReasonFromFault(GpuBackendFault fault) noexcept {
    switch (fault) {
    case GpuBackendFault::GpuDisabled: return GpuFallbackReason::GpuDisabled;
    case GpuBackendFault::NoAdapter: return GpuFallbackReason::NoAdapter;
    case GpuBackendFault::Cooldown: return GpuFallbackReason::Cooldown;
    case GpuBackendFault::FilterError: return GpuFallbackReason::FilterError;
    case GpuBackendFault::UnsupportedCapability: return GpuFallbackReason::UnsupportedCapability;
    case GpuBackendFault::DeviceError:
    case GpuBackendFault::None:
    default:
        return GpuFallbackReason::DeviceError;
    }
}
} // namespace

Pipeline::Pipeline()
    : gpuConfig_(defaultGpuConfig()),
      runtime_(std::make_unique<PipelineRuntimeState>()) {}

Pipeline::~Pipeline() = default;

void Pipeline::copyConfigurationFrom(const Pipeline& source) {
    gpuConfig_ = source.gpuConfig_;
    rawExposureMode_ = source.rawExposureMode_;
    rawNoiseReduction_ = source.rawNoiseReduction_;
    chromaDenoise_ = source.chromaDenoise_;
    processingVersion_ = source.processingVersion_;
    x3fMode_ = source.x3fMode_;
    waveletDenoise_ = source.waveletDenoise_;
    photoEffects_ = source.photoEffects_;
    hsl_ = source.hsl_;
    toneControls_ = source.toneControls_;
    atmosphere_ = source.atmosphere_;
    colorGrading_ = source.colorGrading_;
    cameraCalibration_ = source.cameraCalibration_;
    pointColor_ = source.pointColor_;
    selectiveColor_ = source.selectiveColor_;
    bwMixer_ = source.bwMixer_;
    sharpenV2_ = source.sharpenV2_;
    defringe_ = source.defringe_;
    filmOptics_ = source.filmOptics_;
    toneCurve_ = source.toneCurve_;
    channelCurves_ = source.channelCurves_;
    curveApplyToLuminosity_ = source.curveApplyToLuminosity_;
    parametricCurve_ = source.parametricCurve_;
    aiDenoiseBlend_ = source.aiDenoiseBlend_;
    hasCommittedEditState_ = source.hasCommittedEditState_;
    committedEditState_ = source.committedEditState_;
    masterRecipeWb_ = source.masterRecipeWb_;
    outputSharpening_ = source.outputSharpening_;
    rasterRelativeWbActive_ = source.rasterRelativeWbActive_;
    rasterRelativeTemp_ = source.rasterRelativeTemp_;
    rasterRelativeTint_ = source.rasterRelativeTint_;
    geometry_ = source.geometry_;
    lensCorrection_ = source.lensCorrection_;
    displayLensMetadata_ = source.displayLensMetadata_;
    hasDisplayLensMetadata_ = source.hasDisplayLensMetadata_;
    displayLensOrientation_ = source.displayLensOrientation_;
    lensDatabase_ = source.lensDatabase_;
    lensDatabaseTried_ = source.lensDatabaseTried_;
    lensDatabaseRevision_ = source.lensDatabaseRevision_;
}

RenderStatus Pipeline::validateLook(const char* path, LookFormat* format, uint32_t* formatVersion) {
    if (format) *format = LookFormat::Unknown;
    if (formatVersion) *formatVersion = 0;
    if (path == nullptr || path[0] == '\0') return RenderStatus::InvalidArgument;
    try {
        const auto file = std::filesystem::u8path(path);
        std::error_code error;
        if (!std::filesystem::is_regular_file(file, error) || error) {
            return RenderStatus::IoError;
        }
        std::ifstream readable(file, std::ios::binary);
        if (!readable) return RenderStatus::IoError;
        readable.close();
        const auto kind = LUTParser::detectFormat(path);
        if (kind == "rlook") {
            const auto look = DcpLook::loadCached(path);
            if (!look) return RenderStatus::Unsupported;
            if (formatVersion) *formatVersion = look->formatVersion();
            if (format) *format = LookFormat::Rlook;
        } else if (kind == "cube" || kind == "vlt") {
            std::shared_ptr<LUT3D> lut;
            const auto status = loadLUT(path, &lut);
            if (status != RenderStatus::Ok) return status;
            if (!lut->isPhotoLUT()) return RenderStatus::Unsupported;
            if (format) *format = kind == "vlt" ? LookFormat::Vlt : LookFormat::Cube;
            if (formatVersion && kind == "vlt") *formatVersion = 1;
        } else {
            return RenderStatus::Unsupported;
        }
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (const std::filesystem::filesystem_error&) {
        return RenderStatus::IoError;
    } catch (const std::exception&) {
        return RenderStatus::Unsupported;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

int32_t Pipeline::inspectLutColor(const char* path) {
    constexpr int32_t kLutUnreadable = 6;
    if (path == nullptr || path[0] == '\0') {
        return kLutUnreadable;
    }
    try {
        if (LUTParser::detectFormat(path) == "rlook") {
            return DcpLook::loadCached(path)
                ? static_cast<int32_t>(LUTContractState::Legacy)
                : kLutUnreadable;
        }
        const auto lut = LUTParser::loadLUT(path);
        if (!lut) return kLutUnreadable;
        return static_cast<int32_t>(lut->contractState());
    } catch (...) {
        return kLutUnreadable;
    }
}

RenderStatus Pipeline::sampleToneCurve(const ToneCurveConfig& config, const double* x, double* y, uint32_t count) {
    if (!x || !y || count == 0 || !validToneCurve(config) || config.mode != ToneCurveMode::Custom) {
        return RenderStatus::InvalidArgument;
    }
    for (uint32_t i = 0; i < count; ++i) {
        if (!std::isfinite(x[i])) return RenderStatus::InvalidArgument;
    }
    try {
        const ToneCurve curve(config);
        for (uint32_t i = 0; i < count; ++i) {
            y[i] = curve.evaluate(x[i]);
        }
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::sampleToneCurveV2(
    const ToneCurveConfig& config,
    const ToneCurveParametricConfig* parametric,
    const double* x,
    double* y,
    uint32_t count
) {
    if (!x || !y || count == 0 || !validToneCurve(config, ToneCurveEndpoints::Free)) {
        return RenderStatus::InvalidArgument;
    }
    if (parametric && !parametric->valid()) {
        return RenderStatus::InvalidArgument;
    }
    if (config.mode != ToneCurveMode::Custom && !(parametric && parametric->active())) {
        return RenderStatus::InvalidArgument;
    }
    for (uint32_t i = 0; i < count; ++i) {
        if (!std::isfinite(x[i])) return RenderStatus::InvalidArgument;
    }
    try {
        const ToneCurve curve(config, ToneCurveEndpoints::Free);
        const ToneCurveParametric parametricEval = parametric
            ? ToneCurveParametric(*parametric)
            : ToneCurveParametric{};
        for (uint32_t i = 0; i < count; ++i) {
            double v = x[i];
            if (parametricEval.active()) {
                v = parametricEval.evaluate(v);
            }
            y[i] = curve.evaluate(v);
        }
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

void Pipeline::setCancellation(int32_t (*callback)(void*), void* context) {
    cancellation_.callback = callback;
    cancellation_.context = callback ? context : nullptr;
}

void Pipeline::setHdrProgress(void (*callback)(void*, uint32_t, uint32_t), void* context) {
    hdrProgress_.callback = callback;
    hdrProgress_.context = callback ? context : nullptr;
}

void Pipeline::setGpuConfig(GpuMode mode) {
    gpuConfig_.mode = mode;
#if defined(SONY2FUJI_ENABLE_D3D11)
    if (gpuConfig_.mode == GpuMode::Off && runtime_) runtime_->d3dRenderer.reset();
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
    if (gpuConfig_.mode == GpuMode::Off && runtime_) runtime_->glesRenderer.reset();
#endif
}

RenderStatus Pipeline::setProcessingVersion(ProcessingVersion version) {
    if (!validProcessingVersion(version)) return RenderStatus::InvalidArgument;
    if (processingVersion_ != version) dehazeAnalysis_ = {};
    processingVersion_ = version;
    waveletDenoise_.processingVersion = version;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setChromaDenoise(int32_t mode) {
    if (mode < 0 || mode > 2) return RenderStatus::InvalidArgument;
    if (mode != 0 && !chromaDenoiseAvailable()) return RenderStatus::Unsupported;
    chromaDenoise_ = mode;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setWaveletDenoise(bool enabled, float luma, float chroma, float coarse) {
    const WaveletDenoiseOptions options{enabled, luma, chroma, coarse, processingVersion_};
    if (!validWaveletDenoiseOptions(options)) return RenderStatus::InvalidArgument;
    if (options.active() && !waveletDenoiseAvailable()) return RenderStatus::Unsupported;
    waveletDenoise_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::getRawNoiseReductionSupport(int32_t& supported) const {
    if (rawKey_.empty()) return RenderStatus::InvalidArgument;
    supported = rawNoiseReductionSupported_ ? 1 : 0;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::getRawExposure(float& baselineEv, float& metadataEv) const {
    if (rawKey_.empty()) return RenderStatus::InvalidArgument;
    baselineEv = baselineEv_;
    metadataEv = metadataEv_;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::getRawWhiteBalance(float& temperature, float& tint) const {
    if (rawKey_.empty()) return RenderStatus::InvalidArgument;
    if (!calibratedWb_) return RenderStatus::Unsupported;
    temperature = asShotTemperature_;
    tint = asShotTint_;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::getEffectiveRawWhiteBalance(float& temperature, float& tint) const {
    if (!lastRenderRendered_) return RenderStatus::InvalidArgument;
    if (!lastRenderWasRaw_) return RenderStatus::Unsupported;
    if (lastRenderWasNormalX3f_) {
        temperature = 6500.0f;
        tint = 0.0f;
        return RenderStatus::Ok;
    }
    float rawTemp = 0.0f;
    float rawTint = 0.0f;
    const auto status = getRawWhiteBalance(rawTemp, rawTint);
    if (status != RenderStatus::Ok) return status;
    if (!std::isfinite(rawTemp) || !std::isfinite(rawTint)) return RenderStatus::Unsupported;
    temperature = std::round(rawTemp);
    tint = std::round(rawTint);
    return RenderStatus::Ok;
}

RenderStatus Pipeline::resolveRecipeWhiteBalance(const RecipeWbRequest& request, RecipeWbResult& result) {
    result = {};
    if (request.inputPath.empty() ||
        !validProcessingVersion(request.processingVersion) ||
        (request.x3fMode != X3fMode::Legacy && request.x3fMode != X3fMode::Normal) ||
        (request.exposureMode < RawExposureMode::Scene || request.exposureMode > RawExposureMode::Sensor) ||
        !std::isfinite(request.recipeStrength) ||
        !std::isfinite(request.temperature) ||
        !std::isfinite(request.tint)) {
        return RenderStatus::InvalidArgument;
    }
    result.wbMode = request.customWb
        ? RenderWhiteBalanceMode::Temperature
        : RenderWhiteBalanceMode::Camera;
    result.temperature = request.temperature;
    result.tint = request.tint;

    if (!request.recipeActive || (!request.customWb && request.recipeStrength * request.tint == 0.0f)) {
        return RenderStatus::Ok;
    }

    float cameraTemp = 0.0f;
    float cameraTint = 0.0f;
    bool cameraCalibrated = false;

    if (isNormalX3f(request.inputPath.c_str(), request.x3fMode)) {
        cameraTemp = 6500.0f;
        cameraTint = 0.0f;
        cameraCalibrated = true;
    } else {
        std::string fileKey;
        if (!buildFileIdentityKey(request.inputPath.c_str(), fileKey)) {
            return RenderStatus::IoError;
        }
        if (recipeWbCache_.valid &&
            recipeWbCache_.fileKey == fileKey &&
            recipeWbCache_.processingVersion == request.processingVersion &&
            recipeWbCache_.x3fMode == request.x3fMode &&
            recipeWbCache_.exposureMode == request.exposureMode) {
            if (!recipeWbCache_.calibrated) {
                return RenderStatus::Unsupported;
            }
            cameraTemp = recipeWbCache_.temperature;
            cameraTint = recipeWbCache_.tint;
            cameraCalibrated = true;
        } else {
            try {
                ProcessingCancellationScope cancelScope(cancellation_);
                checkProcessingCancellation();

                RAWProcessor probe(sony2fuji::usesLegacySonyCrop(request.processingVersion));
                const auto inspected = probe.inspectFile(request.inputPath);
                checkProcessingCancellation();
                if (inspected != ErrorCode::Success) {
                    return mapErrorCode(inspected);
                }

                float rawTemp = 0.0f;
                float rawTint = 0.0f;
                const bool calibrated = probe.getAsShotWhiteBalance(rawTemp, rawTint) &&
                    std::isfinite(rawTemp) && std::isfinite(rawTint);
                if (!calibrated) {
                    recipeWbCache_ = {
                        true,
                        std::move(fileKey),
                        request.processingVersion,
                        request.x3fMode,
                        request.exposureMode,
                        false,
                        0.0f,
                        0.0f
                    };
                    return RenderStatus::Unsupported;
                }
                cameraTemp = std::round(rawTemp);
                cameraTint = std::round(rawTint);
                cameraCalibrated = true;
                recipeWbCache_ = {
                    true,
                    std::move(fileKey),
                    request.processingVersion,
                    request.x3fMode,
                    request.exposureMode,
                    true,
                    cameraTemp,
                    cameraTint
                };
            } catch (const ProcessingCancelled&) {
                return RenderStatus::Cancelled;
            } catch (const std::bad_alloc&) {
                return RenderStatus::OutOfMemory;
            } catch (...) {
                return RenderStatus::ProcessingError;
            }
        }
    }

    result.cameraTemperature = cameraTemp;
    result.cameraTint = cameraTint;
    result.cameraCalibrated = cameraCalibrated;
    if (!request.customWb) {
        result.temperature = cameraTemp;
    }
    result.tint = std::clamp(cameraTint + request.tint * request.recipeStrength, -150.0f, 150.0f);
    result.wbMode = RenderWhiteBalanceMode::Temperature;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setPhotoEffects(const PhotoEffectsOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    photoEffects_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setHsl(const HslOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    hsl_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setToneControls(const ToneControlsOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    toneControls_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setAtmosphere(const AtmosphereOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    atmosphere_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setColorGrading(const ColorGradingOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    colorGrading_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setCameraCalibration(const CameraCalibrationOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    cameraCalibration_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setPointColor(const PointColorOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    pointColor_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setSelectiveColor(const SelectiveColorOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    selectiveColor_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setBwMixer(const BwMixerOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    bwMixer_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setSharpenV2(const SharpenV2Options& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    sharpenV2_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setDefringe(const DefringeOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    defringe_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setFilmOptics(const FilmOpticsOptions& options) {
    if (!options.valid()) return RenderStatus::InvalidArgument;
    filmOptics_ = options;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setToneCurve(const ToneCurveConfig& config) {
    if (!validToneCurve(config)) return RenderStatus::InvalidArgument;
    try {
        ToneCurve curve(config);
        toneCurve_ = std::move(curve);
        channelCurves_ = {};
        curveApplyToLuminosity_ = false;
        parametricCurve_ = {};
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::setToneCurves(const ToneCurveConfig& masterConfig, const std::array<ToneCurveConfig, 3>& channelConfigs) {
    if (!validToneCurve(masterConfig) ||
        !std::all_of(channelConfigs.begin(), channelConfigs.end(),
            [](const auto& c) { return validToneCurve(c); })) {
        return RenderStatus::InvalidArgument;
    }
    try {
        ToneCurve master(masterConfig);
        std::array<ToneCurve, 3> channels = {
            ToneCurve(channelConfigs[0]),
            ToneCurve(channelConfigs[1]),
            ToneCurve(channelConfigs[2])
        };
        toneCurve_ = std::move(master);
        channelCurves_ = std::move(channels);
        curveApplyToLuminosity_ = false;
        parametricCurve_ = {};
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::setToneCurvesV2(
    const ToneCurveConfig& masterConfig,
    const std::array<ToneCurveConfig, 3>& channelConfigs,
    bool applyToLuminosity,
    const ToneCurveParametricConfig& parametric
) {
    if (!validToneCurve(masterConfig, ToneCurveEndpoints::Free) ||
        !std::all_of(channelConfigs.begin(), channelConfigs.end(),
            [](const auto& c) { return validToneCurve(c, ToneCurveEndpoints::Free); }) ||
        !parametric.valid()) {
        return RenderStatus::InvalidArgument;
    }
    try {
        ToneCurve master(masterConfig, ToneCurveEndpoints::Free);
        std::array<ToneCurve, 3> channels = {
            ToneCurve(channelConfigs[0], ToneCurveEndpoints::Free),
            ToneCurve(channelConfigs[1], ToneCurveEndpoints::Free),
            ToneCurve(channelConfigs[2], ToneCurveEndpoints::Free)
        };
        toneCurve_ = std::move(master);
        channelCurves_ = std::move(channels);
        curveApplyToLuminosity_ = applyToLuminosity;
        parametricCurve_ = parametric;
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::setAiDenoiseBlend(float strength) noexcept {
    if (!std::isfinite(strength) || strength < 0.0f || strength > 1.0f) {
        return RenderStatus::InvalidArgument;
    }
    aiDenoiseBlend_ = strength;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::applyParams(const char* recipeJson) {
    if (!recipeJson || !*recipeJson) return RenderStatus::InvalidArgument;
    try {
        CanonicalEditState parsed;
        std::string error;
        if (!parseCanonicalEditState(
                recipeJson, parsed, error, {RecipeParseMode::SessionState, /*allowRasterLensCorrection=*/true}) ||
            parsed.isHdr) {
            return RenderStatus::InvalidArgument;
        }
        return applyEditState(parsed, /*preserveUnsetAiBlend=*/true);
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::applyParams(const CanonicalSdrRecipe& recipe) {
    CanonicalEditState state{};
    state.isHdr = false;
    state.schemaVersion = recipe.schemaVersion;
    state.processingVersion = recipe.processingVersion;
    state.x3fMode = recipe.x3fMode;
    state.inputPath = recipe.inputPath;
    state.rasterInput = recipe.rasterInput;
    state.outputPath = recipe.outputPath;
    state.lookPath = recipe.lookPath;
    state.exposureMode = recipe.exposureMode;
    state.exposureEv = recipe.exposureEv;
    state.brightness = recipe.brightness;
    state.whiteBalanceMode = recipe.whiteBalanceMode;
    state.temperatureKelvin = recipe.temperatureKelvin;
    state.tint = recipe.tint;
    state.lookStrength = recipe.lookStrength;
    state.contrast = recipe.contrast;
    state.saturation = recipe.saturation;
    state.highlights = recipe.highlights;
    state.shadows = recipe.shadows;
    state.sCurve = recipe.sCurve;
    state.toneCurve = recipe.toneCurve;
    state.channelCurves = recipe.channelCurves;
    state.curveApplyToLuminosity = recipe.curveApplyToLuminosity;
    state.parametricCurve = recipe.parametricCurve;
    state.toneControls = recipe.toneControls;
    state.atmosphere = recipe.atmosphere;
    state.colorGrading = recipe.colorGrading;
    state.calibration = recipe.calibration;
    state.pointColor = recipe.pointColor;
    state.selectiveColor = recipe.selectiveColor;
    state.bw = recipe.bw;
    state.sharpening = recipe.sharpening;
    state.sharpenV2 = recipe.sharpenV2;
    state.rawNoiseReduction = recipe.rawNoiseReduction;
    state.chromaDenoise = recipe.chromaDenoise;
    state.wavelet = recipe.wavelet;
    state.hsl = recipe.hsl;
    state.effects = recipe.effects;
    state.filmOptics = recipe.filmOptics;
    state.lensDistortion = recipe.lensDistortion;
    state.lensTca = recipe.lensTca;
    state.lensVignetting = recipe.lensVignetting;
    state.lensAutoCrop = recipe.lensAutoCrop;
    state.lensProfileId = recipe.lensProfileId;
    state.defringe = recipe.defringe;
    state.hasAiDenoiseBlend = recipe.hasAiDenoiseBlend;
    state.aiDenoiseBlend = recipe.aiDenoiseBlend;
    state.masterRecipe = recipe.masterRecipe;
    state.outputFormat = recipe.outputFormat;
    state.jpegQuality = recipe.jpegQuality;
    state.outputLongEdge = recipe.outputLongEdge;
    state.outputSharpening = recipe.outputSharpening;
    state.geometry = recipe.geometry;
    return applyEditState(state, /*preserveUnsetAiBlend=*/true);
}

RenderStatus Pipeline::applyEditState(const CanonicalEditState& state, bool preserveUnsetAiBlend) {
    try {
        if (state.isHdr) {
            return RenderStatus::InvalidArgument;
        }
        if (!validProcessingVersion(state.processingVersion)) {
            return RenderStatus::InvalidArgument;
        }
        if (state.x3fMode != X3fMode::Legacy && state.x3fMode != X3fMode::Normal) {
            return RenderStatus::InvalidArgument;
        }
        if (state.exposureMode < RawExposureMode::Scene || state.exposureMode > RawExposureMode::Sensor) {
            return RenderStatus::InvalidArgument;
        }
        if (!std::isfinite(state.exposureEv) || std::abs(state.exposureEv) > 20.0f ||
            !std::isfinite(state.brightness) || state.brightness <= 0.0f ||
            !std::isfinite(state.contrast) || state.contrast < 0.0f || state.contrast > 2.0f ||
            !std::isfinite(state.saturation) || state.saturation < 0.0f || state.saturation > 2.0f ||
            !std::isfinite(state.highlights) || state.highlights < -1.0f || state.highlights > 1.0f ||
            !std::isfinite(state.shadows) || state.shadows < -1.0f || state.shadows > 1.0f ||
            !std::isfinite(state.sCurve) || state.sCurve < -1.0f || state.sCurve > 1.0f ||
            !std::isfinite(state.sharpening) || state.sharpening < 0.0f || state.sharpening > 2.0f ||
            !std::isfinite(state.lookStrength) || state.lookStrength < 0.0f || state.lookStrength > 2.0f ||
            !std::isfinite(state.aiDenoiseBlend) || state.aiDenoiseBlend < 0.0f || state.aiDenoiseBlend > 1.0f ||
            !std::isfinite(state.masterRecipe.strength) || state.masterRecipe.strength < 0.0f || state.masterRecipe.strength > 2.0f ||
            !std::isfinite(state.masterRecipe.temperatureKelvin) || state.masterRecipe.temperatureKelvin < 2000.0f || state.masterRecipe.temperatureKelvin > 50000.0f ||
            !std::isfinite(state.masterRecipe.tint) || std::abs(state.masterRecipe.tint) > 150.0f) {
            return RenderStatus::InvalidArgument;
        }
        if (state.rawNoiseReduction < 0 || state.rawNoiseReduction > 2) {
            return RenderStatus::InvalidArgument;
        }
        if (state.chromaDenoise < 0 || state.chromaDenoise > 2) {
            return RenderStatus::InvalidArgument;
        }
        if (state.chromaDenoise != 0 && !chromaDenoiseAvailable()) {
            return RenderStatus::Unsupported;
        }
        WaveletDenoiseOptions wavelet = state.wavelet;
        wavelet.processingVersion = state.processingVersion;
        if (!validWaveletDenoiseOptions(wavelet)) {
            return RenderStatus::InvalidArgument;
        }
        if (wavelet.active() && !waveletDenoiseAvailable()) {
            return RenderStatus::Unsupported;
        }
        const auto freeCurveEndpoints = state.schemaVersion >= 18 ? ToneCurveEndpoints::Free
            : state.schemaVersion >= 17 ? ToneCurveEndpoints::FreeY : ToneCurveEndpoints::Pinned;
        if (!state.effects.valid() || !state.hsl.valid() || !state.toneControls.valid() ||
            !state.atmosphere.valid() || !state.colorGrading.valid() || !state.parametricCurve.valid() ||
            !state.calibration.valid() || !state.pointColor.valid() || !state.selectiveColor.valid() ||
            !state.bw.valid() || !state.sharpenV2.valid() || !state.defringe.valid() ||
            !state.filmOptics.valid() ||
            state.outputSharpening < OutputSharpening::Off || state.outputSharpening > OutputSharpening::High) {
            return RenderStatus::InvalidArgument;
        }
        if (!validToneCurve(state.toneCurve, freeCurveEndpoints) ||
            !std::all_of(state.channelCurves.begin(), state.channelCurves.end(),
                [freeCurveEndpoints](const auto& c) { return validToneCurve(c, freeCurveEndpoints); })) {
            return RenderStatus::InvalidArgument;
        }
        ToneCurve masterCurve(state.toneCurve, freeCurveEndpoints);
        if (masterCurve.custom() && state.sCurve != 0.0f) {
            return RenderStatus::InvalidArgument;
        }
        std::array<ToneCurve, 3> channelCurves = {
            ToneCurve(state.channelCurves[0], freeCurveEndpoints),
            ToneCurve(state.channelCurves[1], freeCurveEndpoints),
            ToneCurve(state.channelCurves[2], freeCurveEndpoints)
        };
        GeometryOptions geometry = state.geometry;
        if (!geometry.valid()) {
            return RenderStatus::InvalidArgument;
        }
        geometry.crop_width = std::min(geometry.crop_width, 1.0f - geometry.crop_x);
        geometry.crop_height = std::min(geometry.crop_height, 1.0f - geometry.crop_y);

        if (!validProfileId(state.lensProfileId)) {
            return RenderStatus::InvalidArgument;
        }
        LensCorrectionOptions lens{
            state.lensDistortion, state.lensTca, state.lensAutoCrop, state.lensProfileId, state.lensVignetting
        };
        if (lens.active() && !LensCorrectionDatabase::available()) {
            return RenderStatus::Unsupported;
        }

        // All validations passed; commit atomically without touching runtime/hardware/metadata config.
        if (processingVersion_ != state.processingVersion) {
            dehazeAnalysis_ = {};
        }
        processingVersion_ = state.processingVersion;
        x3fMode_ = state.x3fMode;
        x3fError_.clear();
        unsupportedReason_ = UnsupportedReason::None;
        gpuFallbackReason_ = GpuFallbackReason::None;
        gpuErrorDetail_.clear();
        rawExposureMode_ = state.exposureMode;
        rawNoiseReduction_ = state.rawNoiseReduction;
        chromaDenoise_ = state.chromaDenoise;
        waveletDenoise_ = wavelet;
        photoEffects_ = state.effects;
        hsl_ = state.hsl;
        toneControls_ = state.toneControls;
        atmosphere_ = state.atmosphere;
        colorGrading_ = state.colorGrading;
        cameraCalibration_ = state.calibration;
        pointColor_ = state.pointColor;
        selectiveColor_ = state.selectiveColor;
        bwMixer_ = state.bw;
        sharpenV2_ = state.sharpenV2;
        defringe_ = state.defringe;
        filmOptics_ = state.filmOptics;
        toneCurve_ = std::move(masterCurve);
        channelCurves_ = std::move(channelCurves);
        curveApplyToLuminosity_ = state.curveApplyToLuminosity;
        parametricCurve_ = state.parametricCurve;
        if (!preserveUnsetAiBlend || state.hasAiDenoiseBlend) {
            aiDenoiseBlend_ = state.aiDenoiseBlend;
        }
        outputSharpening_ = state.outputSharpening;
        if (state.rasterInput && state.whiteBalanceMode == RenderWhiteBalanceMode::Relative) {
            rasterRelativeWbActive_ = true;
            rasterRelativeTemp_ = state.temperatureKelvin;
            rasterRelativeTint_ = state.tint;
        } else {
            rasterRelativeWbActive_ = false;
            rasterRelativeTemp_ = 6500.0f;
            rasterRelativeTint_ = 0.0f;
        }
        geometry_ = geometry;
        geometryWidth_ = geometryHeight_ = 0;
        lensCorrection_ = std::move(lens);
        masterRecipeWb_ = state.masterRecipe;
        committedEditState_ = state;
        committedEditState_.aiDenoiseBlend = aiDenoiseBlend_;
        if (committedEditState_.whiteBalanceMode == RenderWhiteBalanceMode::Camera) {
            committedEditState_.temperatureKelvin = 6500.0f;
            committedEditState_.tint = 0.0f;
        }
        hasCommittedEditState_ = true;
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

WaveletCacheDiagnostics Pipeline::waveletCacheDiagnostics() const {
    auto result = waveletCache_.diagnostics;
    result.previewBytes = waveletCache_.previewBytes();
    return result;
}

PreviewExposureDiagnostics Pipeline::previewExposureDiagnostics() const {
    return previewExposureCache_.diagnostics();
}

RenderStatus Pipeline::process(const RenderParams& params, OwnedPixelBuffer* outBuffer) {
    try {
        beginAiOperation("render");
        // 取消对预览到缓冲区、以及 FINAL 导出（文件或缓冲区）都生效。编码器在替换目标文件
        // 之前还有一次提交点检查，所以 FINAL 取消既不会留下半成品，也不会覆盖已有目标。
        const bool cancellable =
            params.outputTarget == RenderOutputTarget::Buffer || params.intent == RenderIntent::Final;
        ProcessingCancellationScope scope(cancellable ? cancellation_ : ProcessingCancellation{});
        return processImpl(params, outBuffer);
    } catch (const ProcessingCancelled&) {
        return RenderStatus::Cancelled;
    } catch (const std::bad_alloc& error) {
        return recordAiError(RenderStatus::OutOfMemory, error.what());
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    } catch (const ai::NotReady& error) {
        return recordAiError(RenderStatus::AiNotReady, error.what());
    } catch (const ai::Unsupported& error) {
        return recordAiError(RenderStatus::Unsupported, error.what());
#endif
    } catch (const std::exception& error) {
        return recordAiError(RenderStatus::ProcessingError, error.what());
    } catch (...) {
        return recordAiError(RenderStatus::ProcessingError, "Unknown native AI failure");
    }
}

RenderStatus Pipeline::processToImageData(const RenderParams& params, ImageData& outImage) {
    outImage = {};
    try {
        beginAiOperation("render");
        const bool cancellable =
            params.outputTarget == RenderOutputTarget::Buffer || params.intent == RenderIntent::Final;
        ProcessingCancellationScope scope(cancellable ? cancellation_ : ProcessingCancellation{});
        return processImpl(params, nullptr, nullptr, nullptr, nullptr, &outImage);
    } catch (const ProcessingCancelled&) {
        return RenderStatus::Cancelled;
    } catch (const std::bad_alloc& error) {
        return recordAiError(RenderStatus::OutOfMemory, error.what());
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    } catch (const ai::NotReady& error) {
        return recordAiError(RenderStatus::AiNotReady, error.what());
    } catch (const ai::Unsupported& error) {
        return recordAiError(RenderStatus::Unsupported, error.what());
#endif
    } catch (const std::exception& error) {
        return recordAiError(RenderStatus::ProcessingError, error.what());
    } catch (...) {
        return recordAiError(RenderStatus::ProcessingError, "Unknown native AI failure");
    }
}

RenderStatus Pipeline::resolveStateWhiteBalanceIfNeeded(RenderParams& params) {
    if (!masterRecipeWb_.active || params.inputType != RenderInputType::Raw) {
        return RenderStatus::Ok;
    }
    RecipeWbRequest wbReq{};
    wbReq.inputPath = params.inputPath;
    wbReq.processingVersion = processingVersion_;
    wbReq.x3fMode = x3fMode_;
    wbReq.exposureMode = rawExposureMode_;
    wbReq.recipeActive = masterRecipeWb_.active;
    wbReq.recipeStrength = masterRecipeWb_.strength;
    wbReq.customWb = masterRecipeWb_.customWb;
    wbReq.temperature = masterRecipeWb_.temperatureKelvin;
    wbReq.tint = masterRecipeWb_.tint;

    RecipeWbResult wbRes{};
    const RenderStatus status = resolveRecipeWhiteBalance(wbReq, wbRes);
    if (status == RenderStatus::Ok) {
        params.wbMode = wbRes.wbMode;
        if (wbRes.wbMode == RenderWhiteBalanceMode::Camera) {
            params.temperature = 6500.0f;
            params.tint = 0.0f;
        } else {
            params.temperature = wbRes.temperature;
            params.tint = wbRes.tint;
        }
        return RenderStatus::Ok;
    }
    if (status == RenderStatus::Unsupported &&
        masterRecipeWb_.uncalibratedFallback == UncalibratedWbPolicy::FallbackCamera) {
        params.wbMode = RenderWhiteBalanceMode::Camera;
        params.temperature = 6500.0f;
        params.tint = 0.0f;
        return RenderStatus::Ok;
    }
    return status;
}

RenderStatus Pipeline::prepareStatefulParams(
    const RenderExecutionOptions& options,
    const char* editStateJson,
    RenderParams& outParams,
    bool resolveMasterWb
) {
    if (options.viewportRoi.enabled) {
        const auto& roi = options.viewportRoi;
        if (!std::isfinite(roi.normX0) || !std::isfinite(roi.normY0) ||
            !std::isfinite(roi.normX1) || !std::isfinite(roi.normY1) ||
            roi.normX0 < 0.0 || roi.normY0 < 0.0 ||
            roi.normX1 > 1.0 || roi.normY1 > 1.0 ||
            roi.normX0 >= roi.normX1 || roi.normY0 >= roi.normY1) {
            return RenderStatus::InvalidArgument;
        }
    }
    if (editStateJson != nullptr) {
        if (!*editStateJson) {
            return RenderStatus::InvalidArgument;
        }
        CanonicalEditState parsed;
        std::string error;
        if (!parseCanonicalEditState(
                editStateJson, parsed, error, {RecipeParseMode::SessionState, /*allowRasterLensCorrection=*/true}) ||
            parsed.isHdr) {
            return RenderStatus::InvalidArgument;
        }
        const RenderStatus applyStatus = applyEditState(parsed, /*preserveUnsetAiBlend=*/false);
        if (applyStatus != RenderStatus::Ok) {
            return applyStatus;
        }
    }

    outParams = hasCommittedEditState_ ? committedEditState_.toRenderParams() : RenderParams{};
    outParams.inputType = options.inputType;
    outParams.inputPixelFormat = options.inputPixelFormat;
    if (!options.inputPath.empty()) {
        outParams.inputPath = options.inputPath;
    } else if (options.inputType == RenderInputType::Raw && hasCommittedEditState_) {
        outParams.inputPath = committedEditState_.inputPath;
    } else {
        outParams.inputPath.clear();
    }
    outParams.inputPixels = options.inputPixels;
    outParams.inputWidth = options.inputWidth;
    outParams.inputHeight = options.inputHeight;
    outParams.inputColorSpace = options.inputColorSpace;
    outParams.inputIsLinear = options.inputIsLinear;

    outParams.intent = options.intent;
    outParams.sizeMode = options.sizeMode;
    outParams.targetWidth = options.targetWidth;
    outParams.targetHeight = options.targetHeight;
    outParams.longEdge = options.longEdge;
    outParams.shortEdge = options.shortEdge;
    outParams.previewLongEdge = options.previewLongEdge;
    outParams.outputTarget = options.outputTarget;
    outParams.outputFormat = options.outputFormat;
    if (!options.outputPath.empty()) {
        outParams.outputPath = options.outputPath;
    } else if (options.outputTarget == RenderOutputTarget::File && hasCommittedEditState_) {
        outParams.outputPath = committedEditState_.outputPath;
    } else {
        outParams.outputPath.clear();
    }
    outParams.jpegQuality = options.jpegQuality != 0
        ? options.jpegQuality
        : (hasCommittedEditState_ ? committedEditState_.jpegQuality : 95u);

    if (resolveMasterWb) {
        const RenderStatus wbStatus = resolveStateWhiteBalanceIfNeeded(outParams);
        if (wbStatus != RenderStatus::Ok) {
            return wbStatus;
        }
    }
    return RenderStatus::Ok;
}

namespace {

struct TransientPreviewGuard {
    Pipeline& pipeline;
    bool& interactiveRef;
    bool& viewportRef;
    Pipeline::ViewportRoiConfig& roiRef;
    bool prevInteractive;
    bool prevViewport;
    Pipeline::ViewportRoiConfig prevRoi;

    TransientPreviewGuard(
        Pipeline& p,
        bool& iRef,
        bool& vRef,
        Pipeline::ViewportRoiConfig& rRef,
        const Pipeline::RenderExecutionOptions& opts
    )
        : pipeline(p),
          interactiveRef(iRef),
          viewportRef(vRef),
          roiRef(rRef),
          prevInteractive(iRef),
          prevViewport(vRef),
          prevRoi(rRef) {
        interactiveRef = opts.interactivePreview;
        viewportRef = opts.viewportPreview;
        roiRef = opts.viewportRoi;
    }

    ~TransientPreviewGuard() {
        interactiveRef = prevInteractive;
        viewportRef = prevViewport;
        roiRef = prevRoi;
    }
};

} // namespace

RenderStatus Pipeline::renderWithOptions(
    const RenderExecutionOptions& options,
    const char* editStateJson,
    OwnedPixelBuffer* outBuffer,
    ViewportRoiResult* outRoi
) {
    if (outRoi) *outRoi = {};
    RenderParams params;
    const RenderStatus prep = prepareStatefulParams(options, editStateJson, params);
    if (prep != RenderStatus::Ok) return prep;

    TransientPreviewGuard guard(*this, interactivePreview_, viewportPreview_, viewportRoi_, options);
    const RenderStatus status = process(params, outBuffer);
    if (outRoi) {
        *outRoi = viewportRoiResult_;
    }
    return status;
}

RenderStatus Pipeline::renderToImageDataWithOptions(
    const RenderExecutionOptions& options,
    const char* editStateJson,
    ImageData& outImage
) {
    RenderParams params;
    const RenderStatus prep = prepareStatefulParams(options, editStateJson, params);
    if (prep != RenderStatus::Ok) return prep;

    TransientPreviewGuard guard(*this, interactivePreview_, viewportPreview_, viewportRoi_, options);
    return processToImageData(params, outImage);
}

RenderStatus Pipeline::createHslProbeWithOptions(
    const RenderExecutionOptions& options,
    const char* editStateJson,
    uint64_t sourceRevision,
    uint64_t requestRevision,
    HslProbeData& outProbe
) {
    RenderParams params;
    const RenderStatus prep = prepareStatefulParams(options, editStateJson, params);
    if (prep != RenderStatus::Ok) return prep;

    TransientPreviewGuard guard(*this, interactivePreview_, viewportPreview_, viewportRoi_, options);
    return createHslProbe(params, sourceRevision, requestRevision, outProbe);
}

RenderStatus Pipeline::estimateAutoExposureWithOptions(
    const RenderExecutionOptions& options,
    const char* editStateJson,
    float& outExposureEv
) {
    RenderParams params;
    const RenderStatus prep = prepareStatefulParams(options, editStateJson, params);
    if (prep != RenderStatus::Ok) return prep;

    return estimateAutoExposure(params, outExposureEv);
}

RenderStatus Pipeline::sampleWbProbeWithOptions(
    const RenderExecutionOptions& options,
    const char* editStateJson,
    const WbProbeQuery& query,
    WbProbeResult& outResult
) {
    RenderParams params;
    const RenderStatus prep = prepareStatefulParams(options, editStateJson, params);
    if (prep != RenderStatus::Ok) return prep;

    return sampleWbProbe(params, query, outResult);
}

RenderStatus Pipeline::prepareAiWithOptions(
    const RenderExecutionOptions& options,
    const char* editStateJson,
    const AiProgressCallback& progress
) {
    RenderParams params;
    const RenderStatus prep = prepareStatefulParams(options, editStateJson, params);
    if (prep != RenderStatus::Ok) return prep;

    return prepareAi(params, progress);
}

RenderStatus Pipeline::previewLutCompatibilityWithOptions(
    const RenderExecutionOptions& options,
    const char* editStateJson,
    const char* configuration,
    OwnedPixelBuffer& outBuffer
) {
    RenderParams params;
    const RenderStatus prep = prepareStatefulParams(options, editStateJson, params);
    if (prep != RenderStatus::Ok) return prep;

    TransientPreviewGuard guard(*this, interactivePreview_, viewportPreview_, viewportRoi_, options);
    return previewLutCompatibility(params, configuration, outBuffer);
}

RenderStatus Pipeline::migrateProcessingWithOptions(
    const RenderExecutionOptions& options,
    const char* editStateJson,
    ProcessingMigrationResult& outResult
) {
    RenderParams params;
    const RenderStatus prep = prepareStatefulParams(options, editStateJson, params);
    if (prep != RenderStatus::Ok) return prep;

    return migrateProcessing(params, outResult);
}

RenderStatus Pipeline::previewLutCompatibility(
    const RenderParams& params,
    const char* configuration,
    OwnedPixelBuffer& outBuffer
) {
    outBuffer.reset();
    if (!configuration || !*configuration || params.lutPath.empty() ||
        params.intent != RenderIntent::Preview || params.outputTarget != RenderOutputTarget::Buffer ||
        params.previewLongEdge < 1 || params.previewLongEdge > 1024) {
        return RenderStatus::InvalidArgument;
    }
    try {
        auto lut = loadLUTCompatibilityPreview(params.lutPath.c_str(), configuration);
        return processImpl(params, &outBuffer, nullptr, std::move(lut));
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (const std::filesystem::filesystem_error&) {
        return RenderStatus::IoError;
    } catch (const std::exception&) {
        return RenderStatus::Unsupported;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::createHslProbe(
    const RenderParams& params,
    uint64_t sourceRevision,
    uint64_t requestRevision,
    HslProbeData& outProbe
) {
    if (params.outputTarget != RenderOutputTarget::Buffer) {
        return RenderStatus::InvalidArgument;
    }
    // 分析明确使用 CPU；不改写 gpu_config（避免来回失效 wavelet 缓存），且已发布渲染元信息不泄漏。
    struct Restore {
        Pipeline& pipeline;
        RenderBackend backend;
        uint32_t width;
        uint32_t height;
        UnsupportedReason unsupportedReason;
        GpuFallbackReason gpuFallbackReason;
        std::string gpuErrorDetail;
        ~Restore() {
            pipeline.lastBackend_ = backend;
            pipeline.geometryWidth_ = width;
            pipeline.geometryHeight_ = height;
            pipeline.unsupportedReason_ = unsupportedReason;
            pipeline.gpuFallbackReason_ = gpuFallbackReason;
            pipeline.gpuErrorDetail_ = std::move(gpuErrorDetail);
        }
    } restore{*this, lastBackend_, geometryWidth_, geometryHeight_,
              unsupportedReason_, gpuFallbackReason_, gpuErrorDetail_};

    try {
        beginAiOperation("hsl_probe");
        // 探针只接受缓冲区目标，因此始终处于可取消范围内。
        ProcessingCancellationScope scope(cancellation_);
        HslProbeData probe;
        OwnedPixelBuffer unused{};
        const auto status = processImpl(params, &unused, &probe.image);
        if (status != RenderStatus::Ok) return status;
        probe.sourceRevision = sourceRevision;
        probe.requestRevision = requestRevision;
        probe.quality = params.intent == RenderIntent::Preview
            ? HslProbeQuality::PreviewCpu
            : HslProbeQuality::ExactCpu;
        outProbe = std::move(probe);
        return RenderStatus::Ok;
    } catch (const ProcessingCancelled&) {
        return RenderStatus::Cancelled;
    } catch (const std::bad_alloc& error) {
        return recordAiError(RenderStatus::OutOfMemory, error.what());
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    } catch (const ai::NotReady& error) {
        return recordAiError(RenderStatus::AiNotReady, error.what());
    } catch (const ai::Unsupported& error) {
        return recordAiError(RenderStatus::Unsupported, error.what());
#endif
    } catch (const std::exception& error) {
        return recordAiError(RenderStatus::ProcessingError, error.what());
    } catch (...) {
        return recordAiError(RenderStatus::ProcessingError, "Unknown native AI failure");
    }
}

RenderStatus Pipeline::estimateAutoExposure(const RenderParams& params, float& outExposureEv) {
    x3fError_.clear();
    unsupportedReason_ = UnsupportedReason::None;
    gpuFallbackReason_ = GpuFallbackReason::None;
    gpuErrorDetail_.clear();
    if (params.wbMode < RenderWhiteBalanceMode::Camera || params.wbMode > RenderWhiteBalanceMode::Relative) {
        return RenderStatus::InvalidArgument;
    }
    if (params.inputType == RenderInputType::Buffer &&
        params.inputColorSpace != ColorSpace::sRGB &&
        params.inputColorSpace != ColorSpace::FujiFilm_FGamut &&
        params.inputColorSpace != ColorSpace::SonyNative &&
        params.inputColorSpace != ColorSpace::ACEScg &&
        params.inputColorSpace != ColorSpace::AdobeRGB) {
        return RenderStatus::InvalidArgument;
    }
    auto local = params;
    local.outputTarget = RenderOutputTarget::Buffer;
    local.intent = RenderIntent::Final;
    const auto valid = validateRenderParams(local, true);
    if (valid != RenderStatus::Ok) return valid;
    if (local.inputType == RenderInputType::DisplayBuffer &&
        local.wbMode == RenderWhiteBalanceMode::Camera &&
        local.temperature == 6500.0f &&
        local.tint == 0.0f &&
        rasterRelativeWbActive_) {
        local.wbMode = RenderWhiteBalanceMode::Relative;
        local.temperature = rasterRelativeTemp_;
        local.tint = rasterRelativeTint_;
    }

    try {
        beginAiOperation("auto_exposure");
        ImageData image;
        ColorSpace space = ColorSpace::sRGB;
        bool linear = false;
        const bool raw = local.inputType == RenderInputType::Raw;
        auto status = raw ? loadRawImage(local, image, &space, &linear, false)
                          : loadBufferImage(local, image, &space, &linear);
        if (status != RenderStatus::Ok) return status;
        status = ensureLinear(image, space, &linear);
        if (status != RenderStatus::Ok) return status;
        if (space == ColorSpace::SonyNative) return RenderStatus::Unsupported;
        RGB wb(1, 1, 1);
        if (local.wbMode == RenderWhiteBalanceMode::Relative) {
            wb = hdrRelativeWhiteBalance(local.temperature, local.tint);
        } else if (local.wbMode != RenderWhiteBalanceMode::Temperature || (raw && rawDisplayReferred_)) {
            const auto reference = whiteBalanceForTempTint(6500.0f, 0.0f);
            const auto selected = whiteBalanceForTempTint(local.temperature, local.tint);
            wb = RGB(
                reference.r / std::max(selected.r, 1e-4f),
                reference.g / std::max(selected.g, 1e-4f),
                reference.b / std::max(selected.b, 1e-4f)
            );
            wb.r /= wb.g;
            wb.b /= wb.g;
            wb.g = 1.0f;
        }
        if ((!raw || rawDisplayReferred_) && local.wbMode == RenderWhiteBalanceMode::Custom) {
            wb.r *= local.wbMul[0] / local.wbMul[1];
            wb.b *= local.wbMul[2] / local.wbMul[1];
        }
        float ev = 0.0f;
        if (!sony2fuji::estimateAutoExposure(raw ? rawCache_ : image, space, wb, ev)) {
            return RenderStatus::Unsupported;
        }
        outExposureEv = ev;
        return RenderStatus::Ok;
    } catch (const std::bad_alloc& error) {
        return recordAiError(RenderStatus::OutOfMemory, error.what());
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    } catch (const ai::NotReady& error) {
        return recordAiError(RenderStatus::AiNotReady, error.what());
    } catch (const ai::Unsupported& error) {
        return recordAiError(RenderStatus::Unsupported, error.what());
#endif
    } catch (const std::exception& error) {
        return recordAiError(RenderStatus::ProcessingError, error.what());
    } catch (...) {
        return recordAiError(RenderStatus::ProcessingError, "Unknown native AI failure");
    }
}

RenderStatus Pipeline::migrateProcessing(const RenderParams& params, ProcessingMigrationResult& outResult) const {
    outResult = {};
    unsupportedReason_ = UnsupportedReason::None;
    gpuFallbackReason_ = GpuFallbackReason::None;
    gpuErrorDetail_.clear();
    if (gpuConfig_.mode == GpuMode::Force || aiEnabled()) {
        if (gpuConfig_.mode == GpuMode::Force && !aiEnabled()) {
            unsupportedReason_ = UnsupportedReason::ForceGpu;
        }
        return RenderStatus::Unsupported;
    }
    const MigrationParameters initial{
        params.exposureEV, params.contrast, params.highlights, params.shadows, params.saturation,
        toneControls_.blackPoint, toneControls_.whitePoint, toneControls_.vibrance,
        atmosphere_.clarity, atmosphere_.dehaze
    };
    if (!validMigrationParameters(initial)) return RenderStatus::Unsupported;

    try {
        ProcessingCancellationScope scope(cancellation_);
        checkProcessingCancellation();
        // 只复制配置，不共享会变化的 RAW、降噪、GPU 或去朦胧缓存。
        Pipeline worker;
        worker.copyConfigurationFrom(*this);
        auto local = params;
        local.outputTarget = RenderOutputTarget::Buffer;
        local.outputFormat = RenderOutputFormat::RGB8;
        local.outputPath.clear();
        local.targetWidth = 0;
        local.targetHeight = 0;

        auto stamp = [](const std::string& path) -> std::string {
            if (path.empty()) return std::string();
            const auto file = std::filesystem::u8path(path);
            return std::filesystem::canonical(file).u8string() + ':' +
                std::to_string(std::filesystem::file_size(file)) + ':' +
                std::to_string(std::chrono::duration_cast<std::chrono::microseconds>(
                    std::filesystem::last_write_time(file).time_since_epoch()).count());
        };
        const auto inputStamp = local.inputType == RenderInputType::Raw ? stamp(local.inputPath) : std::string();
        const auto lookStamp = stamp(local.lutPath);
        if (sony2fuji::usesLegacySonyCrop(processingVersion_) &&
            local.inputType == RenderInputType::Raw && !local.inputPath.empty()) {
            bool framingChanged = false;
            const auto status = RAWProcessor::sonyFramingChanged(local.inputPath, framingChanged);
            if (status != ErrorCode::Success) return mapErrorCode(status);
            // A color fit cannot change the reference frame of a saved crop.
            if (framingChanged) return RenderStatus::Unsupported;
        }
        uint32_t evaluations = 0;
        auto render = [&](const MigrationParameters& values, ProcessingVersion version, bool exact,
                          const MigrationFrame* reference = nullptr) {
            checkProcessingCancellation();
            worker.processingVersion_ = version;
            worker.waveletDenoise_.processingVersion = version;
            worker.gpuConfig_.mode = exact ? gpuConfig_.mode : GpuMode::Off;
            worker.interactivePreview_ = false;
            worker.viewportPreview_ = !exact;
            local.intent = exact ? RenderIntent::Final : RenderIntent::Preview;
            local.sizeMode = exact ? RenderSizeMode::Native : RenderSizeMode::LimitLongEdge;
            local.longEdge = exact ? 0 : 384;
            local.previewLongEdge = 0;
            local.exposureEV = values[0];
            local.contrast = values[1];
            local.highlights = values[2];
            local.shadows = values[3];
            local.saturation = values[4];
            worker.toneControls_ = {values[5], values[6], values[7]};
            worker.atmosphere_ = {values[8], values[9], atmosphere_.texture};
            MigrationFrame frame;
            frame.retainNativePixels = exact;
            frame.validationReference = reference;
            OwnedPixelBuffer unused{};
            const auto status = worker.processImpl(local, &unused, nullptr, nullptr, &frame);
            if (status != RenderStatus::Ok) throw status;
            ++evaluations;
            return frame;
        };
        auto fitted = initial;
        MigrationQuality quality;
        auto disposition = MigrationDisposition::Unchanged;
        if (processingVersion_ != ProcessingVersion::BasicV3) {
            const auto reference = render(initial, processingVersion_, false);
            fitted = fitMigrationParameters(initial, reference, [&](const auto& values) {
                return render(values, ProcessingVersion::BasicV3, false);
            });
            // 低清搜索仅产生候选。验收重新处理完整源图，包含原尺寸局部细节。
            const auto exactReference = render(initial, processingVersion_, true);
            quality = migrationQuality(exactReference,
                render(fitted, ProcessingVersion::BasicV3, true, &exactReference));
            disposition = quality.accepted() ? MigrationDisposition::Accepted : MigrationDisposition::Rejected;
        }
        if ((local.inputType == RenderInputType::Raw && stamp(local.inputPath) != inputStamp) ||
            stamp(local.lutPath) != lookStamp) {
            return RenderStatus::Cancelled;
        }
        checkProcessingCancellation();
        outResult = {
            static_cast<int32_t>(processingVersion_),
            3,
            disposition,
            evaluations,
            fitted,
            quality
        };
        return RenderStatus::Ok;
    } catch (RenderStatus status) {
        return status;
    } catch (const ProcessingCancelled&) {
        return RenderStatus::Cancelled;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (const std::filesystem::filesystem_error&) {
        return RenderStatus::IoError;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

static void computeEffectiveWbAndExposure(
    const RenderParams& local,
    bool displayInput,
    RGB& wb,
    float& exposure
) {
    exposure = std::pow(2.0f, local.exposureEV) * local.brightness;
    wb = RGB(1.0f, 1.0f, 1.0f);
    if (local.wbMode == RenderWhiteBalanceMode::Relative) {
        wb = hdrRelativeWhiteBalance(local.temperature, local.tint);
    } else if (local.wbMode != RenderWhiteBalanceMode::Temperature || displayInput) {
        const auto reference = whiteBalanceForTempTint(6500.0f, 0.0f);
        const auto selected = whiteBalanceForTempTint(local.temperature, local.tint);
        wb = RGB(
            reference.r / std::max(selected.r, 1e-4f),
            reference.g / std::max(selected.g, 1e-4f),
            reference.b / std::max(selected.b, 1e-4f)
        );
        wb.r /= wb.g;
        wb.b /= wb.g;
        wb.g = 1.0f;
    }
    if ((local.inputType == RenderInputType::Buffer || displayInput) &&
        local.wbMode == RenderWhiteBalanceMode::Custom) {
        wb.r *= local.wbMul[0] / local.wbMul[1];
        wb.b *= local.wbMul[2] / local.wbMul[1];
    }
}

RenderStatus Pipeline::sampleWbProbe(
    const RenderParams& params,
    const WbProbeQuery& query,
    WbProbeResult& outResult
) {
    outResult = {};
    if (query.windowSize != 0 && query.windowSize != 1 && query.windowSize != 3 && query.windowSize != 5) {
        return RenderStatus::InvalidArgument;
    }
    RenderParams local = params;
    local.outputTarget = RenderOutputTarget::Buffer;
    local.outputPath.clear();
    local.intent = RenderIntent::Preview;
    const RenderStatus valid = validateRenderParams(local, true);
    if (valid != RenderStatus::Ok) {
        return valid;
    }
    if (!std::isfinite(query.normX) || !std::isfinite(query.normY) ||
        query.normX < 0.0f || query.normX > 1.0f ||
        query.normY < 0.0f || query.normY > 1.0f) {
        outResult.availability = WbProbeAvailability::Outside;
        return RenderStatus::Ok;
    }
    if (local.inputType == RenderInputType::Buffer) {
        outResult.availability = WbProbeAvailability::Unavailable;
        return RenderStatus::Ok;
    }
    try {
        const int windowSize = query.windowSize == 0 ? 3 : static_cast<int>(query.windowSize);
        const int half = windowSize / 2;

        if (local.inputType == RenderInputType::Raw) {
            if (isNormalX3f(local.inputPath.c_str(), x3fMode_)) {
                outResult.availability = WbProbeAvailability::Unavailable;
                return RenderStatus::Ok;
            }
            const RenderStatus loadStatus = loadRawForWbProbe(local);
            if (loadStatus != RenderStatus::Ok) {
                return loadStatus;
            }
            if (!hasCachedRawWb_ || !cachedRawWb_.available() || rawCache_.pixels.empty()) {
                outResult.availability = WbProbeAvailability::Unavailable;
                return RenderStatus::Ok;
            }
            const auto outSize = geometryOutputSize(rawCache_.width, rawCache_.height, geometry_);
            const int outW = outSize.first;
            const int outH = outSize.second;
            if (outW <= 0 || outH <= 0) {
                outResult.availability = WbProbeAvailability::Unavailable;
                return RenderStatus::Ok;
            }
            const auto sampler = makeGeometrySampler(rawCache_.width, rawCache_.height, geometry_);
            const auto reader = [&](int sx, int sy) { return rawCache_.at(sx, sy); };
            const int cx = static_cast<int>(std::lround(double(query.normX) * (outW - 1)));
            const int cy = static_cast<int>(std::lround(double(query.normY) * (outH - 1)));
            const auto adobeToSrgb = ColorConverter::getConversionMatrix(ColorSpace::AdobeRGB, ColorSpace::sRGB);
            const float invBaseline = 1.0f / std::exp2(cachedBaselineEv_);

            double sumR = 0.0, sumG = 0.0, sumB = 0.0;
            for (int dy = -half; dy <= half; ++dy) {
                const int py = cy + dy;
                if (py < 0 || py >= outH) continue;
                for (int dx = -half; dx <= half; ++dx) {
                    const int px = cx + dx;
                    if (px < 0 || px >= outW) continue;
                    const RGB adobe = sampler(px, py, reader);
                    RGB srgb = ColorConverter::applyMatrix(adobe, adobeToSrgb);
                    srgb.r *= invBaseline;
                    srgb.g *= invBaseline;
                    srgb.b *= invBaseline;
                    if (!std::isfinite(srgb.r) || !std::isfinite(srgb.g) || !std::isfinite(srgb.b) ||
                        std::max({srgb.r, srgb.g, srgb.b}) >= 0.98f) {
                        ++outResult.rejectedOverexposedCount;
                        continue;
                    }
                    sumR += srgb.r;
                    sumG += srgb.g;
                    sumB += srgb.b;
                    ++outResult.validPixelCount;
                }
            }
            if (outResult.validPixelCount == 0) {
                outResult.availability = WbProbeAvailability::Overexposed;
                return RenderStatus::Ok;
            }
            const double count = static_cast<double>(outResult.validPixelCount);
            const RGB mean(static_cast<float>(sumR / count), static_cast<float>(sumG / count), static_cast<float>(sumB / count));
            outResult.sampledRgb = {mean.r, mean.g, mean.b};

            ColorConverter::Matrix3x3 invRgbCam{};
            try {
                invRgbCam = ColorConverter::invertMatrix(cachedRgbCam_);
            } catch (...) {
                outResult.availability = WbProbeAvailability::Unavailable;
                return RenderStatus::Ok;
            }
            const RGB camWb = ColorConverter::applyMatrix(mean, invRgbCam);
            const double camRaw[3] = {
                std::max(1e-6, static_cast<double>(camWb.r) / cachedWbUsed_[0]),
                std::max(1e-6, static_cast<double>(camWb.g) / cachedWbUsed_[1]),
                std::max(1e-6, static_cast<double>(camWb.b) / cachedWbUsed_[2])
            };
            const std::array<double, 3> neutral = {
                camRaw[0] / camRaw[1],
                1.0,
                camRaw[2] / camRaw[1]
            };
            TemperatureTint solved{};
            if (!cachedRawWb_.solveTemperatureTint(neutral, solved)) {
                outResult.availability = WbProbeAvailability::Unavailable;
                return RenderStatus::Ok;
            }
            outResult.temperature = static_cast<float>(std::clamp(solved.temperature, 2000.0, 50000.0));
            outResult.tint = static_cast<float>(std::clamp(solved.tint, -150.0, 150.0));
            outResult.wbMul = {
                static_cast<float>(camRaw[1] / camRaw[0]),
                1.0f,
                static_cast<float>(camRaw[1] / camRaw[2])
            };
            outResult.availability = WbProbeAvailability::Available;
            return RenderStatus::Ok;
        }

        // DisplayBuffer (SDR raster)
        ImageData image;
        ColorSpace space = ColorSpace::sRGB;
        bool isLinear = false;
        RenderStatus status = loadBufferImage(local, image, &space, &isLinear);
        if (status != RenderStatus::Ok) return status;
        status = ensureLinear(image, space, &isLinear);
        if (status != RenderStatus::Ok) return status;
        if (hasDisplayLensMetadata_) {
            ensureLensDatabase();
            (void)applyDisplayLensCorrection(image, lensDatabase_,
                displayLensMetadata_, lensCorrection_, displayLensOrientation_);
        }
        const auto outSize = geometryOutputSize(image.width, image.height, geometry_);
        const int outW = outSize.first;
        const int outH = outSize.second;
        if (outW <= 0 || outH <= 0) {
            outResult.availability = WbProbeAvailability::Unavailable;
            return RenderStatus::Ok;
        }
        const auto sampler = makeGeometrySampler(image.width, image.height, geometry_);
        const auto reader = [&](int sx, int sy) { return image.at(sx, sy); };
        const int cx = static_cast<int>(std::lround(double(query.normX) * (outW - 1)));
        const int cy = static_cast<int>(std::lround(double(query.normY) * (outH - 1)));

        double sumR = 0.0, sumG = 0.0, sumB = 0.0;
        for (int dy = -half; dy <= half; ++dy) {
            const int py = cy + dy;
            if (py < 0 || py >= outH) continue;
            for (int dx = -half; dx <= half; ++dx) {
                const int px = cx + dx;
                if (px < 0 || px >= outW) continue;
                const RGB srgb = sampler(px, py, reader);
                if (!std::isfinite(srgb.r) || !std::isfinite(srgb.g) || !std::isfinite(srgb.b) ||
                    std::max({srgb.r, srgb.g, srgb.b}) >= 0.98f) {
                    ++outResult.rejectedOverexposedCount;
                    continue;
                }
                sumR += srgb.r;
                sumG += srgb.g;
                sumB += srgb.b;
                ++outResult.validPixelCount;
            }
        }
        if (outResult.validPixelCount == 0) {
            outResult.availability = WbProbeAvailability::Overexposed;
            return RenderStatus::Ok;
        }
        const double count = static_cast<double>(outResult.validPixelCount);
        const RGB mean(static_cast<float>(sumR / count), static_cast<float>(sumG / count), static_cast<float>(sumB / count));
        outResult.sampledRgb = {mean.r, mean.g, mean.b};

        constexpr double eps = 1e-5;
        const double r = std::max<double>(mean.r, eps);
        const double g = std::max<double>(mean.g, eps);
        const double b = std::max<double>(mean.b, eps);
        const double m = std::clamp(std::log2(b / r), -2.25, 0.87);
        const double temp = std::clamp(6500.0 / (1.0 - m), 2000.0, 50000.0);
        const double tint = std::clamp(600.0 * std::log2(g / std::sqrt(r * b)), -150.0, 150.0);
        const RGB gain = hdrRelativeWhiteBalance(static_cast<float>(temp), static_cast<float>(tint));
        outResult.temperature = static_cast<float>(temp);
        outResult.tint = static_cast<float>(tint);
        outResult.wbMul = {gain.r / gain.g, 1.0f, gain.b / gain.g};
        outResult.availability = WbProbeAvailability::Available;
        return RenderStatus::Ok;
    } catch (const ProcessingCancelled&) {
        return RenderStatus::Cancelled;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::setViewportRoi(const ViewportRoiConfig& roi) noexcept {
    if (!roi.enabled) {
        viewportRoi_ = {};
        return RenderStatus::Ok;
    }
    if (!std::isfinite(roi.normX0) || !std::isfinite(roi.normY0) ||
        !std::isfinite(roi.normX1) || !std::isfinite(roi.normY1) ||
        roi.normX0 < 0.0 || roi.normY0 < 0.0 ||
        roi.normX1 > 1.0 || roi.normY1 > 1.0 ||
        roi.normX0 >= roi.normX1 || roi.normY0 >= roi.normY1) {
        return RenderStatus::InvalidArgument;
    }
    viewportRoi_ = roi;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::processPreviewRoi(
    const RenderParams& params,
    OwnedPixelBuffer* outBuffer,
    std::shared_ptr<LUT3D> lut,
    std::shared_ptr<const DcpLook> dcp,
    bool displayInput,
    bool normalX3f,
    bool waveletActive,
    int chromaMode,
    bool basicV3,
    float exposure,
    const RGB& wb
) {
    if (!outBuffer) return RenderStatus::InvalidArgument;
    RenderParams local = params;
    ImageData image;
    ImageData guideSeed;
    ColorSpace colorSpace = ColorSpace::sRGB;
    bool isLinear = false;
    int canvasW = 0;
    int canvasH = 0;

    if (local.inputType == RenderInputType::Raw) {
        RenderStatus status = loadRawImage(local, image, &colorSpace, &isLinear, false, true, true);
        if (status != RenderStatus::Ok) return status;
        if (rawCache_.width <= 0 || rawCache_.height <= 0 || rawCache_.pixels.empty()) {
            return RenderStatus::ProcessingError;
        }
        canvasW = rawCache_.width;
        canvasH = rawCache_.height;
        lastRenderRendered_ = true;
        lastRenderWasRaw_ = true;
        lastRenderWasNormalX3f_ = normalX3f;
    } else {
        canvasW = static_cast<int>(local.inputWidth);
        canvasH = static_cast<int>(local.inputHeight);
        if (canvasW <= 0 || canvasH <= 0 || !local.inputPixels ||
            exceedsOutputPixelCap(local.inputWidth, local.inputHeight)) {
            return RenderStatus::InvalidArgument;
        }
        colorSpace = local.inputColorSpace;
        isLinear = local.inputIsLinear;
    }

    const auto native = geometryOutputSize(canvasW, canvasH, geometry_);
    if (native.first <= 0 || native.second <= 0) return RenderStatus::InvalidArgument;
    const uint32_t nativeWidth = static_cast<uint32_t>(native.first);
    const uint32_t nativeHeight = static_cast<uint32_t>(native.second);
    const auto plan = computeOutputRoiPlan(native.first, native.second,
        viewportRoi_.normX0, viewportRoi_.normY0, viewportRoi_.normX1, viewportRoi_.normY1,
        viewportRoi_.maxOutputLongEdge);
    if (!plan.valid()) return RenderStatus::InvalidArgument;

    const BasicToneV3 basicTone{-local.highlights, local.shadows};
    const bool basicToneActive = basicV3 && basicTone.active();
    const bool needGuides = basicToneActive || atmosphere_.dehaze != 0.0f || atmosphere_.clarity != 0.0f || filmOptics_.active();

    int halo = geometry_.active() ? 4 : 2;
    if (defringe_.active()) halo += 4;
    if (waveletActive) halo += 96;
    if (chromaMode != 0) halo += 32;
    if (local.noiseReduction > 0.0f || local.sharpening > 0.0f) halo += 16;
    if (atmosphere_.texture != 0.0f) halo += 14;
    if (sharpenV2_.luminanceV2 && local.sharpening > 0.0f) halo += 12;

    const auto srcRect = computeGeometrySourceBounds(canvasW, canvasH, geometry_,
        plan.ox0, plan.oy0, plan.ox1, plan.oy1, halo);
    if (srcRect.empty()) return RenderStatus::InvalidArgument;

    const bool needsFullDisplayLens = local.inputType == RenderInputType::DisplayBuffer &&
        hasDisplayLensMetadata_ && lensCorrection_.active();

    if (local.inputType == RenderInputType::Raw) {
        image = extractImageSubRect(rawCache_, srcRect);
        if (image.width <= 0 || image.height <= 0) return RenderStatus::ProcessingError;
    } else if (needsFullDisplayLens) {
        RenderStatus status = loadBufferImage(local, image, &colorSpace, &isLinear);
        if (status != RenderStatus::Ok) return status;
        lastRenderRendered_ = true;
        lastRenderWasRaw_ = false;
        lastRenderWasNormalX3f_ = false;
        status = ensureLinear(image, colorSpace, &isLinear);
        if (status != RenderStatus::Ok) return status;
        ensureLensDatabase();
        lensReport_ = applyDisplayLensCorrection(image, lensDatabase_,
            displayLensMetadata_, lensCorrection_, displayLensOrientation_);
        if (needGuides) {
            const int longest = std::max(image.width, image.height);
            if (longest > 1024) {
                const double gs = 1024.0 / double(longest);
                guideSeed = resizeBilinear(image,
                    std::max(1u, static_cast<uint32_t>(std::lround(image.width * gs))),
                    std::max(1u, static_cast<uint32_t>(std::lround(image.height * gs))));
            } else {
                guideSeed = image;
            }
            ColorConverter().convertImage(guideSeed, colorSpace, ColorSpace::sRGB);
        }
        image = extractImageSubRect(image, srcRect);
    } else {
        RenderStatus status = loadBufferImageROI(local, srcRect, image, &colorSpace, &isLinear);
        if (status != RenderStatus::Ok) return status;
        lastRenderRendered_ = true;
        lastRenderWasRaw_ = false;
        lastRenderWasNormalX3f_ = false;
    }

    RenderStatus status = RenderStatus::Ok;
    const ColorSpace rawColorSpace = colorSpace;
    const bool rawIsLinear = isLinear;
    status = ensureLinear(image, colorSpace, &isLinear);
    if (status != RenderStatus::Ok) return status;
    checkProcessingCancellation();
    if (colorSpace == ColorSpace::SonyNative) return RenderStatus::Unsupported;

    // Bound large intermediate ROI work patches (e.g. slight zoom on ultra-high-MP sensors)
    // while keeping strict 1:1 source pixels whenever close to or beyond 1:1 magnification.
    const double outScaleX = double(plan.outputWidth) / double(plan.nativeWidth());
    const double outScaleY = double(plan.outputHeight) / double(plan.nativeHeight());
    const double uniformOutScale = std::min(1.0, std::max(outScaleX, outScaleY));
    if (uint64_t(image.width) * uint64_t(image.height) > 6000000ULL && uniformOutScale < 0.999) {
        const double workScale = std::clamp(std::max(uniformOutScale * 1.15, 0.25), 0.25, 1.0);
        if (workScale < 0.999) {
            const uint32_t wW = std::max(1u, static_cast<uint32_t>(std::lround(image.width * workScale)));
            const uint32_t wH = std::max(1u, static_cast<uint32_t>(std::lround(image.height * workScale)));
            image = resizeBilinear(image, wW, wH);
        }
    }

    BasicToneV3Field basicField;
    DehazeAnalysis dehazeState;
    ClarityField clarityField;
    FilmOpticsField opticsField;
    if (needGuides) {
        ImageData guideImage;
        if (local.inputType == RenderInputType::Raw) {
            uint32_t baselineBits = 0;
            static_assert(sizeof(baselineBits) == sizeof(baselineEv_));
            std::memcpy(&baselineBits, &baselineEv_, sizeof(baselineBits));
            const std::string cacheKey = rawKey_ + ":baseline:" + std::to_string(baselineBits);
            if (roiGuideCache_.key != cacheKey || roiGuideCache_.linearSrgb.pixels.empty()) {
                const int longest = std::max(canvasW, canvasH);
                if (longest > 1024) {
                    const double gs = 1024.0 / double(longest);
                    roiGuideCache_.linearSrgb = resizeBilinear(rawCache_,
                        std::max(1u, static_cast<uint32_t>(std::lround(canvasW * gs))),
                        std::max(1u, static_cast<uint32_t>(std::lround(canvasH * gs))));
                } else {
                    roiGuideCache_.linearSrgb = rawCache_;
                }
                ColorSpace gSpace = rawColorSpace;
                bool gLinear = rawIsLinear;
                status = ensureLinear(roiGuideCache_.linearSrgb, gSpace, &gLinear);
                if (status != RenderStatus::Ok) return status;
                ColorConverter().convertImage(roiGuideCache_.linearSrgb, gSpace, ColorSpace::sRGB);
                roiGuideCache_.key = cacheKey;
            }
            guideImage = roiGuideCache_.linearSrgb;
        } else if (!guideSeed.pixels.empty()) {
            guideImage = std::move(guideSeed);
        } else {
            ColorSpace gSpace = ColorSpace::sRGB;
            bool gLinear = false;
            status = loadBufferImageDownsampled(local, 1024, guideImage, &gSpace, &gLinear);
            if (status != RenderStatus::Ok) return status;
            status = ensureLinear(guideImage, gSpace, &gLinear);
            if (status != RenderStatus::Ok) return status;
            ColorConverter().convertImage(guideImage, gSpace, ColorSpace::sRGB);
        }

        parallelPixelRanges(guideImage.pixels.size(), [&](size_t first, size_t last) {
            for (size_t i = first; i < last; ++i) {
                applyExposureAndWhiteBalance(guideImage.pixels[i], exposure, wb);
            }
        });
        applyCameraCalibration(guideImage, cameraCalibration_);
        RenderParams guideParams = local;
        if (basicToneActive) {
            basicField = buildBasicToneV3Field(guideImage, canvasW, canvasH);
            if (atmosphere_.dehaze != 0.0f || atmosphere_.clarity != 0.0f || filmOptics_.active()) {
                applyBasicToneV3WithField(guideImage, basicTone, basicField);
            }
            guideParams.highlights = guideParams.shadows = 0.0f;
        }
        if (atmosphere_.dehaze != 0.0f || atmosphere_.clarity != 0.0f || filmOptics_.active()) {
            if (defringe_.active()) {
                applyDefringe(guideImage, defringe_);
            }
            GpuConfig cpuLook = gpuConfig_;
            cpuLook.mode = GpuMode::Off;
            status = applyPhotoLook(guideImage, lut, dcp, guideParams.lutStrength, displayInput, cpuLook);
            if (status != RenderStatus::Ok) return status;
            checkProcessingCancellation();
            if (atmosphere_.dehaze != 0.0f) {
                dehazeState = buildDehazeAnalysis(guideImage, canvasW, canvasH, processingVersion_);
                if (atmosphere_.clarity != 0.0f || filmOptics_.active()) {
                    applyDehazeWithAnalysis(guideImage, atmosphere_.dehaze, dehazeState);
                }
            }
            if (atmosphere_.clarity != 0.0f || filmOptics_.active()) {
                applyBwMixer(guideImage, bwMixer_);
                if (basicV3) applyBasicBlackWhiteV3(guideImage, toneControls_);
                else applyBlackWhite(guideImage, toneControls_);
                applyToneAdjustments(guideImage, guideParams, channelCurves_, basicV3);
                if (basicV3) applyBasicVibranceV3(guideImage, toneControls_.vibrance);
                else applyVibrance(guideImage, toneControls_);
                applyHsl(guideImage, hsl_);
                applyPointColor(guideImage, pointColor_);
                applySelectiveColor(guideImage, selectiveColor_);
                applyColorGrading(guideImage, colorGrading_);
                if (atmosphere_.clarity != 0.0f) {
                    clarityField = buildClarityField(guideImage, canvasW, canvasH, processingVersion_);
                }
                if (filmOptics_.active()) {
                    if (atmosphere_.clarity != 0.0f) {
                        applyClarityWithField(guideImage, atmosphere_.clarity, clarityField);
                    }
                    if (atmosphere_.texture != 0.0f) {
                        applyTexture(guideImage, atmosphere_.texture, canvasW, canvasH);
                    }
                    opticsField = buildFilmOpticsField(guideImage, canvasW, canvasH, filmOptics_);
                }
            }
        }
    }

    const SubRectMap roiMap{
        canvasW, canvasH,
        double(srcRect.x0), double(srcRect.y0),
        double(srcRect.width()), double(srcRect.height())
    };

    if (waveletActive) {
        checkProcessingCancellation();
        ColorConverter converter;
        converter.convertImage(image, colorSpace, ColorSpace::sRGB);
        WaveletDenoiseDiagnostics diagnostics;
        const ImageData* noiseSource = (local.inputType == RenderInputType::Raw && !rawCache_.pixels.empty())
            ? &rawCache_ : nullptr;
        const auto wResult = applyWaveletDenoise(image, waveletDenoise_, &diagnostics,
            GpuMode::Off, nullptr, "", nullptr, colorSpace, noiseSource);
        checkProcessingCancellation();
        if (wResult != ErrorCode::Success) return mapErrorCode(wResult);
        colorSpace = ColorSpace::sRGB;
    }

    local.lut = lut;
    local.dcp = dcp;
    local.relativeWB = wb;
    local.effects = photoEffects_;
    local.filmOptics = filmOptics_;
    local.atmosphere = atmosphere_;
    local.chromaDenoise = chromaMode;
    local.preserveSourceResolution = waveletActive || geometry_.active();
    local.hsl = hsl_;
    local.toneControls = toneControls_;
    local.colorGrading = colorGrading_;
    local.calibration = cameraCalibration_;
    local.pointColor = pointColor_;
    local.selectiveColor = selectiveColor_;
    local.bw = bwMixer_;
    local.sharpenV2 = sharpenV2_;
    local.defringe = defringe_;
    local.atmosphereSourceWidth = canvasW;
    local.atmosphereSourceHeight = canvasH;
    local.processingVersion = processingVersion_;
    local.customCurve = toneCurve_;
    local.channelCurves = channelCurves_;
    local.curveApplyToLuminosity = curveApplyToLuminosity_;
    local.parametricCurve = parametricCurve_;
    local.aiDenoiseBlend = aiDenoiseBlend_;
    local.outputSharpening = outputSharpening_;

    ColorConverter converter;
    converter.convertImage(image, colorSpace, ColorSpace::sRGB);
    colorSpace = ColorSpace::sRGB;
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) applyExposureAndWhiteBalance(image.pixels[i], exposure, wb);
    });
    applyCameraCalibration(image, cameraCalibration_);
    if (basicToneActive) {
        applyBasicToneV3WithField(image, basicTone, basicField, roiMap);
        local.highlights = local.shadows = 0.0f;
    }
    if (defringe_.active()) {
        applyDefringe(image, defringe_);
    }

    GpuConfig lookConfig = gpuConfig_;
    lookConfig.mode = GpuMode::Off;
    status = applyPhotoLook(image, lut, dcp, local.lutStrength, displayInput, lookConfig);
    if (status != RenderStatus::Ok) return status;
    checkProcessingCancellation();
    if (atmosphere_.dehaze != 0.0f) {
        applyDehazeWithAnalysis(image, atmosphere_.dehaze, dehazeState, roiMap);
    }
    applyBwMixer(image, bwMixer_);
    if (basicV3) applyBasicBlackWhiteV3(image, toneControls_);
    else applyBlackWhite(image, toneControls_);
    applyToneAdjustments(image, local, channelCurves_, basicV3);
    if (basicV3) applyBasicVibranceV3(image, toneControls_.vibrance);
    else applyVibrance(image, toneControls_);
    applyHsl(image, hsl_);
    applyPointColor(image, pointColor_);
    applySelectiveColor(image, selectiveColor_);
    applyColorGrading(image, colorGrading_);
    const auto chromaResult = applyChromaDenoiseWorking(image, chromaMode);
    checkProcessingCancellation();
    if (chromaResult != ErrorCode::Success) return mapErrorCode(chromaResult);
    const int texDiagW = std::max(1, static_cast<int>(std::lround(
        roiMap.fullWidth * double(image.width) / std::max(1.0, roiMap.sourceSpanX))));
    const int texDiagH = std::max(1, static_cast<int>(std::lround(
        roiMap.fullHeight * double(image.height) / std::max(1.0, roiMap.sourceSpanY))));
    applyDetailAdjustments(image, local.noiseReduction, local.sharpening, atmosphere_.clarity,
        canvasW, canvasH, processingVersion_,
        atmosphere_.clarity != 0.0f ? &clarityField : nullptr, roiMap,
        atmosphere_.texture, sharpenV2_, texDiagW, texDiagH,
        filmOptics_, filmOptics_.active() ? &opticsField : nullptr);
    checkProcessingCancellation();
    applyPhotoEffectsROI(image, photoEffects_, roiMap);

    image = applyGeometryROI(image, srcRect, canvasW, canvasH, geometry_, plan);
    if (image.width <= 0 || image.height <= 0) return RenderStatus::ProcessingError;
    checkProcessingCancellation();
    lastBackend_ = RenderBackend::Cpu;
    status = writeOutputBuffer(local, image, outBuffer);
    if (status == RenderStatus::Ok) {
        geometryWidth_ = nativeWidth;
        geometryHeight_ = nativeHeight;
        viewportRoiResult_.active = true;
        viewportRoiResult_.nativeX0 = static_cast<uint32_t>(plan.ox0);
        viewportRoiResult_.nativeY0 = static_cast<uint32_t>(plan.oy0);
        viewportRoiResult_.nativeX1 = static_cast<uint32_t>(plan.ox1);
        viewportRoiResult_.nativeY1 = static_cast<uint32_t>(plan.oy1);
        viewportRoiResult_.fullNativeWidth = nativeWidth;
        viewportRoiResult_.fullNativeHeight = nativeHeight;
    }
    return status;
}

RenderStatus Pipeline::processImpl(
    const RenderParams& params,
    OwnedPixelBuffer* outBuffer,
    ImageData* preHsl,
    std::shared_ptr<LUT3D> previewLut,
    MigrationFrame* migrationFrame,
    ImageData* outImage
) {
    x3fError_.clear();
    unsupportedReason_ = UnsupportedReason::None;
    gpuFallbackReason_ = GpuFallbackReason::None;
    gpuErrorDetail_.clear();
    checkProcessingCancellation();
    geometryWidth_ = geometryHeight_ = 0;
    viewportRoiResult_ = {};

    RenderStatus status = validateRenderParams(params, outBuffer != nullptr || outImage != nullptr);
    if (status != RenderStatus::Ok) return status;

    status = validateRenderParamsSize(params);
    if (status != RenderStatus::Ok) return status;

    status = validateRenderOutputFormat(params);
    if (status != RenderStatus::Ok) return status;

    RenderParams local = params;
    if (local.inputType == RenderInputType::DisplayBuffer &&
        local.wbMode == RenderWhiteBalanceMode::Camera &&
        local.temperature == 6500.0f &&
        local.tint == 0.0f &&
        rasterRelativeWbActive_) {
        local.wbMode = RenderWhiteBalanceMode::Relative;
        local.temperature = rasterRelativeTemp_;
        local.tint = rasterRelativeTint_;
    }
    if (toneCurve_.custom() && local.toneCurve != 0.0f) return RenderStatus::InvalidArgument;
    const bool cpuAnalysis = preHsl != nullptr;
    const auto effectiveGpuMode = cpuAnalysis ? GpuMode::Off : gpuConfig_.mode;
    const bool normalX3f = local.inputType == RenderInputType::Raw &&
        isNormalX3f(local.inputPath.c_str(), x3fMode_);
    const bool displayInput = local.inputType == RenderInputType::DisplayBuffer || normalX3f;
    const bool useAI = aiEnabled();
    if (useAI && local.inputType != RenderInputType::Raw) return RenderStatus::Unsupported;
    if (local.inputType != RenderInputType::Raw) {
        lensReport_ = {};
        if (lensCorrection_.active()) lensReport_.state = LensCorrectionState::UnsupportedInput;
    }
    const bool unsupportedDisplayLens = lensCorrection_.active() &&
        (normalX3f || !hasDisplayLensMetadata_);
    const int chromaMode = useAI ? 0 : chromaDenoise_;
    const FilmOpticsOptions effectiveFilmOptics =
        (hasCommittedEditState_ || !filmOptics_.isDefault() || local.filmOptics.isDefault())
            ? filmOptics_ : local.filmOptics;
    const bool basicV3 = processingVersion_ == ProcessingVersion::BasicV3;
    const BasicToneV3 basicTone{-local.highlights, local.shadows};
    ActiveFeatures features;
    features.wavelet = !useAI && waveletDenoise_.active();
    features.chromaDenoise = chromaMode != 0;
    features.effects = photoEffects_.active();
    features.filmOptics = effectiveFilmOptics.active();
    features.hsl = hsl_.active();
    features.toneControls = toneControls_.active();
    features.atmosphere = atmosphere_.active();
    features.basicTone = basicV3 && basicTone.active();
    features.basicControls = basicV3 && (basicTone.active() || local.contrast != 1.0f || features.toneControls);
    features.colorGrading = colorGrading_.active();
    features.calibration = cameraCalibration_.active();
    features.bwMixer = bwMixer_.active();
    features.pointColor = pointColor_.active();
    features.selectiveColor = selectiveColor_.active();
    features.geometry = geometry_.active();
    features.masterCurve = toneCurve_.active();
    features.channelCurves = std::any_of(channelCurves_.begin(), channelCurves_.end(),
        [](const auto& curve) { return curve.active(); });
    features.defringe = defringe_.active();
    features.sharpenV2Luminance = sharpenV2_.luminanceV2 && local.sharpening > 0.0f;
    const bool waveletActive = features.wavelet;
    const bool effectsActive = features.effects;
    const bool filmOpticsActive = features.filmOptics;
    const bool atmosphereActive = features.atmosphere;
    const bool basicToneActive = features.basicTone;
    const bool neighborhoodActive = features.neighborhood();
    const bool geometryActive = features.geometry;
    // 预览到缓冲（含未开启视口标志的预览）必须保留大图 RAW 缓存供下一次渲染复用；
    // 只有导出才把工作图移走缓存来省一次整幅拷贝。
    const bool previewToBuffer = local.intent == RenderIntent::Preview &&
        local.outputTarget == RenderOutputTarget::Buffer;
    const bool roiActive = viewportRoi_.enabled && previewToBuffer && !preHsl && !migrationFrame;
    const bool c5Wavelet = waveletActive && usesC5Denoise(waveletDenoise_.processingVersion);

    GpuAdmissionFacts admissionFacts;
    admissionFacts.gpuMode = gpuConfig_.mode;
    admissionFacts.cpuAnalysis = cpuAnalysis;
    admissionFacts.gpuBackendCompiled = kGpuBackendCompiled;
    admissionFacts.displayInput = displayInput;
    admissionFacts.normalX3f = normalX3f;
    admissionFacts.rawNoiseReduction = rawNoiseReduction_ != 0;
    admissionFacts.unsupportedDisplayLens = unsupportedDisplayLens;
    admissionFacts.features = features;
    admissionFacts.masterCurveGpuSupported = toneCurve_.gpuSupported();
    admissionFacts.channelCurvesGpuSupported = std::all_of(channelCurves_.begin(), channelCurves_.end(),
        [](const auto& curve) { return curve.gpuSupported(); });
    admissionFacts.c5Wavelet = c5Wavelet;
    admissionFacts.roiActive = roiActive;
    GpuAdmission admission = admitGpuBeforeLook(admissionFacts);
    gpuFallbackReason_ = admission.fallbackReason;
    if (admission.unsupported) {
        unsupportedReason_ = admission.unsupportedReason;
        if (admission.x3fError != X3fAdmissionError::None) x3fError_ = x3fAdmissionErrorText(admission.x3fError);
        if (!admission.rejectedAtInput) lastBackend_ = RenderBackend::Cpu;
        return RenderStatus::Unsupported;
    }
    local.lutStrength = clampFloat(local.lutStrength, 0.0f, 2.0f);
    lastBackend_ = RenderBackend::Cpu;
    bool viewportPreview = viewportPreview_ && previewToBuffer && !roiActive;
    const bool fastWavelet = !neighborhoodActive && !geometryActive && waveletActive && !effectsActive &&
        !filmOpticsActive && chromaMode == 0 && interactivePreview_ &&
        local.intent == RenderIntent::Preview && local.outputTarget == RenderOutputTarget::Buffer;
    if (needsSourceSizePreflight(local)) {
        uint32_t sourceWidth = local.inputWidth;
        uint32_t sourceHeight = local.inputHeight;
        bool hasSourceSize = local.inputType != RenderInputType::Raw;
        if (!hasSourceSize) {
            const bool legacySonyCrop = sony2fuji::usesLegacySonyCrop(processingVersion_);
            std::string baseSourceKey;
            if (buildRawSourceIdentityKey(local.inputPath.c_str(), legacySonyCrop, baseSourceKey)) {
                const std::string probeKey = baseSourceKey + ":x3f:" + std::to_string(static_cast<int>(x3fMode_));
                if (probedHeaderKey_ != probeKey) {
                    uint32_t probedW = 0, probedH = 0;
                    const auto probeRes = probeInputHeaderSize(
                        local.inputPath.c_str(), legacySonyCrop, x3fMode_, probedW, probedH);
                    if (probeRes != ProbeSizeResult::OpenFailed) {
                        probedHeaderKey_ = probeKey;
                        probedHeaderResult_ = probeRes;
                        probedHeaderWidth_ = probedW;
                        probedHeaderHeight_ = probedH;
                    }
                }
                if (probedHeaderKey_ == probeKey && probedHeaderResult_ == ProbeSizeResult::Probed) {
                    sourceWidth = probedHeaderWidth_;
                    sourceHeight = probedHeaderHeight_;
                    hasSourceSize = true;
                }
            }
        }
        if (hasSourceSize) {
            if (sourceWidth > static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
                sourceHeight > static_cast<uint32_t>(std::numeric_limits<int32_t>::max())) {
                return RenderStatus::InvalidArgument;
            }
            const auto native = geometryOutputSize(
                static_cast<int>(sourceWidth), static_cast<int>(sourceHeight), geometry_);
            uint32_t targetWidth = 0, targetHeight = 0;
            status = computeTargetSize(local, static_cast<uint32_t>(native.first), static_cast<uint32_t>(native.second),
                &targetWidth, &targetHeight);
            if (status != RenderStatus::Ok) return status;
        }
    }

    const bool useLut = !local.lutPath.empty() && local.lutStrength > 0.0f;
    std::shared_ptr<LUT3D> lut;
    std::shared_ptr<const DcpLook> dcp;
    if (useLut) {
        if (previewLut) {
            lut = std::move(previewLut);
        } else if (LUTParser::detectFormat(local.lutPath) == "rlook") {
            dcp = DcpLook::loadCached(local.lutPath);
            if (!dcp) return RenderStatus::Unsupported;
        } else {
            status = loadLUT(local.lutPath.c_str(), &lut);
            if (status != RenderStatus::Ok) return status;
            if (!lut->isPhotoLUT()) return RenderStatus::Unsupported;
        }
    }

    const bool contractCPU = lut && lut->requiresCPU();
    GpuLookTraits lookTraits;
    lookTraits.dcpLook = dcp != nullptr;
    lookTraits.lutRequiresCpu = contractCPU;
    admission = admitGpuAfterLook(admissionFacts, admission, lookTraits);
    gpuFallbackReason_ = admission.fallbackReason;
    if (admission.unsupported) {
        unsupportedReason_ = admission.unsupportedReason;
        return RenderStatus::Unsupported;
    }
    const bool sessionGpuPipeline = admission.sessionGpuPipeline;
    bool gpuPipeline = admission.gpuPipeline;
    checkProcessingCancellation();

    RGB wb(1.0f, 1.0f, 1.0f);
    float exposure = 1.0f;
    computeEffectiveWbAndExposure(local, displayInput, wb, exposure);
    if (roiActive) {
        return processPreviewRoi(local, outBuffer, std::move(lut), std::move(dcp),
            displayInput, normalX3f, waveletActive, chromaMode, basicV3, exposure, wb);
    }

    ImageData image;
    ColorSpace colorSpace = ColorSpace::sRGB;
    bool isLinear = false;
    if (local.inputType == RenderInputType::Raw) {
        bool wbMatrixShortcutUsed = false;
        if (interactivePreview_ && viewportPreview && previewToBuffer &&
            !geometryActive && !waveletActive && !roiActive && !normalX3f && !useAI &&
            !rawDisplayReferred_ && !rawCache_.pixels.empty() && rawCacheWbValid_ && rawProcessor_ &&
            local.wbMode != RenderWhiteBalanceMode::Auto &&
            rawNativeSize_.first > 0 && rawNativeSize_.second > 0) {
            std::string baseSourceKey, fileKey, wbBaseKey, previewExposureKey;
            const bool keysOk = buildRawCacheWbKeys(local, baseSourceKey, fileKey, wbBaseKey, previewExposureKey);
            const bool cachedHalfSize = std::pair{rawCache_.width, rawCache_.height} != rawNativeSize_;
            previewExposureKey += cachedHalfSize ? ":half" : ":full";
            const bool exposureOk = rawExposureMode_ != RawExposureMode::Preview ||
                (rawCacheAnchoredPreview_ &&
                 (local.wbMode == RenderWhiteBalanceMode::Camera || local.wbMode == RenderWhiteBalanceMode::Temperature) &&
                 previewExposureKey_ == previewExposureKey);
            if (keysOk && wbBaseKey == rawCacheWbBaseKey_ && exposureOk) {
                bool sizeOk = std::pair{rawCache_.width, rawCache_.height} == rawNativeSize_;
                if (!sizeOk) {
                    uint32_t reqW = 0, reqH = 0;
                    const RenderStatus szStatus = computeTargetSize(local,
                        static_cast<uint32_t>(rawNativeSize_.first),
                        static_cast<uint32_t>(rawNativeSize_.second), &reqW, &reqH);
                    sizeOk = szStatus == RenderStatus::Ok &&
                        reqW <= static_cast<uint32_t>(rawCache_.width) &&
                        reqH <= static_cast<uint32_t>(rawCache_.height);
                }
                if (sizeOk) {
                    float targetMul[3]{};
                    bool hasTarget = false;
                    if (local.wbMode == RenderWhiteBalanceMode::Camera) {
                        std::copy_n(rawCacheAsShotWbMul_.data(), 3, targetMul);
                        hasTarget = true;
                    } else if (local.wbMode == RenderWhiteBalanceMode::Temperature) {
                        hasTarget = rawProcessor_->computeTemperatureWhiteBalanceMultipliers(
                            local.temperature, local.tint, targetMul);
                    } else if (local.wbMode == RenderWhiteBalanceMode::Custom &&
                               std::isfinite(local.wbMul[0]) && local.wbMul[0] > 0.0f &&
                               std::isfinite(local.wbMul[1]) && local.wbMul[1] > 0.0f &&
                               std::isfinite(local.wbMul[2]) && local.wbMul[2] > 0.0f) {
                        targetMul[0] = local.wbMul[0] / local.wbMul[1];
                        targetMul[1] = 1.0f;
                        targetMul[2] = local.wbMul[2] / local.wbMul[1];
                        hasTarget = true;
                    }
                    if (hasTarget) {
                        float ratio[3]{};
                        bool validRatio = true;
                        for (int c = 0; c < 3; ++c) {
                            ratio[c] = targetMul[c] / rawCacheAppliedWbMul_[c];
                            if (!std::isfinite(ratio[c]) || ratio[c] <= 0.0f) {
                                validRatio = false;
                                break;
                            }
                        }
                        if (validRatio) {
                            if (std::abs(ratio[0] - 1.0f) > 1e-6f || std::abs(ratio[2] - 1.0f) > 1e-6f) {
                                ColorConverter::Matrix3x3 M;
                                for (int r = 0; r < 3; ++r)
                                    for (int c = 0; c < 3; ++c)
                                        M[r][c] = rawCacheCamToSrgb_[r][c];
                                const auto M_inv = ColorConverter::invertMatrix(M);
                                const ColorConverter::Matrix3x3 D{{
                                    {ratio[0], 0.0f, 0.0f},
                                    {0.0f, ratio[1], 0.0f},
                                    {0.0f, 0.0f, ratio[2]}
                                }};
                                const auto W = ColorConverter::multiplyMatrices(M, ColorConverter::multiplyMatrices(D, M_inv));
                                const auto B = ColorConverter::getConversionMatrix(ColorSpace::AdobeRGB, ColorSpace::sRGB);
                                const auto T = ColorConverter::multiplyMatrices(W, B);
                                bool finiteT = true;
                                for (const auto& row : T)
                                    for (float v : row)
                                        if (!std::isfinite(v)) finiteT = false;
                                if (finiteT) {
                                    local.hasCustomToSrgb = true;
                                    local.customToSrgb = T;
                                    wbMatrixShortcutUsed = true;
                                }
                            } else {
                                wbMatrixShortcutUsed = true;
                            }
                        }
                    }
                }
            }
        }
        if (wbMatrixShortcutUsed) {
            image.width = rawCache_.width;
            image.height = rawCache_.height;
            colorSpace = ColorSpace::AdobeRGB;
            isLinear = true;
            lensReport_ = rawLensReport_;
            status = RenderStatus::Ok;
        } else {
            // Atmosphere 的分析尺度和 native 元信息仍以精确 RAW 为准；BasicToneV3 在交互视口预览时可复用 half-size，
            // settled 与导出仍走精确 RAW，避免改变空间分析尺度，同时保留 Preview+Buffer 语义。
            const bool forceFullRes = geometryActive || atmosphereActive ||
                (basicToneActive && !(interactivePreview_ && viewportPreview));
            status = loadRawImage(local, image, &colorSpace, &isLinear, false, true, forceFullRes);
            // Use a full decode when the viewport needs more pixels than the RAW proxy provides.
            if (status == RenderStatus::Ok && viewportPreview &&
                std::pair{image.width, image.height} != rawNativeSize_) {
                const auto [sourceWidth, sourceHeight] = rawNativeSize_;
                uint32_t width = 0, height = 0;
                status = computeTargetSize(local, static_cast<uint32_t>(sourceWidth), static_cast<uint32_t>(sourceHeight), &width, &height);
                if (status == RenderStatus::Ok && (width > uint32_t(image.width) || height > uint32_t(image.height))) {
                    status = loadRawImage(local, image, &colorSpace, &isLinear, false, true, true);
                }
            }
            if (status == RenderStatus::Ok && !viewportPreview && (!gpuPipeline || waveletActive)) {
                const bool large = rawCache_.pixels.size() * sizeof(RGB) > WaveletRenderCache::defaultPreviewBudget;
                // C5 失败不会破坏工作图；Legacy 的 GPU 重试仍需要原始 RAW。
                const bool reloadableWavelet = waveletActive &&
                    !usesC5Denoise(waveletDenoise_.processingVersion);
                if (large && !previewToBuffer && !reloadableWavelet && !preHsl) image = std::move(rawCache_);
                else image = rawCache_;
            }
        }
    } else {
        status = loadBufferImage(local, image, &colorSpace, &isLinear);
    }
    if (status != RenderStatus::Ok) return status;
    lastRenderRendered_ = true;
    lastRenderWasRaw_ = local.inputType == RenderInputType::Raw;
    lastRenderWasNormalX3f_ = normalX3f;
    status = ensureLinear(image, colorSpace, &isLinear);
    if (status != RenderStatus::Ok) return status;
    if (local.inputType == RenderInputType::DisplayBuffer && hasDisplayLensMetadata_) {
        ensureLensDatabase();
        lensReport_ = applyDisplayLensCorrection(image, lensDatabase_,
            displayLensMetadata_, lensCorrection_, displayLensOrientation_);
    }
    checkProcessingCancellation();
    if (colorSpace == ColorSpace::SonyNative) return RenderStatus::Unsupported;
    const int atmosphereSourceWidth = image.width;
    const int atmosphereSourceHeight = image.height;
    const auto [canvasWidth, canvasHeight] = viewportPreview && local.inputType == RenderInputType::Raw
        ? rawNativeSize_ : std::pair{image.width, image.height};
    const auto native = geometryOutputSize(canvasWidth, canvasHeight, geometry_);
    const uint32_t nativeWidth = static_cast<uint32_t>(native.first);
    const uint32_t nativeHeight = static_cast<uint32_t>(native.second);
    // 预览长边封顶到裁剪旋转后的 native 长边：neighborhood 与纯几何预览共用该契约，
    // 显式 FIT_LONG_EDGE/EXACT（FINAL）不受影响。
    if ((neighborhoodActive || geometryActive) && local.intent == RenderIntent::Preview &&
        local.previewLongEdge > 0) {
        local.previewLongEdge = std::min(local.previewLongEdge, std::max(nativeWidth, nativeHeight));
    }
    uint32_t targetWidth = 0, targetHeight = 0;
    status = computeTargetSize(local, nativeWidth, nativeHeight, &targetWidth, &targetHeight);
    if (status != RenderStatus::Ok) return status;

    ImageData viewportNoiseSource;
    const ImageData* waveletNoiseSource = nullptr;
    if (viewportPreview) {
        uint32_t width = targetWidth, height = targetHeight;
        // Atmosphere 只近似缩小预览；原生及放大请求保留原请求的尺寸和精确输出。
        if (neighborhoodActive && width >= nativeWidth && height >= nativeHeight) {
            viewportPreview = false;
            if (local.inputType == RenderInputType::Raw) image = rawCache_;
        } else {
            const auto& source = local.inputType == RenderInputType::Raw ? rawCache_ : image;
            std::pair<int, int> sourceSize;
            if (geometryActive) {
                sourceSize = geometryViewportSourceSize(source.width, source.height, geometry_, width, height);
            } else {
                const double scale = std::min({1.0, double(source.width) / width, double(source.height) / height});
                width = std::max(1u, static_cast<uint32_t>(std::lround(width * scale)));
                height = std::max(1u, static_cast<uint32_t>(std::lround(height * scale)));
                sourceSize = {static_cast<int>(width), static_cast<int>(height)};
            }
            // 新图可能比上一次视口需求小；后续阶段也必须沿用已限制的尺寸。
            local.previewLongEdge = 0;
            local.sizeMode = RenderSizeMode::Exact;
            local.targetWidth = width;
            local.targetHeight = height;
            // RAW 缓存保持不变，直接读取源像素，避免先拷贝完整大图。
            if (sourceSize.first != source.width || sourceSize.second != source.height) {
                auto reduced = resizeBilinear(source, static_cast<uint32_t>(sourceSize.first),
                    static_cast<uint32_t>(sourceSize.second));
                if (c5Wavelet) {
                    if (local.inputType == RenderInputType::Raw) waveletNoiseSource = &rawCache_;
                    else {
                        viewportNoiseSource = std::move(image);
                        waveletNoiseSource = &viewportNoiseSource;
                    }
                }
                image = std::move(reduced);
            } else if (local.inputType == RenderInputType::Raw) {
                image = source;
            }
        }
    }

    // Absolute RAW WB already ran in camera space. Legacy RGB controls compensate
    // for the chosen illuminant (inverse response), not paint its color onto RGB.
    if (waveletActive) {
        checkProcessingCancellation();
        if (fastWavelet) {
            uint32_t width = 0, height = 0;
            status = computeTargetSize(local, static_cast<uint32_t>(image.width), static_cast<uint32_t>(image.height), &width, &height);
            if (status != RenderStatus::Ok) return status;
            if (width != static_cast<uint32_t>(image.width) || height != static_cast<uint32_t>(image.height))
                image = resizeBilinear(image, width, height);
        }
        const bool cacheable = local.inputType == RenderInputType::Raw && (!fastWavelet || viewportPreview);
        // 相机 WB/FBDD 往返会改变实际曝光锚点，即使 RAW 参数 key 恢复旧值。
        uint32_t baselineBits = 0;
        static_assert(sizeof(baselineBits) == sizeof(baselineEv_));
        std::memcpy(&baselineBits, &baselineEv_, sizeof(baselineBits));
        const auto waveletKey = rawKey_ + ":baseline:" + std::to_string(baselineBits) + (viewportPreview ? ":viewport:" +
            std::to_string(image.width) + "x" + std::to_string(image.height) : "");
        auto* entry = cacheable ? &waveletCache_.select(waveletKey, viewportPreview) : nullptr;
        const bool cachedMatches = entry && entry->matches(waveletDenoise_, gpuConfig_.mode);
        const bool cacheHit = cachedMatches ? (!cpuAnalysis || entry->cpuExecuted)
            : (cpuAnalysis && entry && entry->matches(waveletDenoise_, GpuMode::Off) && entry->cpuExecuted);
        if (cacheHit) {
            image = entry->image;
            ++waveletCache_.diagnostics.outputHits;
        } else {
            // HSL 取样在 Legacy GPU 模式下只计算临时 CPU 参考，不能清空/覆盖已缓存的 GPU 小波输出。
            const bool preserveCachedOutput = cpuAnalysis && cachedMatches;
            if (entry && !preserveCachedOutput) {
                // 失效的整图输出先释放，避免与重算峰值叠加；分析模型仍可复用。
                entry->image = {};
                entry->completed = false;
            }
            ColorConverter converter;
            converter.convertImage(image, colorSpace, ColorSpace::sRGB);
            const bool cpuC5 = usesC5Denoise(waveletDenoise_.processingVersion) &&
                effectiveGpuMode != GpuMode::Force;
            const auto mode = gpuPipeline && !cpuC5 ? GpuMode::Force : GpuMode::Off;
            WaveletDenoiseDiagnostics diagnostics;
            auto filter = [&](GpuMode backend) {
                ++waveletCache_.diagnostics.filterRuns;
                const auto result = applyWaveletDenoise(image, waveletDenoise_, &diagnostics,
                    backend, entry ? &entry->analysis : nullptr, waveletKey,
                    local.inputType == RenderInputType::Raw && !viewportPreview && !fastWavelet &&
                        !rawCache_.pixels.empty() ? &rawCache_ : nullptr,
                    colorSpace, waveletNoiseSource);
                if (result == ErrorCode::Success && diagnostics.applied)
                    ++waveletCache_.diagnostics.appliedRuns;
                if (diagnostics.analysisReused) ++waveletCache_.diagnostics.analysisHits;
                return result;
            };
            lastGpuFilterOutcome() = {};
            auto result = filter(mode);
            checkProcessingCancellation();
            if (result != ErrorCode::Success && mode == GpuMode::Force && !cpuAnalysis &&
                gpuConfig_.mode != GpuMode::Off) {
                const auto filterOutcome = lastGpuFilterOutcome();
                gpuFallbackReason_ = fallbackReasonFromFault(
                    filterOutcome.fault != GpuBackendFault::None
                        ? filterOutcome.fault
                        : GpuBackendFault::FilterError);
                gpuErrorDetail_ = filterOutcome.message;
            }
            const bool fallback = result != ErrorCode::Success &&
                result != ErrorCode::OutOfMemory &&
                effectiveGpuMode == GpuMode::Auto;
            if (fallback) {
                gpuPipeline = false;
                result = filter(GpuMode::Off);
            }
            if (result != ErrorCode::Success) {
                if (result == ErrorCode::Unsupported && mode == GpuMode::Force) {
                    unsupportedReason_ = UnsupportedReason::ForceGpu;
                }
                return mapErrorCode(result);
            }
            if (entry && !preserveCachedOutput) {
                const bool ranCpu = fallback || mode == GpuMode::Off;
                const bool normalUsesCpuWavelet = gpuConfig_.mode != GpuMode::Force &&
                    (!sessionGpuPipeline || usesC5Denoise(waveletDenoise_.processingVersion));
                const auto storeMode = (!fallback && (!cpuAnalysis || normalUsesCpuWavelet))
                    ? gpuConfig_.mode
                    : GpuMode::Off;
                waveletCache_.store(*entry, image, waveletDenoise_, storeMode, ranCpu);
            }
        }
        // 小波及其重试已完成；视口与预览工作缓冲仍需缓存 RAW 供下一次滑杆调整复用，导出才释放。
        if (!viewportPreview && !previewToBuffer && !preHsl &&
            rawCache_.pixels.size() * sizeof(RGB) > WaveletRenderCache::defaultPreviewBudget) {
            rawCache_ = {};
        }
        colorSpace = ColorSpace::sRGB;
    }

    local.lut = lut;
    local.dcp = dcp;
    local.relativeWB = wb;
    local.effects = photoEffects_;
    local.filmOptics = effectiveFilmOptics;
    local.atmosphere = atmosphere_;
    local.chromaDenoise = chromaMode;
    local.preserveSourceResolution = waveletActive || geometryActive || (basicToneActive && !viewportPreview);
    local.hsl = hsl_;
    local.toneControls = toneControls_;
    local.colorGrading = colorGrading_;
    local.calibration = cameraCalibration_;
    local.pointColor = pointColor_;
    local.selectiveColor = selectiveColor_;
    local.bw = bwMixer_;
    local.sharpenV2 = sharpenV2_;
    local.defringe = defringe_;
    local.atmosphereSourceWidth = atmosphereSourceWidth;
    local.atmosphereSourceHeight = atmosphereSourceHeight;
    local.processingVersion = processingVersion_;
    local.customCurve = toneCurve_;
    local.channelCurves = channelCurves_;
    local.curveApplyToLuminosity = curveApplyToLuminosity_;
    local.parametricCurve = parametricCurve_;
    local.aiDenoiseBlend = aiDenoiseBlend_;
    local.outputSharpening = outputSharpening_;
    local.basicV3 = basicV3;
    local.basicTone = basicV3 ? basicTone : BasicToneV3{};

    int basicFieldSourceWidth = 0;
    int basicFieldSourceHeight = 0;
    if (basicToneActive && (gpuPipeline || (local.inputType == RenderInputType::Raw && !waveletActive && !geometryActive))) {
        const auto& fieldSource = (local.inputType == RenderInputType::Raw && !waveletActive && !viewportPreview &&
            !rawCache_.pixels.empty()) ? rawCache_ : image;
        basicFieldSourceWidth = fieldSource.width;
        basicFieldSourceHeight = fieldSource.height;
        const auto fieldToSrgb = local.hasCustomToSrgb
            ? local.customToSrgb
            : ColorConverter::getConversionMatrix(colorSpace, ColorSpace::sRGB);
        const RGB exposureWB(exposure * wb.r, exposure * wb.g, exposure * wb.b);
        const bool cacheBasicField = local.inputType == RenderInputType::Raw && !waveletActive && !geometryActive;
        std::string fieldKey;
        if (cacheBasicField) {
            auto appendFloatBits = [&](float value) {
                uint32_t bits = 0;
                std::memcpy(&bits, &value, sizeof(bits));
                fieldKey.push_back(':');
                fieldKey += std::to_string(bits);
            };
            fieldKey = rawKey_ + ":dec:" + std::to_string(rawDecodeCount_) +
                ":src:" + std::to_string(fieldSource.width) + "x" + std::to_string(fieldSource.height) +
                ":atm:" + std::to_string(atmosphereSourceWidth) + "x" + std::to_string(atmosphereSourceHeight);
            for (const auto& row : fieldToSrgb)
                for (float v : row) appendFloatBits(v);
            appendFloatBits(exposureWB.r);
            appendFloatBits(exposureWB.g);
            appendFloatBits(exposureWB.b);
        }
        if (cacheBasicField && basicToneFieldCache_.field && basicToneFieldCache_.key == fieldKey) {
            local.basicToneField = basicToneFieldCache_.field;
        } else {
            auto computed = std::make_shared<BasicToneV3Field>(
                buildBasicToneV3Field(fieldSource, fieldToSrgb, exposureWB, atmosphereSourceWidth, atmosphereSourceHeight));
            if (cacheBasicField) {
                basicToneFieldCache_.key = std::move(fieldKey);
                basicToneFieldCache_.field = computed;
            }
            local.basicToneField = std::move(computed);
        }
    }

#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    // 后端直接读取 RAW 缓存；Auto 回退时再从缓存恢复 CPU 工作图。
    const bool rawGpuSource = local.inputType == RenderInputType::Raw && !waveletActive && !viewportPreview;
    // 运行一个编译进来的 GPU 后端并统一处理结果：成功即出图；显存不足直接失败；Force 不伪装成功；
    // Auto 恢复 CPU 工作图后返回 nullopt，继续走 CPU 链。
    auto runGpuBackend = [&](RenderBackend backend, bool moveLargeRawCache, auto&& render)
        -> std::optional<RenderStatus> {
        checkProcessingCancellation();
        uint32_t width = static_cast<uint32_t>(image.width);
        uint32_t height = static_cast<uint32_t>(image.height);
        if (!geometryActive) {
            status = computeTargetSize(local, static_cast<uint32_t>(image.width), static_cast<uint32_t>(image.height), &width, &height);
            if (status != RenderStatus::Ok) return status;
        }
        ImageData rendered;
        const GpuRenderOutcome outcome = render(rawGpuSource ? rawCache_ : image, width, height, rendered);
        if (outcome.succeeded()) {
            lastBackend_ = backend;
            gpuFallbackReason_ = GpuFallbackReason::None;
            gpuErrorDetail_.clear();
            return finishOutput(local, rendered, outBuffer, nativeWidth, nativeHeight, migrationFrame, outImage);
        }
        gpuFallbackReason_ = fallbackReasonFromFault(outcome.fault);
        gpuErrorDetail_ = outcome.message;
        if (outcome.failure == GpuFailureKind::OutOfMemory) return RenderStatus::OutOfMemory;
        if (gpuConfig_.mode == GpuMode::Force) {
            if (outcome.failure == GpuFailureKind::Unsupported) {
                unsupportedReason_ = UnsupportedReason::ForceGpu;
                return RenderStatus::Unsupported;
            }
            return RenderStatus::ProcessingError;
        }
        if (rawGpuSource) {
            if (moveLargeRawCache &&
                rawCache_.pixels.size() * sizeof(RGB) > WaveletRenderCache::defaultPreviewBudget && !previewToBuffer)
                image = std::move(rawCache_);
            else
                image = rawCache_;
        }
        return std::nullopt;
    };
#endif
#if defined(SONY2FUJI_ENABLE_METAL)
    if (gpuPipeline) {
        // Metal 不持有会话纹理，导出回退时可把超预算的 RAW 缓存直接移交 CPU，省一次整幅拷贝。
        const auto finished = runGpuBackend(RenderBackend::Metal, true,
            [&](const ImageData& source, uint32_t width, uint32_t height, ImageData& rendered) {
                return renderPhotoMetalWithOutcome(source, colorSpace, local, width, height, rendered);
            });
        if (finished) return *finished;
    }
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
    if (gpuPipeline) {
        const auto finished = runGpuBackend(RenderBackend::Gles, false,
            [&](const ImageData& source, uint32_t width, uint32_t height, ImageData& rendered) {
                if (!runtime_->glesRenderer) runtime_->glesRenderer = std::make_unique<GlesPhotoRenderer>();
                return runtime_->glesRenderer->renderWithOutcome(source, colorSpace, local, width, height,
                    rawGpuSource ? runtime_->rawRevision : 0, rendered);
            });
        if (finished) return *finished;
    }
#endif
#if defined(SONY2FUJI_ENABLE_D3D11)
    if (gpuPipeline) {
        const auto finished = runGpuBackend(RenderBackend::D3d11, false,
            [&](const ImageData& source, uint32_t width, uint32_t height, ImageData& rendered) {
                if (!runtime_->d3dRenderer) runtime_->d3dRenderer = std::make_unique<D3D11PhotoRenderer>();
                return runtime_->d3dRenderer->renderWithOutcome(source, colorSpace, local, width, height,
                    rawGpuSource ? runtime_->rawRevision : 0, rendered);
            });
        if (finished) return *finished;
    }
#endif

    // A pixel-radius filter must run at source resolution for preview/export parity.
    if (!neighborhoodActive && !geometryActive && local.intent == RenderIntent::Preview && local.sharpening <= 0.0f &&
        local.noiseReduction <= 0.0f && !defringe_.active() && chromaMode == 0 && !effectsActive && (!waveletActive || fastWavelet)) {
        uint32_t width = 0, height = 0;
        status = computeTargetSize(local, static_cast<uint32_t>(image.width), static_cast<uint32_t>(image.height), &width, &height);
        if (status != RenderStatus::Ok) return status;
        if (width != static_cast<uint32_t>(image.width) || height != static_cast<uint32_t>(image.height))
            image = resizeBilinear(image, width, height);
    }

    const auto cpuToSrgb = local.hasCustomToSrgb
        ? local.customToSrgb
        : ColorConverter::getConversionMatrix(colorSpace, ColorSpace::sRGB);
    const bool applyMatrix = local.hasCustomToSrgb || colorSpace != ColorSpace::sRGB;
    const RGB exposureWB(exposure * wb.r, exposure * wb.g, exposure * wb.b);
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            RGB p = applyMatrix ? ColorConverter::applyMatrix(image.pixels[i], cpuToSrgb) : image.pixels[i];
            p.r *= exposureWB.r;
            p.g *= exposureWB.g;
            p.b *= exposureWB.b;
            image.pixels[i] = p;
        }
    });
    colorSpace = ColorSpace::sRGB;
    applyCameraCalibration(image, cameraCalibration_);
    if (basicToneActive) {
        if (local.basicToneField && !local.basicToneField->empty() &&
            image.width == basicFieldSourceWidth && image.height == basicFieldSourceHeight) {
            applyBasicToneV3WithField(image, basicTone, *local.basicToneField, {});
        } else {
            applyBasicToneV3(image, basicTone, atmosphereSourceWidth, atmosphereSourceHeight);
        }
        local.highlights = local.shadows = 0.0f;
    }
    if (defringe_.active()) {
        applyDefringe(image, defringe_);
    }

    auto lookConfig = gpuConfig_;
    if (cpuAnalysis || contractCPU || gpuPipeline || features.stagedOperatorActive() ||
        features.defringe || features.sharpenV2Luminance) {
        lookConfig.mode = GpuMode::Off;
    }
    status = applyPhotoLook(image, lut, dcp, local.lutStrength, displayInput, lookConfig);
    if (status != RenderStatus::Ok) return status;
    checkProcessingCancellation();
    applyDehaze(image, atmosphere_.dehaze, &dehazeAnalysis_,
        atmosphereSourceWidth, atmosphereSourceHeight, processingVersion_);
    applyPostLookStages(image, local, toneControls_, hsl_, colorGrading_,
        channelCurves_, basicV3, !preHsl);
    if (preHsl) {
        status = finishGeometry(local, image, nativeWidth, nativeHeight);
        if (status == RenderStatus::Ok) *preHsl = std::move(image);
        return status;
    }
    const auto chromaResult = applyChromaDenoiseWorking(image, chromaMode);
    checkProcessingCancellation();
    if (chromaResult != ErrorCode::Success) return mapErrorCode(chromaResult);
    applyDetailAdjustments(image, local.noiseReduction, local.sharpening, atmosphere_.clarity,
        atmosphereSourceWidth, atmosphereSourceHeight, processingVersion_,
        nullptr, {}, atmosphere_.texture, sharpenV2_, image.width, image.height,
        effectiveFilmOptics, nullptr);
    checkProcessingCancellation();
    applyPhotoEffects(image, photoEffects_);

    return finishOutput(local, image, outBuffer, nativeWidth, nativeHeight, migrationFrame, outImage);
}

RenderStatus Pipeline::supportsFastFullResGpu(
    const FastFullResGpuQuery& query,
    const char* editStateJson,
    bool& outSupported
) const {
    outSupported = false;
    if (query.inputType < RenderInputType::Raw || query.inputType > RenderInputType::DisplayBuffer) {
        return RenderStatus::InvalidArgument;
    }
    if ((query.inputWidth == 0) != (query.inputHeight == 0)) {
        return RenderStatus::InvalidArgument;
    }

    ProcessingVersion pv = processingVersion_;
    X3fMode x3f = x3fMode_;
    int32_t chroma = chromaDenoise_;
    WaveletDenoiseOptions wavelet = waveletDenoise_;
    PhotoEffectsOptions effects = photoEffects_;
    FilmOpticsOptions filmOptics = filmOptics_;
    AtmosphereOptions atmosphere = atmosphere_;
    GeometryOptions geometry = geometry_;
    bool masterCurveGpuSupported = toneCurve_.gpuSupported();
    bool channelCurvesGpuSupported = std::all_of(channelCurves_.begin(), channelCurves_.end(),
        [](const auto& curve) { return curve.gpuSupported(); });
    std::string lookPath = hasCommittedEditState_ ? committedEditState_.lookPath : std::string{};
    float lookStrength = hasCommittedEditState_ ? committedEditState_.lookStrength : 1.0f;
    std::string stateInputPath = hasCommittedEditState_ ? committedEditState_.inputPath : std::string{};
    bool isHdr = false;

    if (editStateJson != nullptr) {
        if (!*editStateJson) {
            return RenderStatus::InvalidArgument;
        }
        CanonicalEditState parsed;
        std::string error;
        if (!parseCanonicalEditState(
                editStateJson, parsed, error, {RecipeParseMode::SessionState, /*allowRasterLensCorrection=*/true})) {
            return RenderStatus::InvalidArgument;
        }
        if (parsed.isHdr) {
            isHdr = true;
        } else {
            if (!validProcessingVersion(parsed.processingVersion) ||
                (parsed.x3fMode != X3fMode::Legacy && parsed.x3fMode != X3fMode::Normal) ||
                parsed.exposureMode < RawExposureMode::Scene ||
                parsed.exposureMode > RawExposureMode::Sensor) {
                return RenderStatus::InvalidArgument;
            }
            if (!std::isfinite(parsed.exposureEv) || std::abs(parsed.exposureEv) > 20.0f ||
                !std::isfinite(parsed.brightness) || parsed.brightness <= 0.0f ||
                !std::isfinite(parsed.contrast) || parsed.contrast < 0.0f || parsed.contrast > 2.0f ||
                !std::isfinite(parsed.saturation) || parsed.saturation < 0.0f || parsed.saturation > 2.0f ||
                !std::isfinite(parsed.highlights) || parsed.highlights < -1.0f || parsed.highlights > 1.0f ||
                !std::isfinite(parsed.shadows) || parsed.shadows < -1.0f || parsed.shadows > 1.0f ||
                !std::isfinite(parsed.sCurve) || parsed.sCurve < -1.0f || parsed.sCurve > 1.0f ||
                !std::isfinite(parsed.sharpening) || parsed.sharpening < 0.0f || parsed.sharpening > 2.0f ||
                !std::isfinite(parsed.lookStrength) || parsed.lookStrength < 0.0f || parsed.lookStrength > 2.0f ||
                !std::isfinite(parsed.aiDenoiseBlend) || parsed.aiDenoiseBlend < 0.0f || parsed.aiDenoiseBlend > 1.0f ||
                !std::isfinite(parsed.masterRecipe.strength) || parsed.masterRecipe.strength < 0.0f || parsed.masterRecipe.strength > 2.0f ||
                !std::isfinite(parsed.masterRecipe.temperatureKelvin) || parsed.masterRecipe.temperatureKelvin < 2000.0f || parsed.masterRecipe.temperatureKelvin > 50000.0f ||
                !std::isfinite(parsed.masterRecipe.tint) || std::abs(parsed.masterRecipe.tint) > 150.0f ||
                parsed.rawNoiseReduction < 0 || parsed.rawNoiseReduction > 2 ||
                parsed.chromaDenoise < 0 || parsed.chromaDenoise > 2) {
                return RenderStatus::InvalidArgument;
            }
            WaveletDenoiseOptions parsedWavelet = parsed.wavelet;
            parsedWavelet.processingVersion = parsed.processingVersion;
            if (!validWaveletDenoiseOptions(parsedWavelet)) {
                return RenderStatus::InvalidArgument;
            }
            const auto freeCurveEndpoints = parsed.schemaVersion >= 18 ? ToneCurveEndpoints::Free
                : parsed.schemaVersion >= 17 ? ToneCurveEndpoints::FreeY : ToneCurveEndpoints::Pinned;
            if (!parsed.effects.valid() || !parsed.hsl.valid() || !parsed.toneControls.valid() ||
                !parsed.atmosphere.valid() || !parsed.colorGrading.valid() || !parsed.parametricCurve.valid() ||
                !parsed.calibration.valid() || !parsed.pointColor.valid() || !parsed.selectiveColor.valid() ||
                !parsed.bw.valid() || !parsed.sharpenV2.valid() || !parsed.defringe.valid() ||
                !parsed.filmOptics.valid() ||
                parsed.outputSharpening < OutputSharpening::Off || parsed.outputSharpening > OutputSharpening::High ||
                !validToneCurve(parsed.toneCurve, freeCurveEndpoints) ||
                !std::all_of(parsed.channelCurves.begin(), parsed.channelCurves.end(),
                    [freeCurveEndpoints](const auto& c) { return validToneCurve(c, freeCurveEndpoints); })) {
                return RenderStatus::InvalidArgument;
            }
            ToneCurve masterCurve(parsed.toneCurve, freeCurveEndpoints);
            if (masterCurve.custom() && parsed.sCurve != 0.0f) {
                return RenderStatus::InvalidArgument;
            }
            GeometryOptions parsedGeometry = parsed.geometry;
            if (!parsedGeometry.valid() || !validProfileId(parsed.lensProfileId)) {
                return RenderStatus::InvalidArgument;
            }
            parsedGeometry.crop_width = std::min(parsedGeometry.crop_width, 1.0f - parsedGeometry.crop_x);
            parsedGeometry.crop_height = std::min(parsedGeometry.crop_height, 1.0f - parsedGeometry.crop_y);

            pv = parsed.processingVersion;
            x3f = parsed.x3fMode;
            chroma = parsed.chromaDenoise;
            wavelet = parsedWavelet;
            effects = parsed.effects;
            filmOptics = parsed.filmOptics;
            atmosphere = parsed.atmosphere;
            geometry = parsedGeometry;
            masterCurveGpuSupported = masterCurve.gpuSupported();
            channelCurvesGpuSupported =
                ToneCurve(parsed.channelCurves[0], freeCurveEndpoints).gpuSupported() &&
                ToneCurve(parsed.channelCurves[1], freeCurveEndpoints).gpuSupported() &&
                ToneCurve(parsed.channelCurves[2], freeCurveEndpoints).gpuSupported();
            lookPath = std::move(parsed.lookPath);
            lookStrength = parsed.lookStrength;
            stateInputPath = std::move(parsed.inputPath);
        }
    }

    if (isHdr || gpuConfig_.mode == GpuMode::Off) {
        return RenderStatus::Ok;
    }
#if !defined(SONY2FUJI_ENABLE_METAL) && !defined(SONY2FUJI_ENABLE_GLES) && !defined(SONY2FUJI_ENABLE_D3D11)
    return RenderStatus::Ok;
#else
    if (query.inputType != RenderInputType::Raw || aiEnabled()) {
        return RenderStatus::Ok;
    }
    const std::string& effectiveInputPath = !query.inputPath.empty() ? query.inputPath : stateInputPath;
    if (isNormalX3f(effectiveInputPath.c_str(), x3f)) {
        return RenderStatus::Ok;
    }
    if (wavelet.active() || chroma != 0 || geometry.active() ||
        !masterCurveGpuSupported || !channelCurvesGpuSupported) {
        return RenderStatus::Ok;
    }

    uint32_t checkW = query.inputWidth;
    uint32_t checkH = query.inputHeight;
    if ((checkW == 0 || checkH == 0) && !effectiveInputPath.empty()) {
        uint32_t probedW = 0;
        uint32_t probedH = 0;
        if (probeInputHeaderSize(
                effectiveInputPath.c_str(), sony2fuji::usesLegacySonyCrop(pv), x3f, probedW, probedH) ==
            ProbeSizeResult::Probed) {
            checkW = probedW;
            checkH = probedH;
        }
    }
    if (checkW > 0 && checkH > 0 && query.maxPixels > 0 &&
        static_cast<uint64_t>(checkW) * static_cast<uint64_t>(checkH) > static_cast<uint64_t>(query.maxPixels)) {
        return RenderStatus::Ok;
    }
    const uint32_t gpuCheckW = checkW > 0 ? checkW : 1u;
    const uint32_t gpuCheckH = checkH > 0 ? checkH : 1u;

    const float clampedStrength = clampFloat(lookStrength, 0.0f, 2.0f);
    const bool useLook = !lookPath.empty() && clampedStrength > 0.0f;
    bool useDcp = false;
    if (useLook) {
        if (LUTParser::detectFormat(lookPath) == "rlook") {
            const auto dcp = DcpLook::loadCached(lookPath);
            if (!dcp) {
                return RenderStatus::Ok;
            }
            useDcp = true;
        } else {
            std::shared_ptr<LUT3D> lut;
            if (loadLUT(lookPath.c_str(), &lut) != RenderStatus::Ok || !lut || !lut->isPhotoLUT() || lut->requiresCPU()) {
                return RenderStatus::Ok;
            }
        }
    }
    (void)useDcp;

#if defined(SONY2FUJI_ENABLE_METAL)
    const PhotoGpuCapabilities caps = queryMetalPhotoCapabilities(gpuCheckW, gpuCheckH);
    if (!caps.compiled || !caps.ready || !caps.dimensionsSupported) {
        return RenderStatus::Ok;
    }
    if (effects.active() && !caps.supportsEffects) {
        return RenderStatus::Ok;
    }
    if (filmOptics.active() && !caps.supportsFilmOptics) {
        return RenderStatus::Ok;
    }
    if (useDcp && !caps.supportsDcp) {
        return RenderStatus::Ok;
    }
#elif defined(SONY2FUJI_ENABLE_GLES)
    if (gpuCheckW > static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
        gpuCheckH > static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
        static_cast<uint64_t>(gpuCheckW) * gpuCheckH > static_cast<uint64_t>(std::numeric_limits<int32_t>::max())) {
        return RenderStatus::Ok;
    }
    if (runtime_ && runtime_->glesRenderer && !runtime_->glesRenderer->isReadyForQuery()) {
        return RenderStatus::Ok;
    }
#elif defined(SONY2FUJI_ENABLE_D3D11)
    if (gpuCheckW > 65535u || gpuCheckH > 65535u || D3D11PhotoRenderer::disabledByEnvironment()) {
        return RenderStatus::Ok;
    }
    if (runtime_ && runtime_->d3dRenderer && !runtime_->d3dRenderer->isReadyForQuery()) {
        return RenderStatus::Ok;
    }
#endif

    outSupported = true;
    return RenderStatus::Ok;
#endif
}

} // namespace sony2fuji
