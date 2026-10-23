#pragma once
#include "dualdn_cache.h"
#include "dualdn_runtime.h"

namespace sony2fuji::ai {
class NotReady : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};
class Unsupported : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};
enum class Phase { Loading = 1, Raw = 2, RGB = 3, Saving = 4 };
using JobProgress = std::function<bool(Phase, size_t, size_t)>;

struct PrepareReport {
    bool rawCacheHit = false, rgbCacheHit = false;
    RuntimeReport raw, rgb;
};

// 与渲染 session 一样由一个工作线程持有。跨 session 只共享原子完成的磁盘缓存。
class AISession {
public:
    bool enabled = false;
    std::string lastError, lastBackend;
    void configure(std::string modelDirectory, std::string cacheDirectory, Backend backend);
    std::string renderKey(const std::string& path, const RAWProcessOptions& options);
    const RAWBayerOverride& result(const std::string& path, const RAWProcessOptions& options, const RAWBayerSource& metadata);
    PrepareReport prepare(const std::string& path, const RAWProcessOptions& options, const JobProgress& progress);
private:
    void ensurePackage();
    std::string packageStamp() const;
    std::string modelDirectory_, cacheDirectory_, stamp_, runtimeDigest_, loadedKey_;
    Backend backend_ = Backend::Cpu;
    std::optional<ModelPackage> package_;
    RAWBayerOverride loaded_;
};
} // namespace sony2fuji::ai
