#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct sony2fuji_session;

namespace sony2fuji {

struct PreviewExposureDiagnostics {
    uint64_t thumbnailOpens = 0;
    uint64_t jpegDecodes = 0;
    uint64_t lastJpegSourcePixels = 0;
    uint64_t lastJpegDecodedPixels = 0;
    uint64_t cacheHits = 0;
    uint64_t cacheMisses = 0;
};

class PreviewExposureCache {
public:
    PreviewExposureCache();
    ~PreviewExposureCache();
    PreviewExposureCache(const PreviewExposureCache&) = delete;
    PreviewExposureCache& operator=(const PreviewExposureCache&) = delete;
    PreviewExposureCache(PreviewExposureCache&&) noexcept;
    PreviewExposureCache& operator=(PreviewExposureCache&&) noexcept;

    std::vector<float> getOrLoad(const std::string& path);
    PreviewExposureDiagnostics diagnostics() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

class PreviewExposureCacheScope {
    PreviewExposureCache* previous_;
public:
    explicit PreviewExposureCacheScope(PreviewExposureCache* cache);
    ~PreviewExposureCacheScope();
    PreviewExposureCacheScope(const PreviewExposureCacheScope&) = delete;
    PreviewExposureCacheScope& operator=(const PreviewExposureCacheScope&) = delete;
};

PreviewExposureCache* currentPreviewExposureCache();

bool buildFileIdentityKey(const char* inputPathStr, std::string& outKey);

// Both inputs contain linear-light sRGB luminance samples, including black.
float estimatePreviewExposureEV(std::vector<float> raw, std::vector<float> preview, bool* matched=nullptr);
std::vector<float> loadPreviewLuminance(const std::string& path);
PreviewExposureDiagnostics previewExposureDiagnostics();
PreviewExposureDiagnostics previewExposureDiagnostics(const sony2fuji_session* session);

} // namespace sony2fuji
