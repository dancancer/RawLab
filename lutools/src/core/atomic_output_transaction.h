#pragma once

#include <cstddef>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <string>

namespace sony2fuji {

enum class OutputModePolicy {
    PreserveDestinationOrUmask,
    Private0600,
    Standard0644,
};

enum class AtomicOutputStatus {
    Ok,
    InvalidArgument,
    IoError,
    Cancelled,
    PreCommitRejected,
};

struct AtomicOutputOptions {
    std::string stagingPrefix = ".rawlab-tmp";
    std::string stagingExtension = ".tmp";
    bool includeDestinationFilename = false;
    OutputModePolicy modePolicy = OutputModePolicy::PreserveDestinationOrUmask;
    bool rejectSymlinkTarget = false;
    bool createParentDirs = false;
    bool syncFile = true;
    bool syncParentDir = false;
    bool winRetryOnTransient = true;
    bool openReadWrite = false;
    bool fileAttributeTemporary = false;
};

class AtomicOutputTransaction {
public:
    explicit AtomicOutputTransaction(std::filesystem::path destination, AtomicOutputOptions options = {});
    ~AtomicOutputTransaction();

    AtomicOutputTransaction(const AtomicOutputTransaction&) = delete;
    AtomicOutputTransaction& operator=(const AtomicOutputTransaction&) = delete;

    AtomicOutputStatus begin(std::string* outError = nullptr);

    AtomicOutputStatus writeAll(
        const void* data,
        size_t size,
        bool checkCancellation = false,
        std::string* outError = nullptr);

    std::FILE* openStdioWrite();

    int releasePosixFdForExternalOwner();
#ifdef _WIN32
    void* releaseWin32HandleForExternalOwner();
#endif
    void markExternalOwnerClosed();

    AtomicOutputStatus commit(
        const std::function<bool()>& preCommitCheck = {},
        std::string* outError = nullptr);

    void rollback() noexcept;

    const std::filesystem::path& stagingPath() const noexcept { return stagingPath_; }
    const std::filesystem::path& destination() const noexcept { return destination_; }
    int lastWin32Error() const noexcept { return lastWin32Error_; }
    int lastErrno() const noexcept { return lastErrno_; }

private:
    void closeOwnedDescriptors() noexcept;

    std::filesystem::path destination_;
    AtomicOutputOptions options_;
    std::filesystem::path stagingPath_;
    std::FILE* file_ = nullptr;
    int fd_ = -1;
#ifdef _WIN32
    void* handle_ = reinterpret_cast<void*>(static_cast<intptr_t>(-1));
#endif
    bool createdByUs_ = false;
    bool committed_ = false;
    bool externalOwnerActive_ = false;
    int lastWin32Error_ = 0;
    int lastErrno_ = 0;
};

} // namespace sony2fuji
