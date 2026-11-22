#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef NOGDI
#define NOGDI
#endif
#include <windows.h>
#ifdef RGB
#undef RGB
#endif
#else
#include <sys/stat.h>
#endif

namespace sony2fuji {

struct ResourceFileStamp {
    uint64_t size;
    std::array<uint64_t, 2> modified, changed, identity;
    bool operator==(const ResourceFileStamp& other) const {
        return size == other.size && modified == other.modified && changed == other.changed && identity == other.identity;
    }
};

#ifdef _WIN32
inline std::optional<ResourceFileStamp> resourceFileStampFromHandle(HANDLE file) {
    if (file == INVALID_HANDLE_VALUE || !file) return std::nullopt;
    BY_HANDLE_FILE_INFORMATION info{};
    FILE_BASIC_INFO basic{};
    const bool valid = GetFileInformationByHandle(file, &info) &&
        GetFileInformationByHandleEx(file, FileBasicInfo, &basic, sizeof(basic));
    if (!valid || (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) return std::nullopt;
    return ResourceFileStamp{(uint64_t(info.nFileSizeHigh) << 32) | info.nFileSizeLow,
        {uint64_t(basic.LastWriteTime.QuadPart), 0}, {uint64_t(basic.ChangeTime.QuadPart), 0},
        {info.dwVolumeSerialNumber, (uint64_t(info.nFileIndexHigh) << 32) | info.nFileIndexLow}};
}
#endif

// ctime/ChangeTime 与文件身份保留同大小覆写后恢复 mtime 的失效语义。
inline std::optional<ResourceFileStamp> resourceFileStamp(const std::filesystem::path& path) {
#ifdef _WIN32
    const auto file = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return std::nullopt;
    const auto stamp = resourceFileStampFromHandle(file);
    CloseHandle(file);
    return stamp;
#else
    struct stat info{};
    if (::stat(path.c_str(), &info) || !S_ISREG(info.st_mode) || info.st_size < 0) return std::nullopt;
#ifdef __APPLE__
    const auto modified = info.st_mtimespec, changed = info.st_ctimespec;
#else
    const auto modified = info.st_mtim, changed = info.st_ctim;
#endif
    return ResourceFileStamp{uint64_t(info.st_size),
        {uint64_t(modified.tv_sec), uint64_t(modified.tv_nsec)},
        {uint64_t(changed.tv_sec), uint64_t(changed.tv_nsec)}, {uint64_t(info.st_dev), uint64_t(info.st_ino)}};
#endif
}

inline std::string resourceFileStampKey(const ResourceFileStamp& stamp) {
    std::string key = std::to_string(stamp.size);
    for (const auto& fields : {stamp.modified, stamp.changed, stamp.identity})
        for (const auto value : fields) key += ":" + std::to_string(value);
    return key;
}

} // namespace sony2fuji
