#pragma once

#include "core/resource_file_stamp.h"

#include <array>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace sony2fuji {

enum class SourcePinStatus {
    Ok,
    InvalidPath,
    IoError,
    SourceChanged,
    TooLarge,
    Cancelled,
};

struct PinnedSourceOptions {
    uint64_t maxBytes = 512ull * 1024 * 1024;
    bool allowEmpty = false;
    bool checkCancellation = true;
    bool computeSha256 = true;
    bool rejectSymlink = false;
    const uint8_t* expectedSha256 = nullptr;
    std::function<void(uint64_t size)> beforeAlloc;
    std::function<void()> onReadChunkTestHook;
};

class PinnedSourceFile {
public:
    static SourcePinStatus pinAndRead(
        const std::filesystem::path& path,
        const PinnedSourceOptions& options,
        PinnedSourceFile& outPinned,
        std::vector<uint8_t>& outBytes,
        std::string* outMessage = nullptr);

    static SourcePinStatus pinIdentity(
        const std::filesystem::path& path,
        bool rejectSymlink,
        PinnedSourceFile& outPinned,
        std::string* outMessage = nullptr);

    bool verifyUnchanged() const;

    static bool isSameFile(const std::filesystem::path& a, const std::filesystem::path& b);
    static bool isSymlinkOrReparse(const std::filesystem::path& path);

    const std::filesystem::path& path() const noexcept { return path_; }
    const ResourceFileStamp& stamp() const noexcept { return stamp_; }
    const std::array<uint8_t, 32>& sha256() const noexcept { return sha256_; }
    bool hasSha256() const noexcept { return hasSha256_; }
    bool valid() const noexcept { return valid_; }

private:
    std::filesystem::path path_;
    ResourceFileStamp stamp_{};
    std::array<uint8_t, 32> sha256_{};
    bool rejectSymlink_ = false;
    bool hasSha256_ = false;
    bool valid_ = false;
};

uint64_t sourceHashPassCount();
void resetSourceHashPassCount();
void recordSourceHashPass();
extern void (*sourceReadTestHook)();

} // namespace sony2fuji
