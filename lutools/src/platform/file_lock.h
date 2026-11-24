#pragma once

#include <cstdint>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>

namespace sony2fuji {
namespace platform {

struct StoreError : public std::runtime_error {
    int status;
    std::string code;
    StoreError(int statusCode, std::string errorCode, const std::string& msg)
        : std::runtime_error(msg), status(statusCode), code(std::move(errorCode)) {}
};

struct MacFileIdentity {
    uint64_t fileNumber = 0;
    double modified = 0.0;
    std::string path;
    uint64_t size = 0;
};

struct WindowsFileIdentity {
    std::string path;
    uint64_t length = 0;
    int64_t modified = 0;
    int64_t created = 0;
    std::string fileId;
};

class ScopedFileLock {
public:
    explicit ScopedFileLock(const std::filesystem::path& lockPath);
    ~ScopedFileLock();
    ScopedFileLock(const ScopedFileLock&) = delete;
    ScopedFileLock& operator=(const ScopedFileLock&) = delete;
    ScopedFileLock(ScopedFileLock&& other) noexcept;
    ScopedFileLock& operator=(ScopedFileLock&& other) noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

std::filesystem::path pathFromUtf8(const std::string& utf8);
std::string pathToUtf8(const std::filesystem::path& path);

std::filesystem::path resolveControlledSubpath(
    const std::filesystem::path& dataDir,
    const std::string& subdir,
    const std::string& filename);

std::string readFileBytes(const std::filesystem::path& path, int errorStatus = 3, const std::string& errorCode = "io_error");
void atomicWriteBytes(const std::filesystem::path& targetPath, const std::string& bytes);

MacFileIdentity readMacFileIdentity(const std::filesystem::path& photoPath);
WindowsFileIdentity readWindowsFileIdentity(const std::filesystem::path& photoPath);

std::string normalizePresetNameUtf8(const std::string& rawName);
std::string generateUuidV4Lowercase();
int64_t currentUnixMillis();

} // namespace platform
} // namespace sony2fuji
