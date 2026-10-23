#include "ai_session.h"
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
        stamp_.clear(); runtimeDigest_.clear(); loadedKey_.clear(); package_.reset(); loaded_ = {};
        lastBackend.clear();
    }
    lastError.clear();
}

std::string AISession::packageStamp() const {
    if (modelDirectory_.empty() || cacheDirectory_.empty()) throw std::invalid_argument("AI model/cache directory is not configured");
    std::ostringstream result;
    const auto root = std::filesystem::canonical(std::filesystem::u8path(modelDirectory_));
    result << root.u8string();
    for (const auto* name : {"manifest.json", "raw.onnx", "isp.onnx", "rgb.onnx"}) {
        const auto file = root / name;
        result << ':' << sourceIdentityKey(file.u8string());
    }
    for (const auto* name : {"raw.mlmodelc", "rgb.mlmodelc"}) {
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
        for (const auto& file : files) result << ':' << sourceIdentityKey(file);
    }
    return result.str();
}

void AISession::ensurePackage() {
    const auto stamp = packageStamp();
    if (package_ && stamp == stamp_) return;
    auto package = loadModelPackage(modelDirectory_);
    if (packageStamp() != stamp) throw std::runtime_error("AI model changed during validation");
    const auto identity = package.digest + ":" + NetworkGraph::runtimeVersion(backend_);
    runtimeDigest_ = sha256Bytes(identity.data(), identity.size());
    package_ = std::move(package); stamp_ = stamp; loadedKey_.clear(); loaded_ = {};
}

std::string AISession::renderKey(const std::string& path, const RAWProcessOptions& options) {
    if (options.useAutoWhiteBalance) {
        lastError = "AI denoising does not support automatic white balance";
        throw Unsupported(lastError);
    }
    try {
        ensurePackage();
        return rgbCacheKey(rawCacheKey(path, runtimeDigest_, static_cast<int>(backend_)), options);
    } catch (const std::bad_alloc&) { throw; }
    catch (const std::exception& error) { lastError = error.what(); throw NotReady(lastError); }
}

const RAWBayerOverride& AISession::result(const std::string& path, const RAWProcessOptions& options, const RAWBayerSource& metadata) {
    try { selectNoiseProfile(metadata); }
    catch (const std::invalid_argument& error) { lastError = error.what(); throw Unsupported(lastError); }
    const int width = metadata.width, height = metadata.height;
    const auto key = renderKey(path, options);
    if (loadedKey_ == key && loaded_.width == width && loaded_.height == height) return loaded_;
    const auto rawKey = rawCacheKey(path, runtimeDigest_, static_cast<int>(backend_));
    DenoiseCache cache(cacheDirectory_);
    std::string rawProducer, rgbProducer;
    auto raw = cache.load(rawKey, CacheKind::Raw, width, height, {}, &rawProducer);
    // RGB 修正必须对应实际 RAW 输出；损坏后重算的结果不同则不能混用旧修正。
    auto rgb = raw ? cache.load(key, CacheKind::RGB, width, height,
        sha256Bytes(raw->values.data(), raw->values.size() * sizeof(float)), &rgbProducer) : std::optional<Tensor>{};
    if (!raw || !rgb) {
        lastError = "AI result is missing or invalid; prepare this photo before rendering or exporting";
        throw NotReady(lastError);
    }
    RAWBayerOverride replacement{width, height, std::move(raw->values), {}};
    const size_t pixels = size_t(width) * height;
    replacement.cameraCorrection.resize(pixels);
    for (size_t i = 0; i < pixels; ++i)
        replacement.cameraCorrection[i] = RGB(rgb->values[i], rgb->values[pixels+i], rgb->values[2*pixels+i]);
    loaded_ = std::move(replacement); loadedKey_ = key; lastError.clear();
    lastBackend = producers(rawProducer, rgbProducer);
    return loaded_;
}

PrepareReport AISession::prepare(const std::string& path, const RAWProcessOptions& options, const JobProgress& progress) {
    lastBackend.clear();
    notify(progress, Phase::Loading, 0, 1);
    ensurePackage();
    const auto rawKey = rawCacheKey(path, runtimeDigest_, static_cast<int>(backend_));
    const auto rgbKey = rgbCacheKey(rawKey, options);
    const auto modelStamp = stamp_;
    auto validateSource = [&] {
        if (rawCacheKey(path, runtimeDigest_, static_cast<int>(backend_)) != rawKey || packageStamp() != modelStamp)
            throw std::runtime_error("RAW or model changed during AI processing; please retry");
    };
    RAWProcessor processor;
    if (processor.loadFile(path) != ErrorCode::Success) throw std::runtime_error("Cannot decode RAW for AI denoising");
    RAWBayerSource source;
    if (processor.readBayerSource(options, source) != ErrorCode::Success)
        throw std::invalid_argument("AI denoising requires a supported Bayer RAW and white balance");
    const auto noise = selectNoiseProfile(source);
    notify(progress, Phase::Loading, 1, 1);
    DenoiseCache cache(cacheDirectory_);
    PrepareReport report;
    RAWBayerOverride denoised;
    if (auto raw = cache.load(rawKey, CacheKind::Raw, source.width, source.height, {}, &report.raw.backend)) {
        denoised = {source.width, source.height, std::move(raw->values), {}};
        report.rawCacheHit = true;
        notify(progress, Phase::Raw, 1, 1);
    } else {
        denoised = denoiseRaw(source, *package_, noise, backend_, report.raw,
            [&](size_t done, size_t total) { return !progress || progress(Phase::Raw, done, total); });
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
            [&](size_t done, size_t total) { return !progress || progress(Phase::RGB, done, total); });
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
