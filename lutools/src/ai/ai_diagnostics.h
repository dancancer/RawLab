#pragma once
#include "directml_device.h"
#include <deque>
#include <map>
#include <mutex>
#include <string>

namespace sony2fuji::ai {
std::string nativeErrorText(const std::string& message);

class AIDiagnostics {
public:
    void reset(const std::string& requestedDevice, int backend);
    void field(const std::string& name, const std::string& value);
    void field(const std::string& name, uint64_t value);
    void device(const DirectMLAdapter& value);
    void progress(int phase, size_t done, size_t total);
    void log(int severity, const std::string& category, const std::string& message) noexcept;
    void failure(int status, const std::string& error) noexcept;
    std::string json() const;
private:
    struct Entry { int severity; std::string category, message; };
    mutable std::mutex mutex_;
    std::map<std::string,std::string> strings_;
    std::map<std::string,uint64_t> numbers_;
    std::deque<Entry> logs_;
    uint64_t dropped_ = 0;
};

struct AIExecution {
    const DirectMLAdapter* device = nullptr;
    AIDiagnostics* diagnostics = nullptr;
};
}
