#include "core/pipeline.h"
#include "core/pipeline_runtime.h"

#include "core/image_header_probe.h"
#include "core/x3f_processor.h"

#ifdef SONY2FUJI_ENABLE_AI_DENOISE
#include "ai/ai_session.h"
#endif

#ifdef __APPLE__
#include <TargetConditionals.h>
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

bool Pipeline::buildRawCacheWbKeys(
    const RenderParams& params,
    std::string& outBaseSourceKey,
    std::string& outFileKey,
    std::string& outWbBaseKey,
    std::string& outPreviewExposureKey
) {
    const bool legacySonyCrop = sony2fuji::usesLegacySonyCrop(processingVersion_);
    if (!buildRawSourceIdentityKey(params.inputPath.c_str(), legacySonyCrop, outBaseSourceKey)) {
        return false;
    }
    outFileKey = outBaseSourceKey;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (aiEnabled()) outFileKey += ":ai-source:" + ai::sourceIdentityKey(params.inputPath.c_str());
#endif
    const std::string processingKey = ":processing:" + std::to_string(static_cast<int>(processingVersion_)) +
        ":x3f-v1:" + std::to_string(static_cast<int>(x3fMode_));
    std::string lensKey;
    if (lensCorrection_.active()) {
        ensureLensDatabase();
        lensKey = ":lens:" + std::to_string(lensDatabaseRevision_) + ":" +
            std::to_string(lensCorrection_.distortion) + ":" + std::to_string(lensCorrection_.tca) + ":" +
            std::to_string(lensCorrection_.autoCrop) + ":" + std::to_string(lensCorrection_.vignetting) + ":" +
            lensCorrection_.profileID;
    }
    const int rawNoiseReduction = aiEnabled() ? 0 : rawNoiseReduction_;
    outPreviewExposureKey = outFileKey + processingKey + lensKey;
    outWbBaseKey = outFileKey + processingKey + ":" + std::to_string(static_cast<int>(rawExposureMode_)) +
        ":" + std::to_string(rawNoiseReduction) + lensKey;
    return true;
}

RenderStatus Pipeline::loadRawImage(
    const RenderParams& params,
    ImageData& image,
    ColorSpace* space,
    bool* isLinear,
    bool copyImage,
    bool applyAI,
    bool forceFullResolution
) {
    const bool legacySonyCrop = sony2fuji::usesLegacySonyCrop(processingVersion_);
    std::string baseSourceKey, fileKey, wbBaseKey, previewExposureKey;
    if (!buildRawCacheWbKeys(params, baseSourceKey, fileKey, wbBaseKey, previewExposureKey)) {
        return RenderStatus::IoError;
    }
    const bool useAI = applyAI && aiEnabled();
    const int rawNoiseReduction = aiEnabled() ? 0 : rawNoiseReduction_;
    auto wbOptions = rawWhiteBalanceOptions(params);
    std::string aiKey;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    std::string aiSourceIdentity;
    if (useAI) {
        aiSourceIdentity = ai::sourceIdentityKey(params.inputPath.c_str());
        aiKey = ":ai:" + runtime_->ai->renderKey(params.inputPath.c_str(), wbOptions, aiSourceIdentity);
    }
#endif
    const bool normalX3f = isNormalX3f(params.inputPath.c_str(), x3fMode_);
    if (normalX3f && useAI) {
        x3fError_ = "AI RAW replacement is not supported for normal X3F rendering";
        return RenderStatus::Unsupported;
    }
    const bool interactive = !forceFullResolution && !normalX3f && !useAI && interactivePreview_ && rawNoiseReduction_ == 0 &&
        chromaDenoise_ == 0 && !photoEffects_.active() &&
        params.intent == RenderIntent::Preview &&
        params.outputTarget == RenderOutputTarget::Buffer &&
        !(rawExposureMode_ == RawExposureMode::Preview && params.wbMode == RenderWhiteBalanceMode::Camera);
    std::string key = wbBaseKey + ":" + std::to_string(static_cast<int>(params.wbMode));
    for (float multiplier : params.wbMul) key += ":" + std::to_string(multiplier);
    key += aiKey;
    if (useAI) {
        const float blend = std::clamp(aiDenoiseBlend_, 0.0f, 1.0f) + 0.0f;
        key += ":ai-blend:" + std::to_string(blend);
    }
    if (params.wbMode == RenderWhiteBalanceMode::Temperature)
        key += ":" + std::to_string(params.temperature) + ":" + std::to_string(params.tint);
    // A full-quality cache can serve a proxy, but never the reverse. Non-WB
    // sliders should not trigger another demosaic just because dragging began.
    const std::string exactKey = key + ":exact";
    const bool halfSize = interactive && (rawCache_.pixels.empty() || rawKey_ != exactKey);
    key += halfSize ? ":interactive" : ":exact";
    if (rawKey_ != key || rawCache_.pixels.empty()) {
        // 失效的整图缓存必须在下一次解码之前释放，WB/照片切换不能叠加两张 RAW。
        rawCache_ = {};
        rawKey_.clear();
        rawCacheWbBaseKey_.clear();
        rawCacheWbValid_ = false;
        rawCacheAnchoredPreview_ = false;
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
        const bool anchoredPreview = !normalX3f && rawExposureMode_ == RawExposureMode::Preview &&
            (params.wbMode == RenderWhiteBalanceMode::Temperature || useAI);
        if (anchoredPreview && previewExposureKey_ != previewExposureKey) {
            auto anchorOptions = wbOptions;
            anchorOptions.useCameraWhiteBalance = true;
            anchorOptions.useAutoWhiteBalance = false;
            anchorOptions.useCustomWhiteBalance = false;
            anchorOptions.useTemperatureWhiteBalance = false;
            anchorOptions.halfSize = true;
            anchorOptions.rawNoiseReduction = 0;
            anchorOptions.outputLinear = true;
            anchorOptions.outputAdobe = true;
            anchorOptions.lensDatabase = lensDatabase_;
            anchorOptions.lensCorrection = lensCorrection_;
            anchorOptions.matchEmbeddedPreviewExposure = true;
            anchorOptions.applyBaselineExposure = true;
            float anchorBaselineEv = 0.0f;
            ErrorCode anchorResult = ErrorCode::ProcessingError;
            try {
                PreviewExposureCacheScope previewCacheScope(&previewExposureCache_);
                anchorResult = processor.estimatePreviewExposure(anchorOptions, anchorBaselineEv);
            } catch (...) {
                rawProcessor_.reset();
                processorKey_.clear();
                throw;
            }
            if (anchorResult != ErrorCode::Success) {
                rawProcessor_.reset();
                processorKey_.clear();
                return mapErrorCode(anchorResult);
            }
            previewExposureKey_ = previewExposureKey;
            previewCameraEv_ = anchorBaselineEv;
        }
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
        std::optional<ai::PreparedDenoise> prepared;
        if (useAI) {
            RAWBayerSource metadata;
            const bool bayer = processor.getBayerMetadata(metadata);
            prepared = runtime_->ai->takeResult(params.inputPath.c_str(), wbOptions, bayer ? &metadata : nullptr, aiSourceIdentity);
            if (!prepared->isSceneRGB()) {
                prepared->bayer.blend = std::clamp(aiDenoiseBlend_, 0.0f, 1.0f);
                options.bayerOverride = &prepared->bayer;
            }
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
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
        if (prepared && !prepared->isSceneRGB()) {
            options.bayerOverride = nullptr;
            prepared.reset();
        }
#endif
        if (result != ErrorCode::Success) {
            x3fError_ = processor.getLastError();
            rawProcessor_.reset();
            processorKey_.clear();
            return mapErrorCode(result);
        }
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
        if (prepared && prepared->isSceneRGB()) {
            ai::applySceneRGBCorrection(decoded, prepared->scene, ColorSpace::AdobeRGB,
                std::exp2(processor.getBaselineExposureEV() + options.exposure) * options.brightness,
                std::clamp(aiDenoiseBlend_, 0.0f, 1.0f));
            prepared.reset();
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
        hasCachedRawWb_ = false;
        double wbFirst[3][3]{}, wbSecond[3][3]{};
        double wbFirstTemp = 0.0, wbSecondTemp = 0.0;
        float rgbCam[3][3]{};
        float wbUsed[3]{1.0f, 1.0f, 1.0f};
        if (calibratedWb_ && !normalX3f &&
            processor.getWhiteBalanceCalibration(wbFirst, wbSecond, wbFirstTemp, wbSecondTemp) &&
            processor.getLastRgbCam(rgbCam) &&
            processor.getLastWbUsed(wbUsed)) {
            std::array<std::array<double, 3>, 3> firstMat{}, secondMat{};
            for (int r = 0; r < 3; ++r) {
                for (int c = 0; c < 3; ++c) {
                    firstMat[r][c] = wbFirst[r][c];
                    secondMat[r][c] = wbSecond[r][c];
                    cachedRgbCam_[r][c] = rgbCam[r][c];
                }
                cachedWbUsed_[r] = wbUsed[r];
            }
            cachedRawWb_ = CameraWhiteBalance(firstMat, secondMat, wbFirstTemp, wbSecondTemp);
            cachedBaselineEv_ = baselineEv_;
            hasCachedRawWb_ = cachedRawWb_.available();
        }
        if (!normalX3f) {
            std::string wbFileKey;
            if (buildFileIdentityKey(params.inputPath.c_str(), wbFileKey)) {
                recipeWbCache_.valid = true;
                recipeWbCache_.fileKey = std::move(wbFileKey);
                recipeWbCache_.processingVersion = processingVersion_;
                recipeWbCache_.x3fMode = x3fMode_;
                recipeWbCache_.exposureMode = rawExposureMode_;
                recipeWbCache_.calibrated = calibratedWb_;
                recipeWbCache_.temperature = calibratedWb_ ? std::round(asShotTemperature_) : 0.0f;
                recipeWbCache_.tint = calibratedWb_ ? std::round(asShotTint_) : 0.0f;
            }
        }
        rawCacheWbBaseKey_ = wbBaseKey;
        rawCacheWbValid_ = !normalX3f && !useAI && !rawDisplayReferred_ &&
            processor.getLastAppliedWhiteBalanceMultipliers(rawCacheAppliedWbMul_.data()) &&
            processor.getCameraToSrgbMatrix(rawCacheCamToSrgb_) &&
            processor.getAsShotWhiteBalanceMultipliers(rawCacheAsShotWbMul_.data());
        rawCacheAnchoredPreview_ = rawExposureMode_ == RawExposureMode::Preview &&
            (anchoredPreview || params.wbMode == RenderWhiteBalanceMode::Camera);
        if (rawExposureMode_ == RawExposureMode::Preview && params.wbMode == RenderWhiteBalanceMode::Camera) {
            previewExposureKey_ = previewExposureKey;
            previewCameraEv_ = baselineEv_;
        }
    }
    // 预览编辑期内保留合理上限内的解包 RAW，避免大师配方切牌重读磁盘；导出或超大文件仍及时释放。
    constexpr size_t kMosaicRetainBudget =
#if (defined(__APPLE__) && TARGET_OS_IPHONE) || defined(__ANDROID__)
        64u * 1024u * 1024u;
#else
        WaveletRenderCache::defaultPreviewBudget;
#endif
    const bool keepMosaic = params.intent == RenderIntent::Preview &&
        params.outputTarget == RenderOutputTarget::Buffer &&
        rawCache_.pixels.size() * sizeof(uint16_t) <= kMosaicRetainBudget;
    if (!keepMosaic && rawCache_.pixels.size() * sizeof(RGB) > WaveletRenderCache::defaultPreviewBudget) {
        rawProcessor_.reset();
        processorKey_.clear();
        rawCacheWbValid_ = false;
        rawCacheAnchoredPreview_ = false;
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

RenderStatus Pipeline::loadRawForWbProbe(const RenderParams& params) {
    ImageData unused;
    ColorSpace space = ColorSpace::AdobeRGB;
    bool isLinear = true;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (aiEnabled()) {
        try {
            return loadRawImage(params, unused, &space, &isLinear, false, true);
        } catch (const ai::NotReady&) {
        }
    }
#endif
    return loadRawImage(params, unused, &space, &isLinear, false, false);
}

} // namespace sony2fuji
