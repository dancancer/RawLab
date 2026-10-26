#pragma once
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#ifdef RGB
#undef RGB
#endif
#endif

namespace sony2fuji::ai {
// 原子替换时旧读者继续读取已打开的文件，不再通过路径查询新文件的长度。
class CacheReader {
public:
    explicit CacheReader(const std::filesystem::path& path) {
#ifdef _WIN32
        handle_ = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        LARGE_INTEGER size{};
        valid_ = handle_ != INVALID_HANDLE_VALUE && GetFileSizeEx(handle_, &size) && size.QuadPart >= 0;
        if (valid_) size_ = static_cast<uint64_t>(size.QuadPart);
#else
        input_.open(path, std::ios::binary | std::ios::ate);
        valid_ = bool(input_);
        if (valid_) { size_ = static_cast<uint64_t>(input_.tellg()); input_.seekg(0); }
#endif
    }
    ~CacheReader() {
#ifdef _WIN32
        if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
#endif
    }
    CacheReader(const CacheReader&) = delete;
    CacheReader& operator=(const CacheReader&) = delete;
    explicit operator bool() const { return valid_; }
    uint64_t size() const { return size_; }
    void read(char* bytes, size_t count) {
        if (!valid_) return;
#ifdef _WIN32
        while (count) {
            const DWORD requested = static_cast<DWORD>(std::min<size_t>(count, MAXDWORD));
            DWORD received = 0;
            if (!ReadFile(handle_, bytes, requested, &received, nullptr) || received != requested) {
                valid_ = false; return;
            }
            bytes += received; count -= received;
        }
#else
        input_.read(bytes, static_cast<std::streamsize>(count)); valid_ = bool(input_);
#endif
    }
private:
    uint64_t size_ = 0;
    bool valid_ = false;
#ifdef _WIN32
    HANDLE handle_ = INVALID_HANDLE_VALUE;
#else
    std::ifstream input_;
#endif
};
}
