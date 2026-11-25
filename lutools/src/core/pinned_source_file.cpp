#include "core/pinned_source_file.h"

#include "core/processing_cancellation.h"
#include "core/sha256.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <limits>
#include <system_error>

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
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace sony2fuji {
namespace {

std::atomic<uint64_t> gSourceHashPasses{0};

void setMessage(std::string* outMessage, const std::string& msg) {
    if (outMessage) *outMessage = msg;
}

bool decodeHexDigest(const std::string& hex, std::array<uint8_t, 32>& out) {
    if (hex.size() != 64) return false;
    auto nibble = [](char c, uint8_t& v) -> bool {
        if (c >= '0' && c <= '9') { v = static_cast<uint8_t>(c - '0'); return true; }
        if (c >= 'a' && c <= 'f') { v = static_cast<uint8_t>(c - 'a' + 10); return true; }
        if (c >= 'A' && c <= 'F') { v = static_cast<uint8_t>(c - 'A' + 10); return true; }
        return false;
    };
    for (size_t i = 0; i < 32; ++i) {
        uint8_t hi = 0, lo = 0;
        if (!nibble(hex[2 * i], hi) || !nibble(hex[2 * i + 1], lo)) return false;
        out[i] = static_cast<uint8_t>((hi << 4) | lo);
    }
    return true;
}

#ifndef _WIN32
void fireReadHook(const PinnedSourceOptions& options) {
    if (options.onReadChunkTestHook) {
        options.onReadChunkTestHook();
        return;
    }
    if (sourceReadTestHook) {
        auto hook = sourceReadTestHook;
        sourceReadTestHook = nullptr;
        hook();
    }
}
#endif

#ifndef _WIN32
ResourceFileStamp stampFromStat(const struct stat& info) {
#ifdef __APPLE__
    const auto modified = info.st_mtimespec, changed = info.st_ctimespec;
#else
    const auto modified = info.st_mtim, changed = info.st_ctim;
#endif
    return ResourceFileStamp{
        uint64_t(info.st_size),
        {uint64_t(modified.tv_sec), uint64_t(modified.tv_nsec)},
        {uint64_t(changed.tv_sec), uint64_t(changed.tv_nsec)},
        {uint64_t(info.st_dev), uint64_t(info.st_ino)},
    };
}
#endif

} // namespace

void (*sourceReadTestHook)() = nullptr;

uint64_t sourceHashPassCount() {
    return gSourceHashPasses.load(std::memory_order_relaxed);
}

void resetSourceHashPassCount() {
    gSourceHashPasses.store(0, std::memory_order_relaxed);
}

void recordSourceHashPass() {
    gSourceHashPasses.fetch_add(1, std::memory_order_relaxed);
}

bool PinnedSourceFile::isSymlinkOrReparse(const std::filesystem::path& path) {
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

bool PinnedSourceFile::isSameFile(const std::filesystem::path& a, const std::filesystem::path& b) {
    if (a.empty() || b.empty()) return false;
    std::error_code eqErr;
    if (std::filesystem::equivalent(a, b, eqErr) && !eqErr) return true;
    std::error_code caErr, cbErr;
    const auto ca = std::filesystem::weakly_canonical(a, caErr);
    const auto cb = std::filesystem::weakly_canonical(b, cbErr);
    if (!caErr && !cbErr && !ca.empty() && ca == cb) return true;
    return false;
}

SourcePinStatus PinnedSourceFile::pinAndRead(
    const std::filesystem::path& path,
    const PinnedSourceOptions& options,
    PinnedSourceFile& outPinned,
    std::vector<uint8_t>& outBytes,
    std::string* outMessage) {
    return pinAndStream(path, options, outPinned, &outBytes, outMessage);
}

SourcePinStatus PinnedSourceFile::pinAndHash(
    const std::filesystem::path& path,
    const PinnedSourceOptions& options,
    PinnedSourceFile& outPinned,
    std::string* outMessage) {
    return pinAndStream(path, options, outPinned, nullptr, outMessage);
}

SourcePinStatus PinnedSourceFile::pinAndStream(
    const std::filesystem::path& path,
    const PinnedSourceOptions& options,
    PinnedSourceFile& outPinned,
    std::vector<uint8_t>* outBytes,
    std::string* outMessage) {
    outPinned = PinnedSourceFile{};
    if (outBytes) outBytes->clear();
    setMessage(outMessage, "");

    if (path.empty()) {
        setMessage(outMessage, "Empty source path");
        return SourcePinStatus::InvalidPath;
    }
    if (options.rejectSymlink && isSymlinkOrReparse(path)) {
        setMessage(outMessage, "Source path cannot be a symbolic link");
        return SourcePinStatus::InvalidPath;
    }

    ResourceFileStamp beforeStamp{};
    uint64_t size = 0;
    const bool needHash = options.computeSha256 || options.expectedSha256 != nullptr;
    const bool streamHashInLoop = (outBytes == nullptr) && needHash;
    hash::Sha256 streamHasher;
    std::vector<uint8_t> chunkScratch;

#ifndef _WIN32
    const int openFlags = O_RDONLY | O_CLOEXEC | (options.rejectSymlink ? O_NOFOLLOW : 0);
    const int descriptor = ::open(path.c_str(), openFlags);
    if (descriptor < 0) {
        if (options.rejectSymlink && errno == ELOOP) {
            setMessage(outMessage, "Source path cannot be a symbolic link");
            return SourcePinStatus::InvalidPath;
        }
        setMessage(outMessage, "Source is not a readable regular file");
        return SourcePinStatus::IoError;
    }
    struct DescriptorGuard {
        int fd;
        ~DescriptorGuard() { if (fd >= 0) (void)::close(fd); }
    } guard{descriptor};

    struct stat beforeStat{};
    if (::fstat(descriptor, &beforeStat) != 0 || !S_ISREG(beforeStat.st_mode) || beforeStat.st_size < 0) {
        setMessage(outMessage, "Source is not a readable regular file");
        return SourcePinStatus::IoError;
    }
    beforeStamp = stampFromStat(beforeStat);
    size = beforeStamp.size;
    if (size > options.maxBytes || size > std::numeric_limits<size_t>::max()) {
        setMessage(outMessage, "Source exceeds maximum allowed byte budget");
        return SourcePinStatus::TooLarge;
    }
    if (size == 0 && !options.allowEmpty && !options.expectedSha256) {
        setMessage(outMessage, "Source file is empty");
        return SourcePinStatus::IoError;
    }
    if (outBytes) {
        if (options.beforeAlloc) {
            options.beforeAlloc(size);
        }
        outBytes->resize(static_cast<size_t>(size));
    } else if (size > 0) {
        chunkScratch.resize(static_cast<size_t>(std::min<uint64_t>(size, 1024ull * 1024ull)));
    }

    uint64_t filled = 0;
    bool firstChunk = true;
    while (true) {
        if (options.checkCancellation) {
            try {
                checkProcessingCancellation();
            } catch (const ProcessingCancelled&) {
                if (outBytes) outBytes->clear();
                setMessage(outMessage, "Processing cancelled");
                throw;
            }
        }
        ssize_t got = -1;
        errno = 0;
        if (filled < size) {
            if (outBytes) {
                const size_t remaining = static_cast<size_t>(size - filled);
                const size_t chunk = std::min<size_t>(4u * 1024u * 1024u, remaining);
                got = ::read(descriptor, outBytes->data() + filled, chunk);
            } else {
                const size_t remaining = static_cast<size_t>(std::min<uint64_t>(chunkScratch.size(), size - filled));
                got = ::read(descriptor, chunkScratch.data(), remaining);
            }
        } else {
            unsigned char probe = 0;
            got = ::read(descriptor, &probe, 1);
            if (got > 0) {
                if (outBytes) outBytes->clear();
                setMessage(outMessage, "Source changed during read");
                return SourcePinStatus::SourceChanged;
            }
            if (got == 0) break;
        }
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) {
            if (outBytes) outBytes->clear();
            setMessage(outMessage, "Failed reading source file");
            return SourcePinStatus::IoError;
        }
        if (got == 0) break;
        if (streamHashInLoop) {
            streamHasher.update(chunkScratch.data(), static_cast<size_t>(got));
        }
        filled += static_cast<uint64_t>(got);
        if (firstChunk) {
            firstChunk = false;
            fireReadHook(options);
        }
    }

    struct stat afterStat{};
    if (::fstat(descriptor, &afterStat) != 0 || filled != size ||
        !(beforeStamp == stampFromStat(afterStat))) {
        if (outBytes) outBytes->clear();
        setMessage(outMessage, "Source changed during read");
        return SourcePinStatus::SourceChanged;
    }
#else
    const DWORD openFlags = FILE_ATTRIBUTE_NORMAL |
        (options.rejectSymlink ? FILE_FLAG_OPEN_REPARSE_POINT : 0);
    const HANDLE handle = ::CreateFileW(
        path.c_str(),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        openFlags,
        nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        setMessage(outMessage, "Source is not a readable regular file");
        return SourcePinStatus::IoError;
    }
    struct HandleGuard {
        HANDLE h;
        void close() {
            if (h != INVALID_HANDLE_VALUE) {
                ::CloseHandle(h);
                h = INVALID_HANDLE_VALUE;
            }
        }
        ~HandleGuard() { close(); }
    } guard{handle};

    if (options.rejectSymlink) {
        BY_HANDLE_FILE_INFORMATION info{};
        if (!::GetFileInformationByHandle(handle, &info) ||
            (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            setMessage(outMessage, "Source path cannot be a symbolic link");
            return SourcePinStatus::InvalidPath;
        }
    }
    if (::GetFileType(handle) != FILE_TYPE_DISK) {
        setMessage(outMessage, "Source is not a regular disk file");
        return SourcePinStatus::IoError;
    }
    const auto maybeBefore = resourceFileStampFromHandle(handle);
    if (!maybeBefore) {
        setMessage(outMessage, "Source is not a readable regular file");
        return SourcePinStatus::IoError;
    }
    beforeStamp = *maybeBefore;
    size = beforeStamp.size;
    if (size > options.maxBytes || size > std::numeric_limits<size_t>::max()) {
        setMessage(outMessage, "Source exceeds maximum allowed byte budget");
        return SourcePinStatus::TooLarge;
    }
    if (size == 0 && !options.allowEmpty && !options.expectedSha256) {
        setMessage(outMessage, "Source file is empty");
        return SourcePinStatus::IoError;
    }
    if (outBytes) {
        if (options.beforeAlloc) {
            options.beforeAlloc(size);
        }
        outBytes->resize(static_cast<size_t>(size));
    } else if (size > 0) {
        chunkScratch.resize(static_cast<size_t>(std::min<uint64_t>(size, 1024ull * 1024ull)));
    }

    uint64_t filled = 0;
    bool firstChunk = true;
    while (true) {
        if (options.checkCancellation) {
            try {
                checkProcessingCancellation();
            } catch (const ProcessingCancelled&) {
                if (outBytes) outBytes->clear();
                setMessage(outMessage, "Processing cancelled");
                throw;
            }
        }
        if (filled < size) {
            DWORD got = 0;
            BOOL ok = FALSE;
            if (outBytes) {
                const DWORD chunk = static_cast<DWORD>((std::min<uint64_t>)(4u * 1024u * 1024u, size - filled));
                ok = ::ReadFile(handle, outBytes->data() + filled, chunk, &got, nullptr);
            } else {
                const DWORD chunk = static_cast<DWORD>((std::min<uint64_t>)(chunkScratch.size(), size - filled));
                ok = ::ReadFile(handle, chunkScratch.data(), chunk, &got, nullptr);
            }
            if (!ok) {
                if (outBytes) outBytes->clear();
                setMessage(outMessage, "Failed reading source file");
                return SourcePinStatus::IoError;
            }
            if (got == 0) break;
            if (streamHashInLoop) {
                streamHasher.update(chunkScratch.data(), static_cast<size_t>(got));
            }
            filled += static_cast<uint64_t>(got);
            if (firstChunk) {
                firstChunk = false;
                if (options.onReadChunkTestHook) {
                    options.onReadChunkTestHook();
                }
            }
        } else {
            unsigned char probe = 0;
            DWORD got = 0;
            if (!::ReadFile(handle, &probe, 1, &got, nullptr)) {
                if (outBytes) outBytes->clear();
                setMessage(outMessage, "Failed reading source file");
                return SourcePinStatus::IoError;
            }
            if (got > 0) {
                if (outBytes) outBytes->clear();
                setMessage(outMessage, "Source changed during read");
                return SourcePinStatus::SourceChanged;
            }
            break;
        }
    }

    const auto afterHandleStamp = resourceFileStampFromHandle(handle);
    if (!afterHandleStamp || filled != size || !(*afterHandleStamp == beforeStamp)) {
        if (outBytes) outBytes->clear();
        setMessage(outMessage, "Source changed during read");
        return SourcePinStatus::SourceChanged;
    }
    guard.close();
    if (sourceReadTestHook) {
        auto hook = sourceReadTestHook;
        sourceReadTestHook = nullptr;
        hook();
    }
#endif

    // Verify path identity still refers to the same pinned file (catches atomic rename swaps during read).
    if (options.rejectSymlink && isSymlinkOrReparse(path)) {
        if (outBytes) outBytes->clear();
        setMessage(outMessage, "Source changed to a symbolic link");
        return SourcePinStatus::SourceChanged;
    }
    const auto afterPathStamp = resourceFileStamp(path);
    if (!afterPathStamp || !(*afterPathStamp == beforeStamp)) {
        if (outBytes) outBytes->clear();
        setMessage(outMessage, "Source changed during read");
        return SourcePinStatus::SourceChanged;
    }

    std::array<uint8_t, 32> digest{};
    bool computedSha = false;
    if (needHash) {
        recordSourceHashPass();
        std::string hex;
        if (outBytes) {
            hash::Sha256 hasher;
            size_t offset = 0;
            while (offset < outBytes->size()) {
                if (options.checkCancellation) {
                    try {
                        checkProcessingCancellation();
                    } catch (const ProcessingCancelled&) {
                        outBytes->clear();
                        setMessage(outMessage, "Processing cancelled");
                        throw;
                    }
                }
                const size_t count = std::min<size_t>(outBytes->size() - offset, 1024u * 1024u);
                hasher.update(outBytes->data() + offset, count);
                offset += count;
            }
            hex = hasher.finish();
        } else {
            hex = streamHasher.finish();
        }
        if (!decodeHexDigest(hex, digest)) {
            if (outBytes) outBytes->clear();
            setMessage(outMessage, "Failed computing source SHA-256");
            return SourcePinStatus::IoError;
        }
        computedSha = true;
        if (options.expectedSha256 && std::memcmp(digest.data(), options.expectedSha256, 32) != 0) {
            if (outBytes) outBytes->clear();
            setMessage(outMessage, "Source SHA-256 mismatch");
            return SourcePinStatus::SourceChanged;
        }
    }

    if (size == 0 && !options.allowEmpty) {
        if (outBytes) outBytes->clear();
        setMessage(outMessage, "Source file is empty");
        return SourcePinStatus::IoError;
    }

    outPinned.path_ = path;
    outPinned.stamp_ = beforeStamp;
    outPinned.sha256_ = digest;
    outPinned.rejectSymlink_ = options.rejectSymlink;
    outPinned.hasSha256_ = computedSha;
    outPinned.valid_ = true;
    return SourcePinStatus::Ok;
}

SourcePinStatus PinnedSourceFile::pinIdentity(
    const std::filesystem::path& path,
    bool rejectSymlink,
    PinnedSourceFile& outPinned,
    std::string* outMessage) {
    outPinned = PinnedSourceFile{};
    setMessage(outMessage, "");
    if (path.empty()) {
        setMessage(outMessage, "Empty source path");
        return SourcePinStatus::InvalidPath;
    }
    if (rejectSymlink && isSymlinkOrReparse(path)) {
        setMessage(outMessage, "Source path cannot be a symbolic link");
        return SourcePinStatus::InvalidPath;
    }

#ifndef _WIN32
    const int openFlags = O_RDONLY | O_CLOEXEC | (rejectSymlink ? O_NOFOLLOW : 0);
    const int fd = ::open(path.c_str(), openFlags);
    if (fd < 0) {
        if (rejectSymlink && errno == ELOOP) {
            setMessage(outMessage, "Source path cannot be a symbolic link");
            return SourcePinStatus::InvalidPath;
        }
        setMessage(outMessage, "Cannot inspect source file");
        return SourcePinStatus::IoError;
    }
    struct stat st{};
    const bool ok = (::fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= 0);
    (void)::close(fd);
    if (!ok) {
        setMessage(outMessage, "Source is not a regular file");
        return SourcePinStatus::IoError;
    }
    outPinned.stamp_ = stampFromStat(st);
#else
    const DWORD openFlags = FILE_READ_ATTRIBUTES;
    const HANDLE handle = ::CreateFileW(
        path.c_str(),
        openFlags,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | (rejectSymlink ? FILE_FLAG_OPEN_REPARSE_POINT : 0),
        nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        setMessage(outMessage, "Cannot inspect source file");
        return SourcePinStatus::IoError;
    }
    if (rejectSymlink) {
        BY_HANDLE_FILE_INFORMATION info{};
        if (!::GetFileInformationByHandle(handle, &info) ||
            (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            ::CloseHandle(handle);
            setMessage(outMessage, "Source path cannot be a symbolic link");
            return SourcePinStatus::InvalidPath;
        }
    }
    const auto maybeStamp = resourceFileStampFromHandle(handle);
    ::CloseHandle(handle);
    if (!maybeStamp) {
        setMessage(outMessage, "Source is not a regular file");
        return SourcePinStatus::IoError;
    }
    outPinned.stamp_ = *maybeStamp;
#endif

    outPinned.path_ = path;
    outPinned.rejectSymlink_ = rejectSymlink;
    outPinned.hasSha256_ = false;
    outPinned.valid_ = true;
    return SourcePinStatus::Ok;
}

bool PinnedSourceFile::verifyUnchanged() const {
    if (!valid_ || path_.empty()) return false;
    if (rejectSymlink_ && isSymlinkOrReparse(path_)) return false;
    const auto current = resourceFileStamp(path_);
    return current.has_value() && (*current == stamp_);
}

} // namespace sony2fuji
