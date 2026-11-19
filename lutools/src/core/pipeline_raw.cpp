#include "core/pipeline.h"
#include "core/pipeline_runtime.h"

#include "core/image_header_probe.h"
#include "core/x3f_processor.h"

#ifdef SONY2FUJI_ENABLE_AI_DENOISE
#include "ai/ai_session.h"
#endif

#include <algorithm>
#include <cmath>

namespace sony2fuji {

RAWProcessOptions Pipeline::rawWhiteBalanceOptions(const RenderParams& params) const {
    RAWProcessOptions options;
    options.legacySonyCrop = sony2fuji::usesLegacySonyCrop(processingVersion_);
    options.bayerDemosaic = processingVersion_ == ProcessingVersion::Legacy
        ? BayerDemosaicMethod::Legacy
        : BayerDemosaicMethod::VNG;
    options.useCameraWhiteBalance = params.wbMode == RenderWhiteBalanceMode::Camera;
    options.useAutoWhiteBalance = params.wbMode == RenderWhiteBalanceMode::Auto;
    options.useCustomWhiteBalance = params.wbMode == RenderWhiteBalanceMode::Custom;
    options.useTemperatureWhiteBalance = params.wbMode == RenderWhiteBalanceMode::Temperature;
    options.temperature = params.temperature;
    options.tint = params.tint;
    std::copy(params.wbMul.begin(), params.wbMul.end(), options.customWhiteBalance);
    options.lensDatabase = lensDatabase_;
    options.lensCorrection = lensCorrection_;
    options.x3fMode = x3fMode_;
    if (options.x3fMode == X3fMode::Normal && !params.inputPath.empty() &&
        hasX3fSignature(params.inputPath)) {
        // 正常 X3F 的保存 WB 已显影；用户调整在 display-linear RGB 上相对应用。
        options.useCameraWhiteBalance = true;
        options.useCustomWhiteBalance = false;
        options.useTemperatureWhiteBalance = false;
    }
    return options;
}

RenderStatus Pipeline::loadRawImage(
    const RenderParams& params,
    ImageData& image,
    ColorSpace* space,
    bool* isLinear,
    bool copyImage,
    bool applyAI
) {
    const bool legacySonyCrop = sony2fuji::usesLegacySonyCrop(processingVersion_);
    std::string baseSourceKey;
    if (!buildRawSourceIdentityKey(params.inputPath.c_str(), legacySonyCrop, baseSourceKey)) {
        return RenderStatus::IoError;
    }
    std::string fileKey = baseSourceKey;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    const auto aiSourceIdentity = aiEnabled() ? ai::sourceIdentityKey(params.inputPath.c_str()) : std::string();
    if (aiEnabled()) fileKey += ":ai-source:" + aiSourceIdentity;
#endif
    const bool useAI = applyAI && aiEnabled();
    const int rawNoiseReduction = aiEnabled() ? 0 : rawNoiseReduction_;
    if (lensCorrection_.active()) ensureLensDatabase();
    auto wbOptions = rawWhiteBalanceOptions(params);
    std::string aiKey;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (useAI) aiKey = ":ai:" + runtime_->ai->renderKey(params.inputPath.c_str(), wbOptions, aiSourceIdentity);
#endif
    const bool normalX3f = x3fMode_ == X3fMode::Normal && hasX3fSignature(params.inputPath);
    if (normalX3f && useAI) {
        x3fError_ = "AI RAW replacement is not supported for normal X3F rendering";
        return RenderStatus::Unsupported;
    }
    const bool interactive = !normalX3f && !useAI && interactivePreview_ && rawNoiseReduction_ == 0 &&
        chromaDenoise_ == 0 && !photoEffects_.active() &&
        params.intent == RenderIntent::Preview &&
        params.outputTarget == RenderOutputTarget::Buffer &&
        !(rawExposureMode_ == RawExposureMode::Preview && params.wbMode == RenderWhiteBalanceMode::Camera);
    const std::string processingKey = ":processing:" + std::to_string(static_cast<int>(processingVersion_)) +
        ":x3f-v1:" + std::to_string(static_cast<int>(x3fMode_));
    std::string key = fileKey + processingKey + ":" + std::to_string(static_cast<int>(params.wbMode)) +
        ":" + std::to_string(static_cast<int>(rawExposureMode_)) + ":" + std::to_string(rawNoiseReduction);
    for (float multiplier : params.wbMul) key += ":" + std::to_string(multiplier);
    key += aiKey;
    if (params.wbMode == RenderWhiteBalanceMode::Temperature)
        key += ":" + std::to_string(params.temperature) + ":" + std::to_string(params.tint);
    std::string lensKey;
    if (lensCorrection_.active()) {
        ensureLensDatabase();
        lensKey = ":lens:" + std::to_string(lensDatabaseRevision_) + ":" +
            std::to_string(lensCorrection_.distortion) + ":" + std::to_string(lensCorrection_.tca) + ":" +
            std::to_string(lensCorrection_.autoCrop) + ":" + std::to_string(lensCorrection_.vignetting) + ":" +
            lensCorrection_.profileID;
    }
    key += lensKey;
    // AI 沿用原片的拍摄白平衡预览锚点，不能因去噪/改 WB 再次改变基础曝光。
    const std::string previewExposureKey = fileKey + processingKey + lensKey;
    // A full-quality cache can serve a proxy, but never the reverse. Non-WB
    // sliders should not trigger another demosaic just because dragging began.
    const std::string exactKey = key + ":exact";
    const bool halfSize = interactive && (rawCache_.pixels.empty() || rawKey_ != exactKey);
    key += halfSize ? ":interactive" : ":exact";
    if (rawKey_ != key || rawCache_.pixels.empty()) {
        const bool anchoredPreview = rawExposureMode_ == RawExposureMode::Preview &&
            (params.wbMode == RenderWhiteBalanceMode::Temperature || useAI);
        if (anchoredPreview && previewExposureKey_ != previewExposureKey) {
            auto reference = params;
            reference.wbMode = RenderWhiteBalanceMode::Camera;
            const auto status = loadRawImage(reference, image, space, isLinear, false, false);
            image = {};
            if (status != RenderStatus::Ok) return status;
        }
        // 失效的整图缓存必须在下一次解码之前释放，WB/照片切换不能叠加两张 RAW。
        rawCache_ = {};
        rawKey_.clear();
        if (!rawProcessor_ || processorKey_ != fileKey) {
            rawProcessor_.reset();
            processorKey_.clear();
            auto processor = std::make_unique<RAWProcessor>(legacySonyCrop);
            const auto loaded = processor->loadFile(params.inputPath, x3fMode_);
            if (loaded != ErrorCode::Success) return mapErrorCode(loaded);
            rawProcessor_ = std::move(processor);
            processorKey_ = fileKey;
        }
        auto& processor = *rawProcessor_;
        auto options = wbOptions;
        options.halfSize = halfSize;
        options.rawNoiseReduction = rawNoiseReduction;
        options.outputLinear = true;
        options.outputAdobe = true;
        options.lensDatabase = lensDatabase_;
        options.lensCorrection = lensCorrection_;
        options.matchEmbeddedPreviewExposure = rawExposureMode_ == RawExposureMode::Preview && !anchoredPreview;
        options.applyBaselineExposure = rawExposureMode_ != RawExposureMode::Sensor && !anchoredPreview;
        if (anchoredPreview) options.exposure = previewCameraEv_;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
        const ai::PreparedDenoise* prepared = nullptr;
        if (useAI) {
            RAWBayerSource metadata;
            const bool bayer = processor.getBayerMetadata(metadata);
            prepared = &runtime_->ai->result(params.inputPath.c_str(), wbOptions, bayer ? &metadata : nullptr, aiSourceIdentity);
            if (!prepared->isSceneRGB()) options.bayerOverride = &prepared->bayer;
        }
#endif
        ImageData decoded;
        ErrorCode result;
        try {
            PreviewExposureCacheScope previewCacheScope(&previewExposureCache_);
            result = processor.process(options, decoded);
        } catch (...) {
            rawProcessor_.reset();
            processorKey_.clear();
            throw;
        }
        if (result != ErrorCode::Success) {
            x3fError_ = processor.getLastError();
            rawProcessor_.reset();
            processorKey_.clear();
            return mapErrorCode(result);
        }
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
        if (prepared && prepared->isSceneRGB()) {
            ai::applySceneRGBCorrection(decoded, prepared->scene, ColorSpace::AdobeRGB,
                std::exp2(processor.getBaselineExposureEV() + options.exposure) * options.brightness);
        }
#endif
        rawNativeSize_ = halfSize ? processor.getNativeOutputSize() : std::pair{decoded.width, decoded.height};
        if (rawNativeSize_.first > 0 && rawNativeSize_.second > 0) {
            probedHeaderKey_ = baseSourceKey + ":x3f:" + std::to_string(static_cast<int>(x3fMode_));
            probedHeaderResult_ = ProbeSizeResult::Probed;
            probedHeaderWidth_ = static_cast<uint32_t>(rawNativeSize_.first);
            probedHeaderHeight_ = static_cast<uint32_t>(rawNativeSize_.second);
        }
        rawCache_ = std::move(decoded);
        ++rawDecodeCount_;
        rawDisplayReferred_ = processor.isDisplayReferred();
        rawLensReport_ = processor.getLensCorrectionReport();
#if defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
        if (runtime_) ++runtime_->rawRevision;
#endif
        rawKey_ = key;
        rawNoiseReductionSupported_ = processor.supportsNoiseReduction();
        baselineEv_ = anchoredPreview ? previewCameraEv_ : processor.getBaselineExposureEV();
        metadataEv_ = processor.getMetadataExposureEV();
        calibratedWb_ = processor.getAsShotWhiteBalance(asShotTemperature_, asShotTint_);
        if (rawExposureMode_ == RawExposureMode::Preview && params.wbMode == RenderWhiteBalanceMode::Camera) {
            previewExposureKey_ = previewExposureKey;
            previewCameraEv_ = baselineEv_;
        }
    }
    // 大图已保存全部元数据，后续调色不再需要 LibRaw 的解包像素。
    if (rawCache_.pixels.size() * sizeof(RGB) > WaveletRenderCache::defaultPreviewBudget) {
        rawProcessor_.reset();
        processorKey_.clear();
    }
    lensReport_ = rawLensReport_;
    if (copyImage) image = rawCache_;
    else {
        image.width = rawCache_.width;
        image.height = rawCache_.height;
    }
    *space = ColorSpace::AdobeRGB;
    *isLinear = true;
    return RenderStatus::Ok;
}

} // namespace sony2fuji
