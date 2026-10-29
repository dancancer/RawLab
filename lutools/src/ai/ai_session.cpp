#include "ai_session.h"
#include "dualdn_bridge.h"
#include "core/photo_rendering.h"
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <sstream>

namespace sony2fuji::ai {
namespace {
void notify(const JobProgress& progress, Phase phase, size_t done, size_t total) {
    if (progress && !progress(phase, done, total)) throw Cancelled();
}
std::string producers(const std::string& raw, const std::string& rgb) {
    return "RAW=" + (raw.empty() ? "unknown" : raw) + "; RGB=" + (rgb.empty() ? "unknown" : rgb);
}
}

void AISession::configure(std::string modelDirectory, std::string cacheDirectory, Backend backend) {
    if (backend != Backend::Cpu && backend != Backend::CoreML && backend != Backend::Auto && backend != Backend::DirectML)
        throw std::invalid_argument("invalid AI backend");
    if (modelDirectory_ != modelDirectory || cacheDirectory_ != cacheDirectory || backend_ != backend) {
        modelDirectory_ = std::move(modelDirectory); cacheDirectory_ = std::move(cacheDirectory); backend_ = backend;
        stamp_.clear(); runtimeDigest_.clear(); runtimeIdentity_.clear(); loadedKey_.clear(); package_.reset(); loaded_ = {};
        selectedDevice_.reset(); diagnostics_.reset(deviceID_,static_cast<int>(backend_));
        lastBackend.clear();
    }
    if (!enabled) { loaded_ = {}; loadedKey_.clear(); lastBackend.clear(); }
    lastError.clear();
}

void AISession::setDevice(std::string deviceID) {
    if (deviceID.size() > 256) throw std::invalid_argument("AI device identifier is too long");
    if (deviceID_ == deviceID) return;
    deviceID_ = std::move(deviceID); selectedDevice_.reset();
    runtimeDigest_.clear(); runtimeIdentity_.clear(); loadedKey_.clear(); loaded_ = {}; lastBackend.clear();
    diagnostics_.reset(deviceID_,static_cast<int>(backend_));
}

std::string AISession::runtimeVersion(bool refreshDevice) {
    std::string version;
    if (runtimeVersion_) version = runtimeVersion_(backend_);
    else {
#ifdef _WIN32
        if (backend_ == Backend::Auto || backend_ == Backend::DirectML) {
            if (refreshDevice) selectedDevice_.reset();
            if (!selectedDevice_) selectedDevice_ = findDirectMLAdapter(deviceID_);
            diagnostics_.device(*selectedDevice_);
        }
#else
        (void)refreshDevice;
#endif
        version = NetworkGraph::runtimeVersion(backend_,selectedDevice_ ? &*selectedDevice_ : nullptr);
    }
    runtimeIdentity_ = std::move(version);
    diagnostics_.field("runtime_identity",runtimeIdentity_);
    return runtimeIdentity_;
}

void AISession::beginOperation(const char* operation) {
    diagnostics_.reset(deviceID_,static_cast<int>(backend_));
    diagnostics_.field("operation",operation);lastError.clear();
    if (selectedDevice_) diagnostics_.device(*selectedDevice_);
    if (package_) diagnostics_.field("model_digest",package_->digest);
    if (!runtimeIdentity_.empty()) diagnostics_.field("runtime_identity",runtimeIdentity_);
}

const char* AISession::diagnosticsJSON() const {
    diagnosticsJSON_ = diagnostics_.json(); return diagnosticsJSON_.c_str();
}

std::string AISession::packageStamp() const {
    if (modelDirectory_.empty() || cacheDirectory_.empty()) throw std::invalid_argument("AI model/cache directory is not configured");
    std::ostringstream result;
    const auto root = std::filesystem::canonical(std::filesystem::u8path(modelDirectory_));
    result << root.u8string();
    for (const auto* name : {"manifest.json", "raw.onnx", "isp.onnx", "rgb.onnx", "DualDn-LICENSE.txt",
                             "blind_rgb.onnx", "Restormer-LICENSE.txt"}) {
        const auto file = root / name;
        if (!std::filesystem::exists(file)) { result << ":missing:" << name; continue; }
        result << ':' << sourceMetadataKey(file.u8string());
    }
    for (const auto* name : {"raw.mlmodelc", "rgb.mlmodelc", "blind_rgb.mlmodelc"}) {
        const auto directory = root / name;
        if (std::filesystem::is_symlink(directory)) throw std::runtime_error("AI model directory cannot be a symlink");
        if (!std::filesystem::exists(directory)) { result << ":missing:" << name; continue; }
        std::vector<std::string> files;
        size_t entries = 0;
        for (const auto& entry : std::filesystem::recursive_directory_iterator(directory)) {
            if (++entries > 128 || entry.is_symlink()) throw std::runtime_error("Invalid AI model resources");
            if (entry.is_regular_file()) files.push_back(entry.path().u8string());
            else if (!entry.is_directory()) throw std::runtime_error("Invalid AI model resource type");
        }
        std::sort(files.begin(), files.end());
        for (const auto& file : files) result << ':' << sourceMetadataKey(file);
    }
    return result.str();
}

void AISession::ensurePackage() {
    try {
        const auto stamp = packageStamp();
        if (!package_ || stamp != stamp_) {
            auto package = loadModelPackage(modelDirectory_);
            if (packageStamp() != stamp) throw std::runtime_error("AI model changed during validation");
            package_ = std::move(package); stamp_ = stamp; runtimeDigest_.clear(); loadedKey_.clear(); loaded_ = {};
        }
    } catch (const std::bad_alloc&) { throw; }
    catch (const std::exception& error) {
        lastError = std::string("Invalid AI model package: ") + error.what();
        throw std::runtime_error(lastError);
    }
    diagnostics_.field("model_digest",package_->digest);
    if (!runtimeDigest_.empty()) return;
    // 显卡选择失败是设备错误，不包装成模型损坏；同一任务的全部网络固定到该设备。
    const auto identity = package_->digest + ":" + runtimeVersion();
    runtimeDigest_ = sha256Bytes(identity.data(),identity.size());
}

std::string AISession::renderKey(const std::string& path, const RAWProcessOptions& options, const std::string& sourceIdentity) {
    if (options.useAutoWhiteBalance) {
        lastError = "AI denoising does not support automatic white balance";
        throw Unsupported(lastError);
    }
    ensurePackage();
    const auto rawKey = rawCacheKeyFromIdentity(sourceIdentity.empty() ? sourceIdentityKey(path) : sourceIdentity, runtimeDigest_, static_cast<int>(backend_));
    return rgbCacheKey(rawKey,options) + ":" + sceneRGBCacheKey(rawKey,options);
}

const PreparedDenoise& AISession::result(const std::string& path, const RAWProcessOptions& options,
                                        const RAWBayerSource* metadata, const std::string& sourceIdentity) {
    const auto identity = sourceIdentity.empty() ? sourceIdentityKey(path) : sourceIdentity;
    for (int attempt = 0; attempt < 2; ++attempt) {
        const auto key = renderKey(path, options, identity);
        if (loadedKey_ == key) return loaded_;
        const auto rawKey = rawCacheKeyFromIdentity(identity, runtimeDigest_, static_cast<int>(backend_));
        DenoiseCache cache(cacheDirectory_);
        std::string rawProducer, rgbProducer;
        // 只有 prepare 发布完整结果，渲染与导出不触发模型推理。
        loaded_ = {}; loadedKey_.clear();
        if (auto scene = cache.load(sceneRGBCacheKey(rawKey,options),CacheKind::SceneRGB,0,0,{},&rgbProducer)) {
            loaded_.scene = std::move(*scene); loadedKey_ = key; lastError.clear();
            lastBackend = "SceneRGB=" + rgbProducer;
            return loaded_;
        }
        auto raw = metadata ? cache.load(rawKey, CacheKind::Raw, metadata->width, metadata->height, {}, &rawProducer) : std::optional<Tensor>{};
        auto rgb = raw ? cache.load(rgbCacheKey(rawKey,options), CacheKind::RGB, metadata->width, metadata->height,
            sha256Bytes(raw->values.data(), raw->values.size() * sizeof(float)), &rgbProducer) : std::optional<Tensor>{};
        if (!raw || !rgb) {
            // 准备任务使用新会话；驱动/适配器身份变化或首次查询失败后，只刷新并重查一次。
            const auto runtime = package_->digest + ":" + runtimeVersion(true);
            const auto current = sha256Bytes(runtime.data(), runtime.size());
            if (attempt == 0 && current != runtimeDigest_) { runtimeDigest_ = current; continue; }
            lastError = "AI result is missing or invalid; prepare this photo before rendering or exporting";
            throw NotReady(lastError);
        }
        const int width = metadata->width, height = metadata->height;
        RAWBayerOverride replacement{width, height, std::move(raw->values), {}};
        const size_t pixels = size_t(width) * height;
        replacement.cameraCorrection.resize(pixels);
        for (size_t i = 0; i < pixels; ++i)
            replacement.cameraCorrection[i] = RGB(rgb->values[i], rgb->values[pixels+i], rgb->values[2*pixels+i]);
        loaded_.bayer = std::move(replacement); loadedKey_ = key; lastError.clear();
        lastBackend = producers(rawProducer, rgbProducer);
        return loaded_;
    }
    throw NotReady("GPU AI result is unavailable");
}

PrepareReport AISession::prepare(const std::string& path, const RAWProcessOptions& options, const JobProgress& callback) {
    selectedDevice_.reset(); runtimeDigest_.clear();
    beginOperation("prepare");
    const JobProgress progress = [&](Phase phase, size_t done, size_t total) {
        diagnostics_.progress(static_cast<int>(phase),done,total);
        return !callback || callback(phase,done,total);
    };
    lastBackend.clear();
    if (options.useAutoWhiteBalance) throw std::invalid_argument("AI denoising does not support automatic white balance");
    notify(progress, Phase::Loading, 0, 1);
    ensurePackage();
    const AIExecution execution{selectedDevice_ ? &*selectedDevice_ : nullptr,&diagnostics_};
    const auto rawKey = rawCacheKey(path, runtimeDigest_, static_cast<int>(backend_));
    const auto rgbKey = rgbCacheKey(rawKey, options);
    const auto sceneKey = sceneRGBCacheKey(rawKey,options);
    const auto modelStamp = stamp_;
    auto validateSource = [&] {
        if (rawCacheKey(path, runtimeDigest_, static_cast<int>(backend_)) != rawKey || packageStamp() != modelStamp)
            throw std::runtime_error("RAW or model changed during AI processing; please retry");
    };
    RAWProcessor processor;
    const auto loadStatus = processor.loadFile(path);
    if (loadStatus != ErrorCode::Success) throw DecodeError(loadStatus,"Cannot decode RAW for AI denoising");
    RAWBayerSource source;
    DenoiseCache cache(cacheDirectory_);
    PrepareReport report;
    NoiseParameters noise;
    bool useBayer = processor.getBayerMetadata(source);
    report.routeReason = "non-Bayer or unsupported sensor geometry";
    if (useBayer) {
        const auto sourceStatus = processor.readBayerSource(options,source);
        if (sourceStatus != ErrorCode::Success)
            throw DecodeError(sourceStatus,"Cannot read Bayer RAW with the selected white balance");
        useBayer = supportsDualDnBridge(source);
        report.routeReason = "camera matrix or white balance cannot use the DualDn bridge";
        if (useBayer) {
            try { noise = selectNoiseProfile(source); }
            catch (const NoiseEstimateUnavailable& error) { useBayer = false; report.routeReason = error.what(); }
        }
    }
    notify(progress, Phase::Loading, 1, 1);
    if (!useBayer) {
        source = {};
        report.route = "SceneRGB";
        if (package_->blindRGBPath.empty()) throw std::runtime_error("Scene RGB AI model is not installed");
        if (cache.load(sceneKey,CacheKind::SceneRGB,0,0,{},&report.rgb.backend)) {
            report.rgbCacheHit = true; notify(progress,Phase::RGB,1,1);
        } else {
            auto decode = options;
            decode.halfSize = false; decode.rawNoiseReduction = 0; decode.bayerOverride = nullptr;
            decode.outputLinear = true; decode.outputAdobe = false; decode.outputAces = false;
            decode.applyBaselineExposure = false; decode.matchEmbeddedPreviewExposure = false;
            decode.exposure = 0; decode.brightness = 1;
            ImageData scene;
            const auto decodeStatus = processor.process(decode,scene);
            if (decodeStatus != ErrorCode::Success) throw DecodeError(decodeStatus,"Cannot decode scene RGB for AI denoising");
            const auto correction = denoiseSceneRGB(scene,std::exp2(sceneExposureEV(processor.getMetadataExposureEV())),
                *package_,backend_,report.rgb,[&](size_t done,size_t total) { return !progress || progress(Phase::RGB,done,total); },execution);
            scene = {};
            validateSource(); notify(progress,Phase::Saving,0,1);
            cache.store(sceneKey,CacheKind::SceneRGB,correction.width,correction.height,
                correction.values.data(),correction.values.size(),{},report.rgb.backend);
        }
        validateSource(); notify(progress,Phase::Saving,1,1);
        try { cache.prune(uint64_t(8)*1024*1024*1024,{sceneKey}); }
        catch (const std::filesystem::filesystem_error&) {}
        loadedKey_.clear(); loaded_ = {}; lastError.clear(); lastBackend = "SceneRGB=" + report.rgb.backend;
        return report;
    }
    report.route = "Bayer"; report.routeReason.clear(); report.noise = noise;
    RAWBayerOverride denoised;
    if (auto raw = cache.load(rawKey, CacheKind::Raw, source.width, source.height, {}, &report.raw.backend)) {
        denoised = {source.width, source.height, std::move(raw->values), {}};
        report.rawCacheHit = true;
        notify(progress, Phase::Raw, 1, 1);
    } else {
        denoised = denoiseRaw(source, *package_, noise, backend_, report.raw,
            [&](size_t done, size_t total) { return !progress || progress(Phase::Raw, done, total); },execution);
        validateSource();
        notify(progress, Phase::Saving, 0, 1);
        cache.store(rawKey, CacheKind::Raw, source.width, source.height, denoised.normalizedMosaic.data(),
                    denoised.normalizedMosaic.size(), {}, report.raw.backend);
    }
    const auto rawPayload = sha256Bytes(denoised.normalizedMosaic.data(), denoised.normalizedMosaic.size() * sizeof(float));
    if (cache.load(rgbKey, CacheKind::RGB, source.width, source.height, rawPayload, &report.rgb.backend)) {
        report.rgbCacheHit = true;
        notify(progress, Phase::RGB, 1, 1);
    } else {
        const auto correction = denoiseRgb(source, denoised, *package_, noise, backend_, RGBOutput::CameraCorrection, report.rgb,
            [&](size_t done, size_t total) { return !progress || progress(Phase::RGB, done, total); },execution);
        validateSource();
        notify(progress, Phase::Saving, 0, 1);
        cache.store(rgbKey, CacheKind::RGB, source.width, source.height, correction.values.data(), correction.values.size(), rawPayload, report.rgb.backend);
    }
    validateSource();
    notify(progress, Phase::Saving, 1, 1);
    // 只清理本功能命名的可重建缓存；当前照片两阶段结果始终保留。
    try { cache.prune(uint64_t(8) * 1024 * 1024 * 1024, {rawKey, rgbKey}); }
    catch (const std::filesystem::filesystem_error&) { /* 并发缓存清理失败不撤销已完整保存的结果。 */ }
    loadedKey_.clear(); loaded_ = {}; lastError.clear();
    lastBackend = producers(report.raw.backend, report.rgb.backend);
    return report;
}
} // namespace sony2fuji::ai
