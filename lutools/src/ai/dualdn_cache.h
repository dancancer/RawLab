#pragma once
#include "dualdn_geometry.h"
#include "sony2fuji/raw_processor.h"
#include <optional>
#include <set>

namespace sony2fuji::ai {
enum class CacheKind { Raw, RGB };
std::string sourceIdentityKey(const std::string& path);
std::string rawCacheKey(const std::string& path, const std::string& modelDigest, int backend);
std::string rgbCacheKey(const std::string& rawKey, const RAWProcessOptions& options);

class DenoiseCache {
public:
    explicit DenoiseCache(std::string directory);
    std::optional<Tensor> load(const std::string& key, CacheKind kind, int width, int height,
                               const std::string& dependency = {}, std::string* producer = nullptr) const;
    void store(const std::string& key, CacheKind kind, int width, int height, const float* values, size_t count,
               const std::string& dependency = {}, const std::string& producer = {}) const;
    void prune(uint64_t byteLimit, const std::set<std::string>& protectedKeys) const;
private:
    std::string directory_;
};
} // namespace sony2fuji::ai
