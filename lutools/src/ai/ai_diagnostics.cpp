#include "ai_diagnostics.h"
#include <nlohmann/json.hpp>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#endif

namespace sony2fuji::ai {
std::string nativeErrorText(const std::string& message) {
#ifdef _WIN32
    // WIL 的本地化系统错误可能使用 ANSI；公共 C ABI 和诊断文件统一输出 UTF-8。
    if (!message.empty() && message.size() <= 1024 * 1024 &&
        !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,message.data(),static_cast<int>(message.size()),nullptr,0)) {
        const auto count = MultiByteToWideChar(CP_ACP,0,message.data(),static_cast<int>(message.size()),nullptr,0);
        if (count > 0) {
            std::wstring wide(count,L'\0');
            MultiByteToWideChar(CP_ACP,0,message.data(),static_cast<int>(message.size()),wide.data(),count);
            const auto bytes = WideCharToMultiByte(CP_UTF8,0,wide.data(),count,nullptr,0,nullptr,nullptr);
            if (bytes > 0) {
                std::string result(bytes,'\0');
                WideCharToMultiByte(CP_UTF8,0,wide.data(),count,result.data(),bytes,nullptr,nullptr);
                return result;
            }
        }
    }
#endif
    return message;
}

void AIDiagnostics::reset(const std::string& requestedDevice, int backend) {
    std::lock_guard<std::mutex> lock(mutex_);
    strings_.clear(); numbers_.clear(); logs_.clear(); dropped_ = 0;
    strings_["requested_device_id"] = requestedDevice;
    numbers_["requested_backend"] = static_cast<uint64_t>(backend);
}
void AIDiagnostics::field(const std::string& name, const std::string& value) {
    std::lock_guard<std::mutex> lock(mutex_); strings_[name] = nativeErrorText(value).substr(0,16384);
}
void AIDiagnostics::field(const std::string& name, uint64_t value) {
    std::lock_guard<std::mutex> lock(mutex_); numbers_[name] = value;
}
void AIDiagnostics::device(const DirectMLAdapter& value) {
    field("selected_device_id",value.id); field("selected_device_name",value.name);
    field("selected_device_luid",value.luid); field("driver_version",value.driverVersion);
    field("device_index",static_cast<uint64_t>(value.index));
    field("vendor_id",value.vendor); field("device_id",value.device);
    field("dedicated_memory_bytes",value.dedicatedMemory); field("shared_memory_bytes",value.sharedMemory);
    field("memory_budget_bytes",value.memoryBudget); field("memory_usage_bytes",value.memoryUsage);
}
void AIDiagnostics::progress(int phase, size_t done, size_t total) {
    std::lock_guard<std::mutex> lock(mutex_);
    numbers_["phase"] = phase; numbers_["done"] = done; numbers_["total"] = total;
}
void AIDiagnostics::log(int severity, const std::string& category, const std::string& message) noexcept {
    try {
        auto text = nativeErrorText(message).substr(0,4096);
        std::lock_guard<std::mutex> lock(mutex_);
        if (logs_.size() >= 64) { logs_.pop_front(); ++dropped_; }
        logs_.push_back({severity,category.substr(0,128),std::move(text)});
    } catch (...) { /* 诊断分配失败不能替换原始 GPU 错误或逃出运行库的 C 回调。 */ }
}
void AIDiagnostics::failure(int status, const std::string& error) noexcept {
    try { field("native_status",static_cast<uint64_t>(status)); field("native_error",error); }
    catch (...) {}
}
std::string AIDiagnostics::json() const {
    std::lock_guard<std::mutex> lock(mutex_);
    nlohmann::json result = {{"version",1}, {"dropped_log_entries",dropped_}, {"logs",nlohmann::json::array()}};
    for (const auto& entry : strings_) result[entry.first] = entry.second;
    for (const auto& entry : numbers_) result[entry.first] = entry.second;
    for (const auto& entry : logs_) result["logs"].push_back({{"severity",entry.severity},
        {"category",entry.category}, {"message",entry.message}});
    return result.dump(-1,' ',false,nlohmann::json::error_handler_t::replace);
}
}
