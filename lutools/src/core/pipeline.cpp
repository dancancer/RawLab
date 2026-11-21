#include "core/pipeline.h"
#include "core/edit_recipe_params.h"
#include "core/pipeline_runtime.h"

#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/dcp_look.h"
#include "core/chroma_denoise.h"
#include "core/display_lens_correction.h"
#include "core/image_header_probe.h"
#include "core/lut_compatibility.h"
#include "core/parallel_pixels.h"
#include "core/photo_basic_controls_v3.h"
#include "core/photo_pipeline_stages.h"
#include "core/x3f_processor.h"
#include "gpu/denoise.h"
#include "gpu/photo_gpu.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>

namespace sony2fuji {
namespace {
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
    toneCurve_ = source.toneCurve_;
    channelCurves_ = source.channelCurves_;
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
            struct ProbeGuard {
                Pipeline& self;
                ProcessingVersion processingVersion;
                X3fMode x3fMode;
                RawExposureMode rawExposureMode;
                LensCorrectionOptions lensCorrection;
                int32_t rawNoiseReduction;
                int32_t chromaDenoise;
                bool interactivePreview;
                bool viewportPreview;
                LensCorrectionReport lensReport;
                LensCorrectionReport rawLensReport;
                std::string x3fError;
                UnsupportedReason unsupportedReason;
                GpuFallbackReason gpuFallbackReason;
                std::string gpuErrorDetail;
                explicit ProbeGuard(Pipeline& pipeline)
                    : self(pipeline),
                      processingVersion(pipeline.processingVersion_),
                      x3fMode(pipeline.x3fMode_),
                      rawExposureMode(pipeline.rawExposureMode_),
                      lensCorrection(pipeline.lensCorrection_),
                      rawNoiseReduction(pipeline.rawNoiseReduction_),
                      chromaDenoise(pipeline.chromaDenoise_),
                      interactivePreview(pipeline.interactivePreview_),
                      viewportPreview(pipeline.viewportPreview_),
                      lensReport(pipeline.lensReport_),
                      rawLensReport(pipeline.rawLensReport_),
                      x3fError(pipeline.x3fError_),
                      unsupportedReason(pipeline.unsupportedReason_),
                      gpuFallbackReason(pipeline.gpuFallbackReason_),
                      gpuErrorDetail(pipeline.gpuErrorDetail_) {}
                ~ProbeGuard() {
                    self.processingVersion_ = processingVersion;
                    self.x3fMode_ = x3fMode;
                    self.rawExposureMode_ = rawExposureMode;
                    self.lensCorrection_ = lensCorrection;
                    self.rawNoiseReduction_ = rawNoiseReduction;
                    self.chromaDenoise_ = chromaDenoise;
                    self.interactivePreview_ = interactivePreview;
                    self.viewportPreview_ = viewportPreview;
                    self.lensReport_ = lensReport;
                    self.rawLensReport_ = rawLensReport;
                    self.x3fError_ = std::move(x3fError);
                    self.unsupportedReason_ = unsupportedReason;
                    self.gpuFallbackReason_ = gpuFallbackReason;
                    self.gpuErrorDetail_ = std::move(gpuErrorDetail);
                    self.rawProcessor_.reset();
                    self.processorKey_.clear();
                }
            } guard(*this);

            try {
                ProcessingCancellationScope cancelScope(cancellation_);
                checkProcessingCancellation();
                processingVersion_ = request.processingVersion;
                x3fMode_ = request.x3fMode;
                rawExposureMode_ = request.exposureMode;
                lensCorrection_ = {};
                rawNoiseReduction_ = 0;
                chromaDenoise_ = 0;
                interactivePreview_ = false;
                viewportPreview_ = false;

                RenderParams probeParams;
                probeParams.inputType = RenderInputType::Raw;
                probeParams.inputPath = request.inputPath;
                probeParams.intent = RenderIntent::Preview;
                probeParams.previewLongEdge = 32;
                probeParams.wbMode = RenderWhiteBalanceMode::Camera;
                probeParams.exposureEV = 0.0f;
                probeParams.brightness = 1.0f;

                ImageData scratch;
                ColorSpace space = ColorSpace::AdobeRGB;
                bool isLinear = true;
                const auto status = loadRawImage(probeParams, scratch, &space, &isLinear, false, false);
                checkProcessingCancellation();
                if (status != RenderStatus::Ok) {
                    return status;
                }
                float rawTemp = 0.0f;
                float rawTint = 0.0f;
                const auto wbStatus = getRawWhiteBalance(rawTemp, rawTint);
                if (wbStatus == RenderStatus::Unsupported ||
                    (wbStatus == RenderStatus::Ok && (!std::isfinite(rawTemp) || !std::isfinite(rawTint)))) {
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
                if (wbStatus != RenderStatus::Ok) {
                    return wbStatus;
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

RenderStatus Pipeline::setToneCurve(const ToneCurveConfig& config) {
    if (!validToneCurve(config)) return RenderStatus::InvalidArgument;
    try {
        ToneCurve curve(config);
        toneCurve_ = std::move(curve);
        channelCurves_ = {};
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::setToneCurves(const ToneCurveConfig& masterConfig, const std::array<ToneCurveConfig, 3>& channelConfigs) {
    if (!validToneCurve(masterConfig) ||
        !std::all_of(channelConfigs.begin(), channelConfigs.end(), validToneCurve)) {
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
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::applyParams(const char* recipeJson) {
    if (!recipeJson || !*recipeJson) return RenderStatus::InvalidArgument;
    try {
        CanonicalSdrRecipe parsed;
        std::string error;
        if (!parseCanonicalSdrRecipe(recipeJson, parsed, error, /*allowRasterLensCorrection=*/true)) {
            return RenderStatus::InvalidArgument;
        }
        return applyParams(parsed);
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::applyParams(const CanonicalSdrRecipe& recipe) {
    try {
        if (!validProcessingVersion(recipe.processingVersion)) {
            return RenderStatus::InvalidArgument;
        }
        if (recipe.x3fMode != X3fMode::Legacy && recipe.x3fMode != X3fMode::Normal) {
            return RenderStatus::InvalidArgument;
        }
        if (recipe.exposureMode < RawExposureMode::Scene || recipe.exposureMode > RawExposureMode::Sensor) {
            return RenderStatus::InvalidArgument;
        }
        if (recipe.rawNoiseReduction < 0 || recipe.rawNoiseReduction > 2) {
            return RenderStatus::InvalidArgument;
        }
        if (recipe.chromaDenoise < 0 || recipe.chromaDenoise > 2) {
            return RenderStatus::InvalidArgument;
        }
        if (recipe.chromaDenoise != 0 && !chromaDenoiseAvailable()) {
            return RenderStatus::Unsupported;
        }
        WaveletDenoiseOptions wavelet = recipe.wavelet;
        wavelet.processingVersion = recipe.processingVersion;
        if (!validWaveletDenoiseOptions(wavelet)) {
            return RenderStatus::InvalidArgument;
        }
        if (wavelet.active() && !waveletDenoiseAvailable()) {
            return RenderStatus::Unsupported;
        }
        if (!recipe.effects.valid() || !recipe.hsl.valid() || !recipe.toneControls.valid() ||
            !recipe.atmosphere.valid() || !recipe.colorGrading.valid()) {
            return RenderStatus::InvalidArgument;
        }
        if (!validToneCurve(recipe.toneCurve) ||
            !std::all_of(recipe.channelCurves.begin(), recipe.channelCurves.end(), validToneCurve)) {
            return RenderStatus::InvalidArgument;
        }
        ToneCurve masterCurve(recipe.toneCurve);
        if (masterCurve.custom() && recipe.sCurve != 0.0f) {
            return RenderStatus::InvalidArgument;
        }
        std::array<ToneCurve, 3> channelCurves = {
            ToneCurve(recipe.channelCurves[0]),
            ToneCurve(recipe.channelCurves[1]),
            ToneCurve(recipe.channelCurves[2])
        };
        GeometryOptions geometry = recipe.geometry;
        if (!geometry.valid()) {
            return RenderStatus::InvalidArgument;
        }
        geometry.crop_width = std::min(geometry.crop_width, 1.0f - geometry.crop_x);
        geometry.crop_height = std::min(geometry.crop_height, 1.0f - geometry.crop_y);

        if (!validProfileId(recipe.lensProfileId)) {
            return RenderStatus::InvalidArgument;
        }
        LensCorrectionOptions lens{
            recipe.lensDistortion, recipe.lensTca, recipe.lensAutoCrop, recipe.lensProfileId, recipe.lensVignetting
        };
        if (lens.active() && !LensCorrectionDatabase::available()) {
            return RenderStatus::Unsupported;
        }

        // All validations passed; commit atomically without touching runtime/hardware/metadata config.
        if (processingVersion_ != recipe.processingVersion) {
            dehazeAnalysis_ = {};
        }
        processingVersion_ = recipe.processingVersion;
        x3fMode_ = recipe.x3fMode;
        x3fError_.clear();
        unsupportedReason_ = UnsupportedReason::None;
        gpuFallbackReason_ = GpuFallbackReason::None;
        gpuErrorDetail_.clear();
        rawExposureMode_ = recipe.exposureMode;
        rawNoiseReduction_ = recipe.rawNoiseReduction;
        chromaDenoise_ = recipe.chromaDenoise;
        waveletDenoise_ = wavelet;
        photoEffects_ = recipe.effects;
        hsl_ = recipe.hsl;
        toneControls_ = recipe.toneControls;
        atmosphere_ = recipe.atmosphere;
        colorGrading_ = recipe.colorGrading;
        toneCurve_ = std::move(masterCurve);
        channelCurves_ = std::move(channelCurves);
        geometry_ = geometry;
        geometryWidth_ = geometryHeight_ = 0;
        lensCorrection_ = std::move(lens);
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
    if (params.wbMode < RenderWhiteBalanceMode::Camera || params.wbMode > RenderWhiteBalanceMode::Temperature) {
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
        if (local.wbMode != RenderWhiteBalanceMode::Temperature || (raw && rawDisplayReferred_)) {
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
            worker.atmosphere_ = {values[8], values[9]};
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
    const auto reference = whiteBalanceForTempTint(6500.0f, 0.0f);
    const auto selected = whiteBalanceForTempTint(local.temperature, local.tint);
    exposure = std::pow(2.0f, local.exposureEV) * local.brightness;
    wb = RGB(1.0f, 1.0f, 1.0f);
    if (local.wbMode != RenderWhiteBalanceMode::Temperature || displayInput) {
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
        RenderParams rawRequest = local;
        rawRequest.intent = RenderIntent::Final;
        RenderStatus status = loadRawImage(rawRequest, image, &colorSpace, &isLinear, false);
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
    const bool needGuides = basicToneActive || atmosphere_.dehaze != 0.0f || atmosphere_.clarity != 0.0f;

    int halo = geometry_.active() ? 4 : 2;
    if (waveletActive) halo += 96;
    if (chromaMode != 0) halo += 32;
    if (local.noiseReduction > 0.0f || local.sharpening > 0.0f) halo += 16;

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
        RenderParams guideParams = local;
        if (basicToneActive) {
            basicField = buildBasicToneV3Field(guideImage, canvasW, canvasH);
            if (atmosphere_.dehaze != 0.0f || atmosphere_.clarity != 0.0f) {
                applyBasicToneV3WithField(guideImage, basicTone, basicField);
            }
            guideParams.highlights = guideParams.shadows = 0.0f;
        }
        if (atmosphere_.dehaze != 0.0f || atmosphere_.clarity != 0.0f) {
            GpuConfig cpuLook = gpuConfig_;
            cpuLook.mode = GpuMode::Off;
            status = applyPhotoLook(guideImage, lut, dcp, guideParams.lutStrength, displayInput, cpuLook);
            if (status != RenderStatus::Ok) return status;
            checkProcessingCancellation();
            if (atmosphere_.dehaze != 0.0f) {
                dehazeState = buildDehazeAnalysis(guideImage, canvasW, canvasH, processingVersion_);
                if (atmosphere_.clarity != 0.0f) {
                    applyDehazeWithAnalysis(guideImage, atmosphere_.dehaze, dehazeState);
                }
            }
            if (atmosphere_.clarity != 0.0f) {
                if (basicV3) applyBasicBlackWhiteV3(guideImage, toneControls_);
                else applyBlackWhite(guideImage, toneControls_);
                applyToneAdjustments(guideImage, guideParams, channelCurves_, basicV3);
                if (basicV3) applyBasicVibranceV3(guideImage, toneControls_.vibrance);
                else applyVibrance(guideImage, toneControls_);
                applyHsl(guideImage, hsl_);
                applyColorGrading(guideImage, colorGrading_);
                clarityField = buildClarityField(guideImage, canvasW, canvasH, processingVersion_);
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
    local.chromaDenoise = chromaMode;
    local.preserveSourceResolution = waveletActive || geometry_.active();
    local.hsl = hsl_;
    local.toneControls = toneControls_;
    local.colorGrading = colorGrading_;
    local.customCurve = toneCurve_;

    ColorConverter converter;
    converter.convertImage(image, colorSpace, ColorSpace::sRGB);
    colorSpace = ColorSpace::sRGB;
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) applyExposureAndWhiteBalance(image.pixels[i], exposure, wb);
    });
    if (basicToneActive) {
        applyBasicToneV3WithField(image, basicTone, basicField, roiMap);
        local.highlights = local.shadows = 0.0f;
    }

    GpuConfig lookConfig = gpuConfig_;
    lookConfig.mode = GpuMode::Off;
    status = applyPhotoLook(image, lut, dcp, local.lutStrength, displayInput, lookConfig);
    if (status != RenderStatus::Ok) return status;
    checkProcessingCancellation();
    if (atmosphere_.dehaze != 0.0f) {
        applyDehazeWithAnalysis(image, atmosphere_.dehaze, dehazeState, roiMap);
    }
    if (basicV3) applyBasicBlackWhiteV3(image, toneControls_);
    else applyBlackWhite(image, toneControls_);
    applyToneAdjustments(image, local, channelCurves_, basicV3);
    if (basicV3) applyBasicVibranceV3(image, toneControls_.vibrance);
    else applyVibrance(image, toneControls_);
    applyHsl(image, hsl_);
    applyColorGrading(image, colorGrading_);
    const auto chromaResult = applyChromaDenoiseWorking(image, chromaMode);
    checkProcessingCancellation();
    if (chromaResult != ErrorCode::Success) return mapErrorCode(chromaResult);
    applyDetailAdjustments(image, local.noiseReduction, local.sharpening, atmosphere_.clarity,
        canvasW, canvasH, processingVersion_,
        atmosphere_.clarity != 0.0f ? &clarityField : nullptr, roiMap);
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
    MigrationFrame* migrationFrame
) {
    x3fError_.clear();
    unsupportedReason_ = UnsupportedReason::None;
    gpuFallbackReason_ = GpuFallbackReason::None;
    gpuErrorDetail_.clear();
    checkProcessingCancellation();
    geometryWidth_ = geometryHeight_ = 0;
    viewportRoiResult_ = {};

    RenderStatus status = validateRenderParams(params, outBuffer != nullptr);
    if (status != RenderStatus::Ok) return status;

    status = validateRenderParamsSize(params);
    if (status != RenderStatus::Ok) return status;

    status = validateRenderOutputFormat(params);
    if (status != RenderStatus::Ok) return status;

    RenderParams local = params;
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
    if (displayInput && (rawNoiseReduction_ != 0 || unsupportedDisplayLens ||
        effectiveGpuMode == GpuMode::Force)) {
        if (normalX3f) {
            x3fError_ = rawNoiseReduction_ != 0
                ? "Normal X3F rendering does not support FBDD RAW denoise"
                : lensCorrection_.active() ? "Normal X3F rendering does not support additional lens correction"
                : "Normal X3F rendering uses CPU filtering; GPU Force is not supported";
        }
        if (rawNoiseReduction_ == 0 && !unsupportedDisplayLens && effectiveGpuMode == GpuMode::Force) {
            unsupportedReason_ = UnsupportedReason::ForceGpu;
            gpuFallbackReason_ = GpuFallbackReason::DisplayInput;
        }
        return RenderStatus::Unsupported;
    }
    if (displayInput && !cpuAnalysis && gpuConfig_.mode != GpuMode::Off) {
        gpuFallbackReason_ = GpuFallbackReason::DisplayInput;
    }
    local.lutStrength = clampFloat(local.lutStrength, 0.0f, 2.0f);
    lastBackend_ = RenderBackend::Cpu;
    const bool waveletActive = !useAI && waveletDenoise_.active();
    const int chromaMode = useAI ? 0 : chromaDenoise_;
    const bool effectsActive = photoEffects_.active();
    const bool hslActive = hsl_.active();
    const bool toneControlsActive = toneControls_.active();
    const bool atmosphereActive = atmosphere_.active();
    const bool basicV3 = processingVersion_ == ProcessingVersion::BasicV3;
    const BasicToneV3 basicTone{-local.highlights, local.shadows};
    const bool basicToneActive = basicV3 && basicTone.active();
    const bool basicControlsActive = basicV3 && (basicTone.active() || local.contrast != 1.0f || toneControlsActive);
    const bool neighborhoodActive = atmosphereActive || basicToneActive;
    const bool colorGradingActive = colorGrading_.active();
    const bool geometryActive = geometry_.active();
    if (geometryActive && effectiveGpuMode == GpuMode::Force) {
        unsupportedReason_ = UnsupportedReason::ForceGpu;
        gpuFallbackReason_ = GpuFallbackReason::Geometry;
        return RenderStatus::Unsupported;
    }
    // 预览到缓冲（含未开启视口标志的预览）必须保留大图 RAW 缓存供下一次渲染复用；
    // 只有导出才把工作图移走缓存来省一次整幅拷贝。
    const bool previewToBuffer = local.intent == RenderIntent::Preview &&
        local.outputTarget == RenderOutputTarget::Buffer;
    const bool roiActive = viewportRoi_.enabled && previewToBuffer && !preHsl && !migrationFrame;
    if (roiActive && effectiveGpuMode == GpuMode::Force) {
        unsupportedReason_ = UnsupportedReason::ForceGpu;
        if (gpuFallbackReason_ == GpuFallbackReason::None) {
            gpuFallbackReason_ = GpuFallbackReason::UnsupportedCapability;
        }
        return RenderStatus::Unsupported;
    }
    bool viewportPreview = viewportPreview_ && previewToBuffer && !roiActive;
    const bool channelCurvesActive = std::any_of(channelCurves_.begin(), channelCurves_.end(),
        [](const auto& curve) { return curve.active(); });
#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    const bool cpuOnlyStages = neighborhoodActive || basicControlsActive || channelCurvesActive || !toneCurve_.gpuSupported();
#else
    const bool cpuOnlyStages = neighborhoodActive || basicControlsActive || channelCurvesActive ||
        toneCurve_.active() || colorGradingActive || toneControlsActive || hslActive ||
        effectsActive || waveletActive || chromaMode != 0;
#endif
    const bool c5Wavelet = waveletActive && usesC5Denoise(waveletDenoise_.processingVersion);
    const bool fastWavelet = !neighborhoodActive && !geometryActive && waveletActive && !effectsActive &&
        chromaMode == 0 && interactivePreview_ &&
        local.intent == RenderIntent::Preview && local.outputTarget == RenderOutputTarget::Buffer;
    auto cpuStageFallbackReason = [&]() {
        if (atmosphereActive) return GpuFallbackReason::Atmosphere;
        if (basicControlsActive) return GpuFallbackReason::BasicV3Controls;
        if (channelCurvesActive || !toneCurve_.gpuSupported()) return GpuFallbackReason::Curves;
        if (c5Wavelet) return GpuFallbackReason::C5Wavelet;
        return GpuFallbackReason::GpuDisabled;
    };
    if ((cpuOnlyStages || c5Wavelet) && effectiveGpuMode == GpuMode::Force) {
        unsupportedReason_ = UnsupportedReason::ForceGpu;
        gpuFallbackReason_ = cpuStageFallbackReason();
        return RenderStatus::Unsupported;
    }
    if (cpuOnlyStages && !cpuAnalysis && gpuConfig_.mode != GpuMode::Off &&
        gpuFallbackReason_ == GpuFallbackReason::None) {
        gpuFallbackReason_ = cpuStageFallbackReason();
    }
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
#if !defined(SONY2FUJI_ENABLE_METAL)
            if (!cpuAnalysis && gpuConfig_.mode != GpuMode::Off &&
                gpuFallbackReason_ == GpuFallbackReason::None) {
                gpuFallbackReason_ = GpuFallbackReason::DcpLook;
            }
            if (effectiveGpuMode == GpuMode::Force) {
                unsupportedReason_ = UnsupportedReason::ForceGpu;
                gpuFallbackReason_ = GpuFallbackReason::DcpLook;
                return RenderStatus::Unsupported;
            }
#endif
        } else {
            status = loadLUT(local.lutPath.c_str(), &lut);
            if (status != RenderStatus::Ok) return status;
            if (!lut->isPhotoLUT()) return RenderStatus::Unsupported;
        }
    }

#if defined(SONY2FUJI_ENABLE_METAL)
    bool sessionGpuPipeline = !cpuOnlyStages && gpuConfig_.mode != GpuMode::Off;
#elif defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    bool sessionGpuPipeline = !cpuOnlyStages && !dcp && gpuConfig_.mode != GpuMode::Off;
#else
    bool sessionGpuPipeline = false;
    if (!cpuAnalysis && gpuConfig_.mode != GpuMode::Off &&
        gpuFallbackReason_ == GpuFallbackReason::None) {
        gpuFallbackReason_ = GpuFallbackReason::GpuDisabled;
    }
    if (effectiveGpuMode == GpuMode::Force) {
        unsupportedReason_ = UnsupportedReason::ForceGpu;
        if (gpuFallbackReason_ == GpuFallbackReason::None) {
            gpuFallbackReason_ = GpuFallbackReason::GpuDisabled;
        }
        return RenderStatus::Unsupported;
    }
#endif
    // Reuse the reference stages; scene-view GPU shaders retain their existing
    // contract. Auto explicitly falls back for display-referred input.
    if (displayInput) sessionGpuPipeline = false;
    const bool contractCPU = lut && lut->requiresCPU();
    if (contractCPU) {
        if (!cpuAnalysis && gpuConfig_.mode != GpuMode::Off &&
            gpuFallbackReason_ == GpuFallbackReason::None) {
            gpuFallbackReason_ = GpuFallbackReason::LutContract;
        }
        if (effectiveGpuMode == GpuMode::Force) {
            unsupportedReason_ = UnsupportedReason::ForceGpu;
            gpuFallbackReason_ = GpuFallbackReason::LutContract;
            return RenderStatus::Unsupported;
        }
        sessionGpuPipeline = false;
    }
    bool gpuPipeline = !cpuAnalysis && sessionGpuPipeline && !roiActive;
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
        auto rawRequest = local;
        // Atmosphere 的分析尺度和 native 元信息仍以精确 RAW 为准；交互和 settled
        // 视口共用该缓存，只缩小后续工作图，避免 half-size 解码改变空间尺度。
        if (geometryActive || neighborhoodActive) rawRequest.intent = RenderIntent::Final;
        status = loadRawImage(rawRequest, image, &colorSpace, &isLinear, false);
        // Use a full decode when the viewport needs more pixels than the RAW proxy provides.
        if (status == RenderStatus::Ok && viewportPreview &&
            std::pair{image.width, image.height} != rawNativeSize_) {
            const auto [sourceWidth, sourceHeight] = rawNativeSize_;
            uint32_t width = 0, height = 0;
            status = computeTargetSize(local, static_cast<uint32_t>(sourceWidth), static_cast<uint32_t>(sourceHeight), &width, &height);
            if (status == RenderStatus::Ok && (width > uint32_t(image.width) || height > uint32_t(image.height))) {
                rawRequest.intent = RenderIntent::Final;
                status = loadRawImage(rawRequest, image, &colorSpace, &isLinear, false);
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
    local.chromaDenoise = chromaMode;
    local.preserveSourceResolution = waveletActive || geometryActive;
    local.hsl = hsl_;
    local.toneControls = toneControls_;
    local.colorGrading = colorGrading_;
    local.customCurve = toneCurve_;

#if defined(SONY2FUJI_ENABLE_METAL)
    if (gpuPipeline) {
        checkProcessingCancellation();
        uint32_t width = static_cast<uint32_t>(image.width);
        uint32_t height = static_cast<uint32_t>(image.height);
        if (!geometryActive) {
            status = computeTargetSize(local, static_cast<uint32_t>(image.width), static_cast<uint32_t>(image.height), &width, &height);
            if (status != RenderStatus::Ok) return status;
        }
        const auto& source = local.inputType == RenderInputType::Raw && !waveletActive && !viewportPreview
            ? rawCache_ : image;
        ImageData rendered;
        const auto outcome = renderPhotoMetalWithOutcome(source, colorSpace, local, width, height, rendered);
        if (outcome.succeeded()) {
            lastBackend_ = RenderBackend::Metal;
            gpuFallbackReason_ = GpuFallbackReason::None;
            gpuErrorDetail_.clear();
            return finishOutput(local, rendered, outBuffer, nativeWidth, nativeHeight, migrationFrame);
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
        if (local.inputType == RenderInputType::Raw && !waveletActive && !viewportPreview) {
            if (rawCache_.pixels.size() * sizeof(RGB) > WaveletRenderCache::defaultPreviewBudget && !previewToBuffer)
                image = std::move(rawCache_);
            else
                image = rawCache_;
        }
    }
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
    if (gpuPipeline) {
        checkProcessingCancellation();
        uint32_t width = static_cast<uint32_t>(image.width);
        uint32_t height = static_cast<uint32_t>(image.height);
        if (!geometryActive) {
            status = computeTargetSize(local, static_cast<uint32_t>(image.width), static_cast<uint32_t>(image.height), &width, &height);
            if (status != RenderStatus::Ok) return status;
        }
        if (!runtime_->glesRenderer) runtime_->glesRenderer = std::make_unique<GlesPhotoRenderer>();
        const bool raw = local.inputType == RenderInputType::Raw && !viewportPreview;
        const auto& source = raw && !waveletActive ? rawCache_ : image;
        ImageData rendered;
        const auto outcome = runtime_->glesRenderer->renderWithOutcome(source, colorSpace, local, width, height,
                raw && !waveletActive ? runtime_->rawRevision : 0, rendered);
        if (outcome.succeeded()) {
            lastBackend_ = RenderBackend::Gles;
            gpuFallbackReason_ = GpuFallbackReason::None;
            gpuErrorDetail_.clear();
            return finishOutput(local, rendered, outBuffer, nativeWidth, nativeHeight, migrationFrame);
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
        if (raw && !waveletActive) image = rawCache_;
    }
#endif
#if defined(SONY2FUJI_ENABLE_D3D11)
    if (gpuPipeline) {
        checkProcessingCancellation();
        uint32_t width = static_cast<uint32_t>(image.width);
        uint32_t height = static_cast<uint32_t>(image.height);
        if (!geometryActive) {
            status = computeTargetSize(local, static_cast<uint32_t>(image.width), static_cast<uint32_t>(image.height), &width, &height);
            if (status != RenderStatus::Ok) return status;
        }
        if (!runtime_->d3dRenderer) runtime_->d3dRenderer = std::make_unique<D3D11PhotoRenderer>();
        const bool raw = local.inputType == RenderInputType::Raw && !viewportPreview;
        const auto& source = raw && !waveletActive ? rawCache_ : image;
        ImageData rendered;
        const auto outcome = runtime_->d3dRenderer->renderWithOutcome(source, colorSpace, local, width, height,
                raw && !waveletActive ? runtime_->rawRevision : 0, rendered);
        if (outcome.succeeded()) {
            lastBackend_ = RenderBackend::D3d11;
            gpuFallbackReason_ = GpuFallbackReason::None;
            gpuErrorDetail_.clear();
            return finishOutput(local, rendered, outBuffer, nativeWidth, nativeHeight, migrationFrame);
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
        if (raw && !waveletActive) image = rawCache_;
    }
#endif

    // A pixel-radius filter must run at source resolution for preview/export parity.
    if (!neighborhoodActive && !geometryActive && local.intent == RenderIntent::Preview && local.sharpening <= 0.0f &&
        local.noiseReduction <= 0.0f && chromaMode == 0 && !effectsActive && (!waveletActive || fastWavelet)) {
        uint32_t width = 0, height = 0;
        status = computeTargetSize(local, static_cast<uint32_t>(image.width), static_cast<uint32_t>(image.height), &width, &height);
        if (status != RenderStatus::Ok) return status;
        if (width != static_cast<uint32_t>(image.width) || height != static_cast<uint32_t>(image.height))
            image = resizeBilinear(image, width, height);
    }

    ColorConverter converter;
    converter.convertImage(image, colorSpace, ColorSpace::sRGB);
    colorSpace = ColorSpace::sRGB;
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) applyExposureAndWhiteBalance(image.pixels[i], exposure, wb);
    });
    if (basicToneActive) {
        applyBasicToneV3(image, basicTone, atmosphereSourceWidth, atmosphereSourceHeight);
        local.highlights = local.shadows = 0.0f;
    }

    auto lookConfig = gpuConfig_;
    if (cpuAnalysis || contractCPU || gpuPipeline || neighborhoodActive || basicControlsActive ||
        hslActive || toneControlsActive || colorGradingActive || chromaMode != 0 || waveletActive || effectsActive) {
        lookConfig.mode = GpuMode::Off;
    }
    status = applyPhotoLook(image, lut, dcp, local.lutStrength, displayInput, lookConfig);
    if (status != RenderStatus::Ok) return status;
    checkProcessingCancellation();
    applyDehaze(image, atmosphere_.dehaze, &dehazeAnalysis_,
        atmosphereSourceWidth, atmosphereSourceHeight, processingVersion_);
    if (basicV3) applyBasicBlackWhiteV3(image, toneControls_);
    else applyBlackWhite(image, toneControls_);
    applyToneAdjustments(image, local, channelCurves_, basicV3);
    if (basicV3) applyBasicVibranceV3(image, toneControls_.vibrance);
    else applyVibrance(image, toneControls_);
    if (preHsl) {
        status = finishGeometry(local, image, nativeWidth, nativeHeight);
        if (status == RenderStatus::Ok) *preHsl = std::move(image);
        return status;
    }
    applyHsl(image, hsl_);
    applyColorGrading(image, colorGrading_);
    const auto chromaResult = applyChromaDenoiseWorking(image, chromaMode);
    checkProcessingCancellation();
    if (chromaResult != ErrorCode::Success) return mapErrorCode(chromaResult);
    applyDetailAdjustments(image, local.noiseReduction, local.sharpening, atmosphere_.clarity,
        atmosphereSourceWidth, atmosphereSourceHeight, processingVersion_);
    checkProcessingCancellation();
    applyPhotoEffects(image, photoEffects_);

    return finishOutput(local, image, outBuffer, nativeWidth, nativeHeight, migrationFrame);
}

} // namespace sony2fuji
