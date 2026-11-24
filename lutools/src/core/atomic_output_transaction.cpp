#include "core/atomic_output_transaction.h"

#include "core/output_file_mode.h"
#include "core/processing_cancellation.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <system_error>
#include <thread>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef NOGDI
#define NOGDI
#endif
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#ifdef RGB
#undef RGB
#endif
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace sony2fuji {
namespace {

void setError(std::string* outError, const std::string& msg) {
    if (outError) *outError = msg;
}

bool isSymlinkOrReparse(const std::filesystem::path& path) {
    std::error_code ec;
    const auto st = std::filesystem::symlink_status(path, ec);
    if (!ec && std::filesystem::is_symlink(st)) return true;
#ifdef _WIN32
    const DWORD attrs = ::GetFileAttributesW(path.c_str());
    if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        return true;
    }
#endif
    return false;
}

bool isDestinationDirectory(const std::filesystem::path& path) {
    std::error_code ec;
    const auto st = std::filesystem::symlink_status(path, ec);
    return !ec && std::filesystem::is_directory(st);
}

#ifdef _WIN32
bool isTransientWinError(DWORD err) {
    return err == ERROR_ACCESS_DENIED ||
           err == ERROR_SHARING_VIOLATION ||
           err == ERROR_LOCK_VIOLATION;
}
#endif

std::filesystem::path makeStagingCandidate(
    const std::filesystem::path& parent,
    const std::filesystem::path& destination,
    const AtomicOutputOptions& options,
    const std::string& suffix) {
    if (options.includeDestinationFilename) {
        std::filesystem::path name = destination.filename();
        if (name.empty()) name = std::filesystem::u8path("output");
        name += std::filesystem::u8path(options.stagingPrefix + "-" + suffix + options.stagingExtension);
        return parent / name;
    }
    return parent / std::filesystem::u8path(options.stagingPrefix + "-" + suffix + options.stagingExtension);
}

} // namespace

AtomicOutputTransaction::AtomicOutputTransaction(
    std::filesystem::path destination,
    AtomicOutputOptions options)
    : destination_(std::move(destination)),
      options_(std::move(options)) {}

AtomicOutputTransaction::~AtomicOutputTransaction() {
    rollback();
}

void AtomicOutputTransaction::closeOwnedDescriptors() noexcept {
    if (file_) {
        (void)std::fclose(file_);
        file_ = nullptr;
    }
#ifdef _WIN32
    const HANDLE h = static_cast<HANDLE>(handle_);
    if (h != INVALID_HANDLE_VALUE) {
        ::CloseHandle(h);
        handle_ = INVALID_HANDLE_VALUE;
    }
#else
    if (fd_ >= 0) {
        (void)::close(fd_);
        fd_ = -1;
    }
#endif
}

void AtomicOutputTransaction::rollback() noexcept {
    closeOwnedDescriptors();
    if (createdByUs_ && !committed_ && !stagingPath_.empty()) {
        std::error_code ec;
        std::filesystem::remove(stagingPath_, ec);
    }
    stagingPath_.clear();
    createdByUs_ = false;
    externalOwnerActive_ = false;
}

AtomicOutputStatus AtomicOutputTransaction::begin(std::string* outError) {
    setError(outError, "");
    lastErrno_ = 0;
    lastWin32Error_ = 0;

    if (createdByUs_ || committed_) {
        setError(outError, "Atomic output transaction already started");
        return AtomicOutputStatus::InvalidArgument;
    }

    if (destination_.empty() || !destination_.has_filename()) {
        setError(outError, "Destination path has no filename");
        return AtomicOutputStatus::InvalidArgument;
    }
    if (options_.rejectSymlinkTarget && isSymlinkOrReparse(destination_)) {
        setError(outError, "Destination cannot be a symbolic link");
        return AtomicOutputStatus::InvalidArgument;
    }
    if (isDestinationDirectory(destination_)) {
        setError(outError, "Destination path is a directory");
        return AtomicOutputStatus::IoError;
    }

    std::filesystem::path parent = destination_.parent_path();
    if (parent.empty()) {
        parent = std::filesystem::u8path(".");
    }
    if (options_.createParentDirs) {
        std::error_code ec;
        std::filesystem::create_directories(parent, ec);
        if (ec) {
            setError(outError, "Cannot create destination parent directory: " + ec.message());
            return AtomicOutputStatus::IoError;
        }
    }

    for (int attempt = 0; attempt < 64; ++attempt) {
        const std::string suffix = stagingSuffix();
        const std::filesystem::path candidate =
            makeStagingCandidate(parent, destination_, options_, suffix);
#ifdef _WIN32
        const DWORD access = GENERIC_WRITE | (options_.openReadWrite ? GENERIC_READ : 0);
        const DWORD attrs = options_.fileAttributeTemporary ? FILE_ATTRIBUTE_TEMPORARY : FILE_ATTRIBUTE_NORMAL;
        const HANDLE h = ::CreateFileW(
            candidate.c_str(),
            access,
            0,
            nullptr,
            CREATE_NEW,
            attrs,
            nullptr);
        if (h == INVALID_HANDLE_VALUE) {
            const DWORD err = ::GetLastError();
            if (err == ERROR_FILE_EXISTS) {
                continue; // Belongs to another writer; never delete or open it.
            }
            lastWin32Error_ = static_cast<int>(err);
            setError(outError, "Cannot create staging file: Win32 error " + std::to_string(err));
            return AtomicOutputStatus::IoError;
        }
        handle_ = h;
        stagingPath_ = candidate;
        createdByUs_ = true;
        return AtomicOutputStatus::Ok;
#else
        const int openFlags = O_CREAT | O_EXCL | O_CLOEXEC | (options_.openReadWrite ? O_RDWR : O_WRONLY);
        const mode_t mode = (options_.modePolicy == OutputModePolicy::Private0600)
            ? mode_t{0600}
            : (options_.modePolicy == OutputModePolicy::Standard0644 ? mode_t{0644} : mode_t{0666});
        const int fd = ::open(candidate.c_str(), openFlags, mode);
        if (fd < 0) {
            if (errno == EEXIST) {
                continue; // Belongs to another writer; never unlink or open it.
            }
            lastErrno_ = errno;
            setError(outError, "Cannot create staging file: " + std::string(std::strerror(lastErrno_)));
            return AtomicOutputStatus::IoError;
        }
        if (options_.modePolicy == OutputModePolicy::PreserveDestinationOrUmask) {
            preserveDestinationMode(fd, destination_);
        }
        fd_ = fd;
        stagingPath_ = candidate;
        createdByUs_ = true;
        return AtomicOutputStatus::Ok;
#endif
    }

    setError(outError, "Exhausted staging filename attempts");
    return AtomicOutputStatus::IoError;
}

AtomicOutputStatus AtomicOutputTransaction::writeAll(
    const void* data,
    size_t size,
    bool checkCancellation,
    std::string* outError) {
    setError(outError, "");
    if (!createdByUs_ || committed_ || externalOwnerActive_) {
        setError(outError, "Transaction is not open for direct writing");
        return AtomicOutputStatus::InvalidArgument;
    }
    if (size == 0) return AtomicOutputStatus::Ok;
    if (!data) {
        setError(outError, "Null write buffer");
        return AtomicOutputStatus::InvalidArgument;
    }

    const auto* ptr = static_cast<const uint8_t*>(data);
    size_t offset = 0;

    if (file_) {
        while (offset < size) {
            if (checkCancellation) checkProcessingCancellation();
            const size_t chunk = std::min<size_t>(size - offset, 1024u * 1024u);
            if (std::fwrite(ptr + offset, 1, chunk, file_) != chunk) {
                setError(outError, "Failed writing staging stdio stream");
                return AtomicOutputStatus::IoError;
            }
            offset += chunk;
        }
        return AtomicOutputStatus::Ok;
    }

#ifdef _WIN32
    const HANDLE h = static_cast<HANDLE>(handle_);
    if (h == INVALID_HANDLE_VALUE) {
        setError(outError, "Staging handle is not open");
        return AtomicOutputStatus::InvalidArgument;
    }
    while (offset < size) {
        if (checkCancellation) checkProcessingCancellation();
        const DWORD chunk = static_cast<DWORD>((std::min<size_t>)(size - offset, 1024u * 1024u));
        DWORD written = 0;
        if (!::WriteFile(h, ptr + offset, chunk, &written, nullptr) || written == 0) {
            lastWin32Error_ = static_cast<int>(::GetLastError());
            setError(outError, "Failed writing staging file: Win32 error " + std::to_string(lastWin32Error_));
            return AtomicOutputStatus::IoError;
        }
        offset += static_cast<size_t>(written);
    }
    return AtomicOutputStatus::Ok;
#else
    if (fd_ < 0) {
        setError(outError, "Staging descriptor is not open");
        return AtomicOutputStatus::InvalidArgument;
    }
    while (offset < size) {
        if (checkCancellation) checkProcessingCancellation();
        const size_t chunk = std::min<size_t>(size - offset, 1024u * 1024u);
        const ssize_t written = ::write(fd_, ptr + offset, chunk);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            lastErrno_ = (written < 0) ? errno : EIO;
            setError(outError, "Failed writing staging file: " + std::string(std::strerror(lastErrno_)));
            return AtomicOutputStatus::IoError;
        }
        offset += static_cast<size_t>(written);
    }
    return AtomicOutputStatus::Ok;
#endif
}

std::FILE* AtomicOutputTransaction::openStdioWrite() {
    if (!createdByUs_ || committed_ || externalOwnerActive_) return nullptr;
    if (file_) return file_;
#ifdef _WIN32
    const HANDLE h = static_cast<HANDLE>(handle_);
    if (h == INVALID_HANDLE_VALUE) return nullptr;
    const int crtFd = ::_open_osfhandle(
        reinterpret_cast<intptr_t>(h),
        _O_WRONLY | _O_BINARY | _O_NOINHERIT);
    if (crtFd < 0) {
        lastErrno_ = errno;
        return nullptr;
    }
    handle_ = INVALID_HANDLE_VALUE; // CRT descriptor now owns the Win32 HANDLE.
    std::FILE* f = ::_fdopen(crtFd, "wb");
    if (!f) {
        lastErrno_ = errno;
        (void)::_close(crtFd);
        rollback();
        return nullptr;
    }
    file_ = f;
    return file_;
#else
    if (fd_ < 0) return nullptr;
    std::FILE* f = ::fdopen(fd_, "wb");
    if (!f) {
        lastErrno_ = errno;
        return nullptr;
    }
    fd_ = -1; // FILE* now owns the POSIX file descriptor.
    file_ = f;
    return file_;
#endif
}

int AtomicOutputTransaction::releasePosixFdForExternalOwner() {
#ifdef _WIN32
    return -1;
#else
    if (!createdByUs_ || committed_ || fd_ < 0 || file_) return -1;
    const int released = fd_;
    fd_ = -1;
    externalOwnerActive_ = true;
    return released;
#endif
}

#ifdef _WIN32
void* AtomicOutputTransaction::releaseWin32HandleForExternalOwner() {
    const HANDLE h = static_cast<HANDLE>(handle_);
    if (!createdByUs_ || committed_ || h == INVALID_HANDLE_VALUE || file_) {
        return INVALID_HANDLE_VALUE;
    }
    handle_ = INVALID_HANDLE_VALUE;
    externalOwnerActive_ = true;
    return h;
}
#endif

void AtomicOutputTransaction::markExternalOwnerClosed() {
    externalOwnerActive_ = false;
}

AtomicOutputStatus AtomicOutputTransaction::commit(
    const std::function<bool()>& preCommitCheck,
    std::string* outError) {
    setError(outError, "");
    if (!createdByUs_ || committed_ || stagingPath_.empty() || externalOwnerActive_) {
        setError(outError, "Transaction is not ready to commit");
        return AtomicOutputStatus::InvalidArgument;
    }

    if (file_) {
        bool flushed = (std::fflush(file_) == 0) && (std::ferror(file_) == 0);
        if (flushed && options_.syncFile) {
#ifdef _WIN32
            const int crtFd = ::_fileno(file_);
            const HANDLE h = crtFd >= 0
                ? reinterpret_cast<HANDLE>(::_get_osfhandle(crtFd))
                : INVALID_HANDLE_VALUE;
            if (h == INVALID_HANDLE_VALUE || !::FlushFileBuffers(h)) {
                lastWin32Error_ = static_cast<int>(::GetLastError());
                flushed = false;
            }
#else
            const int sfd = ::fileno(file_);
            while (sfd >= 0 && ::fsync(sfd) < 0) {
                if (errno == EINTR) continue;
                lastErrno_ = errno;
                flushed = false;
                break;
            }
#endif
        }
        const bool closed = (std::fclose(file_) == 0);
        file_ = nullptr;
        if (!flushed || !closed) {
            if (!closed && lastErrno_ == 0) lastErrno_ = errno;
            setError(outError, "Failed flushing staging stream");
            rollback();
            return AtomicOutputStatus::IoError;
        }
    } else {
#ifdef _WIN32
        const HANDLE h = static_cast<HANDLE>(handle_);
        if (h != INVALID_HANDLE_VALUE) {
            if (options_.syncFile && !::FlushFileBuffers(h)) {
                lastWin32Error_ = static_cast<int>(::GetLastError());
                setError(outError, "Failed flushing staging file: Win32 error " + std::to_string(lastWin32Error_));
                rollback();
                return AtomicOutputStatus::IoError;
            }
            ::CloseHandle(h);
            handle_ = INVALID_HANDLE_VALUE;
        }
#else
        if (fd_ >= 0) {
            if (options_.syncFile) {
                while (::fsync(fd_) < 0) {
                    if (errno == EINTR) continue;
                    lastErrno_ = errno;
                    setError(outError, "Failed syncing staging file: " + std::string(std::strerror(lastErrno_)));
                    rollback();
                    return AtomicOutputStatus::IoError;
                }
            }
            const int closeRes = ::close(fd_);
            fd_ = -1;
            if (closeRes != 0) {
                lastErrno_ = errno;
                setError(outError, "Failed closing staging file: " + std::string(std::strerror(lastErrno_)));
                rollback();
                return AtomicOutputStatus::IoError;
            }
        }
#endif
    }

    if (preCommitCheck) {
        bool ok = false;
        try {
            ok = preCommitCheck();
        } catch (...) {
            rollback();
            throw;
        }
        if (!ok) {
            setError(outError, "Pre-commit verification rejected output");
            rollback();
            return AtomicOutputStatus::PreCommitRejected;
        }
    }

    if (options_.rejectSymlinkTarget && isSymlinkOrReparse(destination_)) {
        setError(outError, "Destination cannot be a symbolic link");
        rollback();
        return AtomicOutputStatus::InvalidArgument;
    }

#ifdef _WIN32
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (true) {
        if (::MoveFileExW(
                stagingPath_.c_str(),
                destination_.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            committed_ = true;
            stagingPath_.clear();
            return AtomicOutputStatus::Ok;
        }
        const DWORD err = ::GetLastError();
        if (options_.winRetryOnTransient &&
            isTransientWinError(err) &&
            std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }
        lastWin32Error_ = static_cast<int>(err);
        setError(outError, "Failed publishing staging file: Win32 error " + std::to_string(err));
        rollback();
        return AtomicOutputStatus::IoError;
    }
#else
    if (::rename(stagingPath_.c_str(), destination_.c_str()) != 0) {
        lastErrno_ = errno;
        setError(outError, "Failed publishing staging file: " + std::string(std::strerror(lastErrno_)));
        rollback();
        return AtomicOutputStatus::IoError;
    }
    committed_ = true;
    stagingPath_.clear();
    if (options_.syncParentDir) {
        const std::filesystem::path parent = destination_.parent_path();
        const int dfd = ::open(parent.empty() ? "." : parent.c_str(), O_RDONLY | O_CLOEXEC);
        if (dfd >= 0) {
            (void)::fsync(dfd);
            (void)::close(dfd);
        }
    }
    return AtomicOutputStatus::Ok;
#endif
}

} // namespace sony2fuji
