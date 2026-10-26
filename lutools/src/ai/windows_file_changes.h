#pragma once
#ifdef _WIN32
#include <atomic>
#include <algorithm>
#include <array>
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
    explicit FileChangeLease(const std::filesystem::path& path, uint64_t generation) : generation_(generation), name_(path.filename().wstring()) {
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
        if (!DeviceIoControl(file_, FSCTL_REQUEST_OPLOCK, &request, sizeof(request), &result_, sizeof(result_),
                             nullptr, &overlap_) && GetLastError() == ERROR_IO_PENDING) {
            pending_ = true;
            registered_ = RegisterWaitForSingleObject(&wait_, event_, changed, this, INFINITE, WT_EXECUTEONLYONCE) != 0;
            return;
        }
        CloseHandle(file_.exchange(INVALID_HANDLE_VALUE));
        // SMB 等不提供本地 RH oplock 的路径使用目录变更通知；只让当前文件的事件失效租约。
        directory_ = true;
        file_ = CreateFileW(path.parent_path().c_str(), FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, nullptr);
        if (file_ != INVALID_HANDLE_VALUE) watchDirectory();
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
    bool valid() {
        if (file_.load() == INVALID_HANDLE_VALUE || !pending_) return false;
        if (!directory_) return registered_ && WaitForSingleObject(event_, 0) == WAIT_TIMEOUT;
        // 同一次查询先消费已有的通知批次；目录持续变化时放弃复用，避免无限轮询。
        for (int batch = 0; batch < 8; ++batch) {
            if (WaitForSingleObject(event_, 0) == WAIT_TIMEOUT) return true;
            DWORD bytes = 0;
            if (!GetOverlappedResult(file_, &overlap_, &bytes, FALSE) || bytes == 0) return false;
            size_t offset = 0;
            bool complete = false;
            while (offset + sizeof(FILE_NOTIFY_INFORMATION) <= bytes) {
                const auto* change = reinterpret_cast<const FILE_NOTIFY_INFORMATION*>(notifications_.data() + offset);
                if (offset + offsetof(FILE_NOTIFY_INFORMATION, FileName) + change->FileNameLength > bytes) return false;
                if (CompareStringOrdinal(change->FileName, change->FileNameLength / sizeof(wchar_t),
                                         name_.data(), static_cast<int>(name_.size()), TRUE) == CSTR_EQUAL) return false;
                if (!change->NextEntryOffset) { complete = true; break; }
                if (change->NextEntryOffset < sizeof(FILE_NOTIFY_INFORMATION)) return false;
                offset += change->NextEntryOffset;
            }
            if (!complete || !watchDirectory()) return false;
        }
        return false;
    }

    uint64_t generation() const { return generation_; }
private:
    bool watchDirectory() {
        // Windows 将两次调用之间的通知保存在同一目录句柄的系统缓冲中；重挂时不关闭句柄。
        ResetEvent(event_); overlap_ = {}; overlap_.hEvent = event_;
        pending_ = ReadDirectoryChangesW(file_, notifications_.data(), static_cast<DWORD>(notifications_.size()), FALSE,
            FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE |
            FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_CREATION | FILE_NOTIFY_CHANGE_SECURITY,
            nullptr, &overlap_, nullptr) != 0;
        return pending_;
    }
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
    std::wstring name_;
    alignas(DWORD) std::array<unsigned char, 4096> notifications_{};
    bool pending_ = false, registered_ = false, directory_ = false;
};

inline std::optional<uint64_t> fileChangeGeneration(const std::filesystem::path& path, bool model = false) {
    struct Entry { std::unique_ptr<FileChangeLease> lease; uint64_t used; };
    static std::mutex mutex;
    static uint64_t generation = 0, access = 0;
    // 模型文件随进程保留，不与逐张打开的照片争夺租约；照片按最近使用时间淘汰。
    static std::map<std::filesystem::path, Entry> modelLeases, photoLeases;
    std::lock_guard<std::mutex> lock(mutex);
    auto& leases = model ? modelLeases : photoLeases;
    if (model) {
        for (auto entry = modelLeases.begin(); entry != modelLeases.end();)
            if (!entry->second.lease->valid()) entry = modelLeases.erase(entry); else ++entry;
    }
    const auto found = leases.find(path);
    if (found != leases.end() && found->second.lease->valid()) {
        found->second.used = ++access;
        return found->second.lease->generation();
    }
    auto lease = std::make_unique<FileChangeLease>(path, ++generation);
    if (!lease->valid()) return std::nullopt;
    // 新文件无法建立租约时保留已有条目，不能让一次失败逐出仍然有效的照片。
    if (found == leases.end() && !model && leases.size() >= 128) {
        const auto oldest = std::min_element(leases.begin(), leases.end(),
            [](const auto& left, const auto& right) { return left.second.used < right.second.used; });
        leases.erase(oldest);
    }
    const auto value = lease->generation(); leases[path] = {std::move(lease), ++access};
    return value;
}
}
#endif
