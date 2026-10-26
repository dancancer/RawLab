#pragma once
#ifdef _WIN32
#include <atomic>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <windows.h>
#include <winioctl.h>

namespace sony2fuji::ai {
// ChangeTime 在快速写入时会重复，USN 也可能未启用。RH oplock 先通知失效，再释放读句柄，
// 外部写入和原子替换无需等待下一次渲染；通知对象由 Windows 线程池等待。
class FileChangeLease {
public:
    explicit FileChangeLease(const std::filesystem::path& path, uint64_t generation) : generation_(generation) {
        file_ = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, nullptr);
        if (file_ == INVALID_HANDLE_VALUE) return;
        event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!event_) return;
        overlap_.hEvent = event_;
        REQUEST_OPLOCK_INPUT_BUFFER request{};
        request.StructureVersion = REQUEST_OPLOCK_CURRENT_VERSION;
        request.StructureLength = sizeof(request);
        request.RequestedOplockLevel = OPLOCK_LEVEL_CACHE_READ | OPLOCK_LEVEL_CACHE_HANDLE;
        request.Flags = REQUEST_OPLOCK_INPUT_FLAG_REQUEST;
        if (DeviceIoControl(file_, FSCTL_REQUEST_OPLOCK, &request, sizeof(request), &result_, sizeof(result_),
                            nullptr, &overlap_) || GetLastError() != ERROR_IO_PENDING) return;
        pending_ = true;
        if (!RegisterWaitForSingleObject(&wait_, event_, changed, this, INFINITE, WT_EXECUTEONLYONCE)) return;
        registered_ = true;
    }
    ~FileChangeLease() {
        if (registered_) UnregisterWaitEx(wait_, INVALID_HANDLE_VALUE);
        const auto file = file_.exchange(INVALID_HANDLE_VALUE);
        if (file != INVALID_HANDLE_VALUE) {
            if (pending_) {
                CancelIoEx(file, &overlap_);
                DWORD transferred = 0; GetOverlappedResult(file, &overlap_, &transferred, TRUE);
            }
            CloseHandle(file);
        }
        if (event_) CloseHandle(event_);
    }
    FileChangeLease(const FileChangeLease&) = delete;
    bool valid() const {
        return registered_ && file_.load() != INVALID_HANDLE_VALUE && WaitForSingleObject(event_, 0) == WAIT_TIMEOUT;
    }
    uint64_t generation() const { return generation_; }
private:
    static VOID CALLBACK changed(PVOID context, BOOLEAN) {
        auto& lease = *static_cast<FileChangeLease*>(context);
        const auto file = lease.file_.exchange(INVALID_HANDLE_VALUE);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    }
    std::atomic<HANDLE> file_{INVALID_HANDLE_VALUE};
    HANDLE event_ = nullptr, wait_ = nullptr;
    OVERLAPPED overlap_{};
    REQUEST_OPLOCK_OUTPUT_BUFFER result_{};
    uint64_t generation_;
    bool pending_ = false, registered_ = false;
};

inline std::optional<uint64_t> fileChangeGeneration(const std::filesystem::path& path) {
    static std::mutex mutex;
    static uint64_t generation = 0;
    static std::map<std::filesystem::path, std::unique_ptr<FileChangeLease>> leases;
    std::lock_guard<std::mutex> lock(mutex);
    const auto found = leases.find(path);
    if (found != leases.end() && found->second->valid()) return found->second->generation();
    if (found != leases.end()) leases.erase(found);
    if (leases.size() >= 128) leases.erase(leases.begin());
    auto lease = std::make_unique<FileChangeLease>(path, ++generation);
    if (!lease->valid()) return std::nullopt;
    const auto value = lease->generation(); leases[path] = std::move(lease);
    return value;
}
}
#endif
