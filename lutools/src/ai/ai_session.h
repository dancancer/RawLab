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
    std::string route, routeReason;
    NoiseParameters noise;
};
struct PreparedDenoise {
    RAWBayerOverride bayer;
    Tensor scene;
    bool isSceneRGB() const { return !scene.values.empty(); }
};

// 与渲染 session 一样由一个工作线程持有。跨 session 只共享原子完成的磁盘缓存。
class AISession {
public:
    explicit AISession(std::function<std::string(Backend)> runtimeVersion = {})
        : runtimeVersion_(std::move(runtimeVersion)) {}
    bool enabled = false;
    std::string lastError, lastBackend;
    void configure(std::string modelDirectory, std::string cacheDirectory, Backend backend);
    void setDevice(std::string deviceID);
    void beginOperation(const char* operation);
    const char* diagnosticsJSON() const;
    void recordFailure(int status, const std::string& error) noexcept { diagnostics_.failure(status,error); }
    std::string renderKey(const std::string& path, const RAWProcessOptions& options, const std::string& sourceIdentity = {});
    const PreparedDenoise& result(const std::string& path, const RAWProcessOptions& options, const RAWBayerSource* metadata, const std::string& sourceIdentity = {});
    PrepareReport prepare(const std::string& path, const RAWProcessOptions& options, const JobProgress& progress);
private:
    void ensurePackage();
    std::string runtimeVersion(bool refreshDevice = false);
    std::string packageStamp() const;
    std::string modelDirectory_, cacheDirectory_, stamp_, runtimeDigest_, runtimeIdentity_, loadedKey_;
    std::function<std::string(Backend)> runtimeVersion_;
    std::string deviceID_;
    std::optional<DirectMLAdapter> selectedDevice_;
    AIDiagnostics diagnostics_;
    mutable std::string diagnosticsJSON_;
    Backend backend_ = Backend::Auto;
    std::optional<ModelPackage> package_;
    PreparedDenoise loaded_;
};
} // namespace sony2fuji::ai
