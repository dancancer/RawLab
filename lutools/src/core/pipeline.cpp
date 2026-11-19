#include "core/pipeline.h"
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

#if defined(SONY2FUJI_ENABLE_METAL)
#include "gpu/photo_gpu.h"
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>

namespace sony2fuji {

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
        ~Restore() {
            pipeline.lastBackend_ = backend;
            pipeline.geometryWidth_ = width;
            pipeline.geometryHeight_ = height;
        }
    } restore{*this, lastBackend_, geometryWidth_, geometryHeight_};

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
    if (gpuConfig_.mode == GpuMode::Force || aiEnabled()) {
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

RenderStatus Pipeline::processImpl(
    const RenderParams& params,
    OwnedPixelBuffer* outBuffer,
    ImageData* preHsl,
    std::shared_ptr<LUT3D> previewLut,
    MigrationFrame* migrationFrame
) {
    x3fError_.clear();
    unsupportedReason_ = UnsupportedReason::None;
    checkProcessingCancellation();
    geometryWidth_ = geometryHeight_ = 0;

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
    const bool normalX3f = local.inputType == RenderInputType::Raw && x3fMode_ == X3fMode::Normal &&
        hasX3fSignature(local.inputPath);
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
        }
        return RenderStatus::Unsupported;
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
        return RenderStatus::Unsupported;
    }
    // 预览到缓冲（含未开启视口标志的预览）必须保留大图 RAW 缓存供下一次渲染复用；
    // 只有导出才把工作图移走缓存来省一次整幅拷贝。
    const bool previewToBuffer = local.intent == RenderIntent::Preview &&
        local.outputTarget == RenderOutputTarget::Buffer;
    bool viewportPreview = viewportPreview_ && previewToBuffer;
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
    if ((cpuOnlyStages || c5Wavelet) && effectiveGpuMode == GpuMode::Force) {
        unsupportedReason_ = UnsupportedReason::ForceGpu;
        return RenderStatus::Unsupported;
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
            if (effectiveGpuMode == GpuMode::Force) {
                unsupportedReason_ = UnsupportedReason::ForceGpu;
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
    if (effectiveGpuMode == GpuMode::Force) {
        unsupportedReason_ = UnsupportedReason::ForceGpu;
        return RenderStatus::Unsupported;
    }
#endif
    // Reuse the reference stages; scene-view GPU shaders retain their existing
    // contract. Auto explicitly falls back for display-referred input.
    if (displayInput) sessionGpuPipeline = false;
    const bool contractCPU = lut && lut->requiresCPU();
    if (contractCPU) {
        if (effectiveGpuMode == GpuMode::Force) {
            unsupportedReason_ = UnsupportedReason::ForceGpu;
            return RenderStatus::Unsupported;
        }
        sessionGpuPipeline = false;
    }
    bool gpuPipeline = !cpuAnalysis && sessionGpuPipeline;
    checkProcessingCancellation();

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
    const auto reference = whiteBalanceForTempTint(6500.0f, 0.0f);
    const auto selected = whiteBalanceForTempTint(local.temperature, local.tint);
    const float exposure = std::pow(2.0f, local.exposureEV) * local.brightness;
    RGB wb(1, 1, 1);
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
    if ((local.inputType == RenderInputType::Buffer || displayInput) && local.wbMode == RenderWhiteBalanceMode::Custom) {
        wb.r *= local.wbMul[0] / local.wbMul[1];
        wb.b *= local.wbMul[2] / local.wbMul[1];
    }

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
            auto result = filter(mode);
            checkProcessingCancellation();
            const bool fallback = result != ErrorCode::Success && effectiveGpuMode == GpuMode::Auto;
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
        if (renderPhotoMetal(source, colorSpace, local, width, height, rendered)) {
            lastBackend_ = RenderBackend::Metal;
            return finishOutput(local, rendered, outBuffer, nativeWidth, nativeHeight, migrationFrame);
        }
        if (gpuConfig_.mode == GpuMode::Force) return RenderStatus::ProcessingError;
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
        if (runtime_->glesRenderer->render(source, colorSpace, local, width, height,
                raw && !waveletActive ? runtime_->rawRevision : 0, rendered)) {
            lastBackend_ = RenderBackend::Gles;
            return finishOutput(local, rendered, outBuffer, nativeWidth, nativeHeight, migrationFrame);
        }
        if (gpuConfig_.mode == GpuMode::Force) return RenderStatus::ProcessingError;
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
        if (runtime_->d3dRenderer->render(source, colorSpace, local, width, height,
                raw && !waveletActive ? runtime_->rawRevision : 0, rendered)) {
            lastBackend_ = RenderBackend::D3d11;
            return finishOutput(local, rendered, outBuffer, nativeWidth, nativeHeight, migrationFrame);
        }
        if (gpuConfig_.mode == GpuMode::Force) return RenderStatus::ProcessingError;
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
