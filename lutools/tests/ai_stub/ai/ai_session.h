#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/raw_processor.h"

#include <functional>
#include <new>
#include <stdexcept>
#include <string>

namespace sony2fuji::ai {

enum class Backend {
    Auto = 0,
    CoreML = 1,
    DirectML = 2,
    Cpu = 3
};

enum class Phase {
    Loading = 1,
    Raw = 2,
    RGB = 3,
    Saving = 4
};

using JobProgress = std::function<bool(Phase, size_t, size_t)>;

class Cancelled : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class NotReady : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class Unsupported : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class DecodeError : public std::runtime_error {
public:
    ErrorCode code;
    DecodeError(ErrorCode c, const char* message)
        : std::runtime_error(message), code(c) {}
};

struct CoreMLGraph {
    static bool available();
    static bool gpuPlanAvailable();
};

inline std::string nativeErrorText(const std::string& message) {
    return message;
}

inline std::string sourceIdentityKey(const char*, void (*)() = nullptr) {
    return {};
}

enum class ConfigureFault {
    None = 0,
    BadAlloc = 1,
    InvalidArgument = 2,
    Unknown = 3
};

class AISession {
public:
    inline static ConfigureFault nextConfigureFault = ConfigureFault::None;
    inline static int liveSessions = 0;

    AISession() { ++liveSessions; }
    ~AISession() { --liveSessions; }
    AISession(const AISession&) = delete;
    AISession& operator=(const AISession&) = delete;

    bool enabled = false;
    std::string lastError;
    std::string lastBackend;
    std::string lastModelDirectory;
    std::string lastCacheDirectory;
    Backend lastBackendPreference = Backend::Auto;

    void configure(std::string modelDirectory, std::string cacheDirectory, Backend backend) {
        const ConfigureFault fault = nextConfigureFault;
        nextConfigureFault = ConfigureFault::None;
        switch (fault) {
            case ConfigureFault::BadAlloc:
                throw std::bad_alloc();
            case ConfigureFault::InvalidArgument:
                throw std::invalid_argument("injected configure failure");
            case ConfigureFault::Unknown:
                throw 42;
            case ConfigureFault::None:
                break;
        }
        lastModelDirectory = std::move(modelDirectory);
        lastCacheDirectory = std::move(cacheDirectory);
        lastBackendPreference = backend;
    }

    void setDevice(std::string) {}
    void beginOperation(const char*) {}
    const char* diagnosticsJSON() const { return "{\"version\":1,\"logs\":[]}"; }
    void recordFailure(int, const std::string&) noexcept {}
    void prepare(const char*, const RAWProcessOptions&, const JobProgress&) {}
    void prepareHDRBayer(const char*, const std::string&, const RAWBayerSource&, bool, const JobProgress&) {}
    std::string hdrBayerKey(const char*, bool, const std::string& = {}) { return {}; }
    RAWBayerOverride loadHDRBayer(const std::string&, const RAWBayerSource&) { return {}; }
};

} // namespace sony2fuji::ai
