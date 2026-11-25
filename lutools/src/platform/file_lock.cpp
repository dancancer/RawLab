#include "platform/file_lock.h"
#include "core/atomic_output_transaction.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#include <winnls.h>
#else
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#elif !defined(_WIN32) && (!defined(__ANDROID__) || (defined(__ANDROID_API__) && __ANDROID_API__ >= 28))
#include <sys/random.h>
#endif

namespace sony2fuji {
namespace platform {
namespace {

#if !defined(_WIN32)
constexpr int64_t kSwiftReferenceEpochOffset = 978307200LL; // 2001-01-01T00:00:00Z
#else
constexpr int64_t kDotNetFileTimeOffset = 504911232000000000LL; // 1601-01-01 vs 0001-01-01 in 100ns ticks
#endif

bool isPresetWhitespace(uint32_t cp) {
    if ((cp >= 0x0009 && cp <= 0x000D) || cp == 0x0020 || cp == 0x0085 || cp == 0x00A0 ||
        cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200B) || cp == 0x2028 || cp == 0x2029 ||
        cp == 0x202F || cp == 0x205F || cp == 0x3000) {
        return true;
    }
    return false;
}

std::vector<uint32_t> decodeUtf8Codepoints(const std::string& input) {
    std::vector<uint32_t> out;
    out.reserve(input.size());
    const auto* bytes = reinterpret_cast<const unsigned char*>(input.data());
    const size_t n = input.size();
    size_t i = 0;
    while (i < n) {
        const unsigned char b0 = bytes[i];
        uint32_t cp = 0;
        size_t len = 0;
        if (b0 < 0x80) {
            cp = b0;
            len = 1;
        } else if ((b0 & 0xE0) == 0xC0) {
            if (i + 1 >= n) throw StoreError(2, "invalid_argument", "Invalid UTF-8 sequence");
            const unsigned char b1 = bytes[i + 1];
            if ((b1 & 0xC0) != 0x80) throw StoreError(2, "invalid_argument", "Invalid UTF-8 sequence");
            cp = ((uint32_t)(b0 & 0x1F) << 6) | (uint32_t)(b1 & 0x3F);
            if (cp < 0x80) throw StoreError(2, "invalid_argument", "Overlong UTF-8 sequence");
            len = 2;
        } else if ((b0 & 0xF0) == 0xE0) {
            if (i + 2 >= n) throw StoreError(2, "invalid_argument", "Invalid UTF-8 sequence");
            const unsigned char b1 = bytes[i + 1];
            const unsigned char b2 = bytes[i + 2];
            if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80)
                throw StoreError(2, "invalid_argument", "Invalid UTF-8 sequence");
            cp = ((uint32_t)(b0 & 0x0F) << 12) | ((uint32_t)(b1 & 0x3F) << 6) | (uint32_t)(b2 & 0x3F);
            if (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))
                throw StoreError(2, "invalid_argument", "Invalid UTF-8 codepoint");
            len = 3;
        } else if ((b0 & 0xF8) == 0xF0) {
            if (i + 3 >= n) throw StoreError(2, "invalid_argument", "Invalid UTF-8 sequence");
            const unsigned char b1 = bytes[i + 1];
            const unsigned char b2 = bytes[i + 2];
            const unsigned char b3 = bytes[i + 3];
            if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80)
                throw StoreError(2, "invalid_argument", "Invalid UTF-8 sequence");
            cp = ((uint32_t)(b0 & 0x07) << 18) | ((uint32_t)(b1 & 0x3F) << 12) |
                 ((uint32_t)(b2 & 0x3F) << 6) | (uint32_t)(b3 & 0x3F);
            if (cp < 0x10000 || cp > 0x10FFFF)
                throw StoreError(2, "invalid_argument", "Invalid UTF-8 codepoint");
            len = 4;
        } else {
            throw StoreError(2, "invalid_argument", "Invalid UTF-8 byte");
        }
        if (cp == 0) throw StoreError(2, "invalid_argument", "String cannot contain NUL bytes");
        out.push_back(cp);
        i += len;
    }
    return out;
}

std::string encodeUtf8Codepoints(const std::vector<uint32_t>& cps) {
    std::string out;
    out.reserve(cps.size());
    for (uint32_t cp : cps) {
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
    return out;
}

bool isSymlinkOrReparse(const std::filesystem::path& p) {
    std::error_code ec;
    const auto st = std::filesystem::symlink_status(p, ec);
    if (!ec && std::filesystem::is_symlink(st)) return true;
#if defined(_WIN32)
    const DWORD attrs = GetFileAttributesW(p.c_str());
    if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        return true;
    }
#endif
    return false;
}

bool pathsMatchControlled(const std::filesystem::path& a, const std::filesystem::path& b) {
    std::error_code ec;
    if (std::filesystem::exists(a, ec) && std::filesystem::exists(b, ec)) {
        if (std::filesystem::equivalent(a, b, ec) && !ec) return true;
    }
    const std::string sa = pathToUtf8(a.lexically_normal());
    const std::string sb = pathToUtf8(b.lexically_normal());
#if defined(_WIN32)
    if (sa.size() != sb.size()) return false;
    for (size_t i = 0; i < sa.size(); ++i) {
        const unsigned char ca = static_cast<unsigned char>(sa[i]);
        const unsigned char cb = static_cast<unsigned char>(sb[i]);
        if (std::tolower(ca) != std::tolower(cb)) return false;
    }
    return true;
#else
    return sa == sb;
#endif
}

#if defined(_WIN32)
std::string hex32(uint32_t v) {
    char buf[9];
    std::snprintf(buf, sizeof(buf), "%08x", static_cast<unsigned int>(v));
    return std::string(buf);
}

std::wstring utf8ToWide(const std::string& utf8) {
    if (utf8.empty()) return L"";
    const int needed = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    if (needed <= 0) throw StoreError(2, "invalid_argument", "Invalid UTF-8 string");
    std::wstring wide(static_cast<size_t>(needed), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()), wide.data(), needed) <= 0) {
        throw StoreError(2, "invalid_argument", "Invalid UTF-8 string");
    }
    return wide;
}

std::string wideToUtf8(const std::wstring& wide) {
    if (wide.empty()) return "";
    const int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    if (needed <= 0) throw StoreError(2, "invalid_argument", "Invalid UTF-16 string");
    std::string utf8(static_cast<size_t>(needed), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), static_cast<int>(wide.size()), utf8.data(), needed, nullptr, nullptr) <= 0) {
        throw StoreError(2, "invalid_argument", "Invalid UTF-16 string");
    }
    return utf8;
}

bool isTransientWinError(DWORD err) {
    return err == ERROR_ACCESS_DENIED || err == ERROR_SHARING_VIOLATION || err == ERROR_LOCK_VIOLATION;
}
#endif

} // namespace

std::filesystem::path pathFromUtf8(const std::string& utf8) {
#if defined(_WIN32)
    return std::filesystem::path(utf8ToWide(utf8));
#else
    return std::filesystem::u8path(utf8);
#endif
}

std::string pathToUtf8(const std::filesystem::path& path) {
#if defined(_WIN32)
    return wideToUtf8(path.wstring());
#else
    return path.u8string();
#endif
}

struct ScopedFileLock::Impl {
#if defined(_WIN32)
    HANDLE handle = INVALID_HANDLE_VALUE;
#else
    int fd = -1;
#endif
    ~Impl() {
#if defined(_WIN32)
        if (handle != INVALID_HANDLE_VALUE) {
            CloseHandle(handle);
            handle = INVALID_HANDLE_VALUE;
        }
#else
        if (fd >= 0) {
            flock(fd, LOCK_UN);
            close(fd);
            fd = -1;
        }
#endif
    }
};

ScopedFileLock::ScopedFileLock(const std::filesystem::path& lockPath) : impl_(std::make_unique<Impl>()) {
    std::error_code ec;
    const auto parent = lockPath.parent_path();
    if (!parent.empty()) {
        std::filesystem::create_directories(parent, ec);
        if (ec) {
            throw StoreError(6, "output_io_error", "Cannot create store directory: " + ec.message());
        }
    }
    if (isSymlinkOrReparse(lockPath)) {
        throw StoreError(2, "invalid_argument", "Lock file cannot be a symbolic link");
    }

#if defined(_WIN32)
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (true) {
        HANDLE h = CreateFileW(
            lockPath.c_str(),
            GENERIC_READ | GENERIC_WRITE,
            0, // exclusive lock
            nullptr,
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
            nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            BY_HANDLE_FILE_INFORMATION info{};
            if (GetFileInformationByHandle(h, &info) && (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                CloseHandle(h);
                throw StoreError(2, "invalid_argument", "Lock file cannot be a symbolic link");
            }
            impl_->handle = h;
            return;
        }
        const DWORD err = GetLastError();
        if (isTransientWinError(err) && std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }
        throw StoreError(6, "output_io_error", "Failed to acquire lock file: Win32 error " + std::to_string(err));
    }
#else
    const int fd = open(lockPath.c_str(), O_CREAT | O_RDWR | O_NOFOLLOW, 0644);
    if (fd < 0) {
        if (errno == ELOOP) {
            throw StoreError(2, "invalid_argument", "Lock file cannot be a symbolic link");
        }
        throw StoreError(6, "output_io_error", "Failed to open lock file: " + std::string(std::strerror(errno)));
    }
    while (flock(fd, LOCK_EX) < 0) {
        if (errno == EINTR) continue;
        const int savedErr = errno;
        close(fd);
        throw StoreError(6, "output_io_error", "Failed to lock file: " + std::string(std::strerror(savedErr)));
    }
    impl_->fd = fd;
#endif
}

ScopedFileLock::~ScopedFileLock() = default;
ScopedFileLock::ScopedFileLock(ScopedFileLock&&) noexcept = default;
ScopedFileLock& ScopedFileLock::operator=(ScopedFileLock&&) noexcept = default;

std::filesystem::path resolveControlledSubpath(
    const std::filesystem::path& dataDir,
    const std::string& subdir,
    const std::string& filename) {
    auto validSegment = [](const std::string& s) {
        if (s.empty() || s == "." || s == "..") return false;
        for (char c : s) {
            if (c == '/' || c == '\\' || c == '\0') return false;
        }
        return true;
    };
    if (!validSegment(subdir)) {
        throw StoreError(2, "invalid_argument", "Invalid controlled subdirectory");
    }
    if (!validSegment(filename)) {
        throw StoreError(2, "invalid_argument", "Invalid controlled filename");
    }
    if (dataDir.empty()) {
        throw StoreError(2, "invalid_argument", "Controlled data_dir cannot be empty");
    }

    std::error_code ec;
    const auto absRoot = std::filesystem::absolute(dataDir, ec);
    if (ec) {
        throw StoreError(2, "invalid_argument", "Invalid data_dir path: " + ec.message());
    }
    const auto canonicalRoot = std::filesystem::weakly_canonical(absRoot, ec);
    if (ec) {
        throw StoreError(2, "invalid_argument", "Cannot resolve data_dir: " + ec.message());
    }
    const auto rootStatus = std::filesystem::status(canonicalRoot, ec);
    if (!ec && std::filesystem::exists(rootStatus) && !std::filesystem::is_directory(rootStatus)) {
        throw StoreError(2, "invalid_argument", "Controlled data_dir must be a directory");
    }

    const auto targetDir = canonicalRoot / pathFromUtf8(subdir);
    const auto dirLexStatus = std::filesystem::symlink_status(targetDir, ec);
    if (!ec && std::filesystem::exists(dirLexStatus)) {
        if (isSymlinkOrReparse(targetDir)) {
            throw StoreError(2, "invalid_argument", "Controlled directory '" + subdir + "' cannot be a symbolic link");
        }
        if (!std::filesystem::is_directory(dirLexStatus)) {
            throw StoreError(2, "invalid_argument", "Controlled directory '" + subdir + "' is not a directory");
        }
        const auto resolvedDir = std::filesystem::weakly_canonical(targetDir, ec);
        if (ec || !pathsMatchControlled(resolvedDir, targetDir)) {
            throw StoreError(2, "invalid_argument", "Controlled directory '" + subdir + "' escaped data_dir");
        }
    }

    const auto targetFile = targetDir / pathFromUtf8(filename);
    const auto fileLexStatus = std::filesystem::symlink_status(targetFile, ec);
    if (!ec && std::filesystem::exists(fileLexStatus)) {
        if (isSymlinkOrReparse(targetFile)) {
            throw StoreError(2, "invalid_argument", "Controlled store '" + filename + "' cannot be a symbolic link");
        }
        if (!std::filesystem::is_regular_file(fileLexStatus)) {
            throw StoreError(2, "invalid_argument", "Controlled store '" + filename + "' is not a regular file");
        }
        const auto resolvedFile = std::filesystem::weakly_canonical(targetFile, ec);
        if (ec || !pathsMatchControlled(resolvedFile, targetFile)) {
            throw StoreError(2, "invalid_argument", "Controlled store '" + filename + "' escaped data_dir");
        }
    }

    return targetFile;
}

std::string readFileBytes(const std::filesystem::path& path, int errorStatus, const std::string& errorCode) {
    if (isSymlinkOrReparse(path)) {
        // Note: input request/photo paths might be symlinks, only controlled paths forbid symlinks via resolveControlledSubpath.
    }
    std::error_code ec;
    const auto st = std::filesystem::status(path, ec);
    if (ec || !std::filesystem::exists(st)) {
        throw StoreError(errorStatus, errorCode, "File does not exist: " + pathToUtf8(path));
    }
    if (!std::filesystem::is_regular_file(st)) {
        throw StoreError(errorStatus, errorCode, "Path is not a regular file: " + pathToUtf8(path));
    }

#if defined(_WIN32)
    HANDLE h = CreateFileW(
        path.c_str(),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        throw StoreError(errorStatus, errorCode, "Cannot open file for reading: " + pathToUtf8(path));
    }
    LARGE_INTEGER fileSize{};
    if (!GetFileSizeEx(h, &fileSize) || fileSize.QuadPart < 0) {
        CloseHandle(h);
        throw StoreError(errorStatus, errorCode, "Cannot determine file size: " + pathToUtf8(path));
    }
    std::string data;
    data.resize(static_cast<size_t>(fileSize.QuadPart));
    size_t offset = 0;
    while (offset < data.size()) {
        const DWORD chunk = static_cast<DWORD>(std::min<size_t>(data.size() - offset, 1u << 24));
        DWORD readBytes = 0;
        if (!ReadFile(h, data.data() + offset, chunk, &readBytes, nullptr)) {
            CloseHandle(h);
            throw StoreError(errorStatus, errorCode, "Failed reading file: " + pathToUtf8(path));
        }
        if (readBytes == 0) break;
        offset += readBytes;
    }
    data.resize(offset);
    CloseHandle(h);
    return data;
#else
    const int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        throw StoreError(errorStatus, errorCode, "Cannot open file for reading: " + pathToUtf8(path));
    }
    struct stat stBuf {};
    if (fstat(fd, &stBuf) != 0) {
        close(fd);
        throw StoreError(errorStatus, errorCode, "Cannot stat file: " + pathToUtf8(path));
    }
    std::string data;
    if (stBuf.st_size > 0) data.reserve(static_cast<size_t>(stBuf.st_size));
    char buf[65536];
    while (true) {
        const ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            data.append(buf, static_cast<size_t>(n));
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            const int saved = errno;
            close(fd);
            throw StoreError(errorStatus, errorCode, "Failed reading file: " + std::string(std::strerror(saved)));
        }
    }
    close(fd);
    return data;
#endif
}

void atomicWriteBytes(const std::filesystem::path& targetPath, const std::string& bytes) {
    AtomicOutputOptions options;
    options.stagingPrefix = ".rawlab-store";
    options.stagingExtension = ".tmp";
    options.includeDestinationFilename = true;
    options.modePolicy = OutputModePolicy::Standard0644;
    options.rejectSymlinkTarget = true;
    options.createParentDirs = true;
    options.syncFile = true;
    options.syncParentDir = true;
    options.winRetryOnTransient = true;

    AtomicOutputTransaction tx(targetPath, options);
    std::string errMsg;
    auto mapFailure = [&](AtomicOutputStatus st) -> void {
        if (st == AtomicOutputStatus::InvalidArgument) {
            throw StoreError(2, "invalid_argument",
                errMsg.empty() ? "Controlled store cannot be a symbolic link" : errMsg);
        }
        throw StoreError(6, "output_io_error",
            errMsg.empty() ? "Failed atomic store write" : errMsg);
    };

    const AtomicOutputStatus beginStatus = tx.begin(&errMsg);
    if (beginStatus != AtomicOutputStatus::Ok) {
        mapFailure(beginStatus);
    }
    const AtomicOutputStatus writeStatus = tx.writeAll(bytes.data(), bytes.size(), false, &errMsg);
    if (writeStatus != AtomicOutputStatus::Ok) {
        mapFailure(writeStatus);
    }
    const AtomicOutputStatus commitStatus = tx.commit({}, &errMsg);
    if (commitStatus != AtomicOutputStatus::Ok) {
        mapFailure(commitStatus);
    }
}

MacFileIdentity readMacFileIdentity(const std::filesystem::path& photoPath) {
#if defined(_WIN32)
    (void)photoPath;
    throw StoreError(4, "unsupported", "macOS file identity is unavailable on Windows");
#else
    char resolvedBuf[PATH_MAX];
    const std::string raw = pathToUtf8(photoPath);
    if (realpath(raw.c_str(), resolvedBuf) == nullptr) {
        throw StoreError(3, "io_error", "Photo does not exist: " + raw);
    }
    std::string real(resolvedBuf);
#if defined(__APPLE__)
    for (const char* prefix : {"/private/tmp", "/private/var", "/private/etc"}) {
        const size_t plen = std::strlen(prefix);
        if (real == prefix || (real.size() > plen && real.compare(0, plen, prefix) == 0 && real[plen] == '/')) {
            real.erase(0, std::strlen("/private"));
            break;
        }
    }
#endif
    struct stat st {};
    if (stat(real.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
        throw StoreError(3, "io_error", "Photo does not exist: " + raw);
    }
#if defined(__APPLE__)
    const int64_t sec = static_cast<int64_t>(st.st_mtimespec.tv_sec);
    const int64_t nsec = static_cast<int64_t>(st.st_mtimespec.tv_nsec);
#else
    const int64_t sec = static_cast<int64_t>(st.st_mtim.tv_sec);
    const int64_t nsec = static_cast<int64_t>(st.st_mtim.tv_nsec);
#endif
    const double modifiedCf = static_cast<double>(sec - kSwiftReferenceEpochOffset) +
                              (static_cast<double>(nsec) / 1e9);
    return MacFileIdentity{
        static_cast<uint64_t>(st.st_ino),
        modifiedCf,
        real,
        static_cast<uint64_t>(st.st_size),
    };
#endif
}

WindowsFileIdentity readWindowsFileIdentity(const std::filesystem::path& photoPath) {
#if !defined(_WIN32)
    (void)photoPath;
    throw StoreError(4, "unsupported", "Windows file identity is unavailable on POSIX");
#else
    const DWORD needed = GetFullPathNameW(photoPath.c_str(), 0, nullptr, nullptr);
    if (needed == 0) {
        throw StoreError(3, "io_error", "Photo path is invalid: " + pathToUtf8(photoPath));
    }
    std::wstring full(needed, L'\0');
    const DWORD written = GetFullPathNameW(photoPath.c_str(), needed, full.data(), nullptr);
    if (written == 0 || written >= needed) {
        throw StoreError(3, "io_error", "Photo path could not be resolved: " + pathToUtf8(photoPath));
    }
    full.resize(written);

    HANDLE h = CreateFileW(
        full.c_str(),
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        throw StoreError(3, "io_error", "Photo does not exist: " + pathToUtf8(photoPath));
    }
    BY_HANDLE_FILE_INFORMATION info{};
    const BOOL ok = GetFileInformationByHandle(h, &info);
    CloseHandle(h);
    if (!ok || (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        throw StoreError(3, "io_error", "Photo is not a regular file: " + pathToUtf8(photoPath));
    }
    const uint64_t length = (static_cast<uint64_t>(info.nFileSizeHigh) << 32) |
                            static_cast<uint64_t>(info.nFileSizeLow);
    const int64_t modifiedFt = (static_cast<int64_t>(info.ftLastWriteTime.dwHighDateTime) << 32) |
                               static_cast<int64_t>(info.ftLastWriteTime.dwLowDateTime);
    const int64_t createdFt = (static_cast<int64_t>(info.ftCreationTime.dwHighDateTime) << 32) |
                              static_cast<int64_t>(info.ftCreationTime.dwLowDateTime);
    const std::string fileId = hex32(info.dwVolumeSerialNumber) + "-" +
                               hex32(info.nFileIndexHigh) + "-" +
                               hex32(info.nFileIndexLow);
    return WindowsFileIdentity{
        wideToUtf8(full),
        length,
        modifiedFt + kDotNetFileTimeOffset,
        createdFt + kDotNetFileTimeOffset,
        fileId,
    };
#endif
}

std::string normalizePresetNameUtf8(const std::string& rawName) {
    auto cps = decodeUtf8Codepoints(rawName);
    size_t start = 0;
    while (start < cps.size() && isPresetWhitespace(cps[start])) {
        ++start;
    }
    size_t end = cps.size();
    while (end > start && isPresetWhitespace(cps[end - 1])) {
        --end;
    }
    if (start == end) return "";
    cps.assign(cps.begin() + static_cast<std::ptrdiff_t>(start),
               cps.begin() + static_cast<std::ptrdiff_t>(end));
    const std::string trimmed = encodeUtf8Codepoints(cps);

#if defined(__APPLE__)
    CFStringRef cf = CFStringCreateWithBytes(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(trimmed.data()),
        static_cast<CFIndex>(trimmed.size()),
        kCFStringEncodingUTF8,
        false);
    if (cf == nullptr) {
        throw StoreError(2, "invalid_argument", "Preset name contains invalid UTF-8");
    }
    CFMutableStringRef mut = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, cf);
    CFRelease(cf);
    if (mut == nullptr) {
        throw StoreError(5, "out_of_memory", "Out of memory normalizing preset name");
    }
    CFStringNormalize(mut, kCFStringNormalizationFormC);
    const CFIndex len = CFStringGetLength(mut);
    const CFIndex maxSize = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
    std::string normalized(static_cast<size_t>(maxSize), '\0');
    const Boolean converted = CFStringGetCString(mut, normalized.data(), maxSize, kCFStringEncodingUTF8);
    CFRelease(mut);
    if (!converted) {
        throw StoreError(2, "invalid_argument", "Preset name could not be normalized");
    }
    normalized.resize(std::strlen(normalized.c_str()));
    return normalized;
#elif defined(_WIN32)
    const std::wstring wide = utf8ToWide(trimmed);
    int cap = NormalizeString(NormalizationC, wide.data(), static_cast<int>(wide.size()), nullptr, 0);
    if (cap <= 0) {
        throw StoreError(2, "invalid_argument", "Preset name could not be normalized");
    }
    std::wstring normWide(static_cast<size_t>(cap), L'\0');
    const int actual = NormalizeString(NormalizationC, wide.data(), static_cast<int>(wide.size()), normWide.data(), cap);
    if (actual <= 0) {
        throw StoreError(2, "invalid_argument", "Preset name could not be normalized");
    }
    normWide.resize(static_cast<size_t>(actual));
    return wideToUtf8(normWide);
#else
    return trimmed;
#endif
}

std::string generateUuidV4Lowercase() {
    uint8_t b[16]{};
#if defined(_WIN32)
    if (BCryptGenRandom(nullptr, b, sizeof(b), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
        throw StoreError(6, "output_io_error", "Failed to generate UUID");
    }
#elif defined(__APPLE__)
    arc4random_buf(b, sizeof(b));
#else
    size_t got = 0;
#if !defined(__ANDROID__) || (defined(__ANDROID_API__) && __ANDROID_API__ >= 28)
    while (got < sizeof(b)) {
        const ssize_t n = getrandom(b + got, sizeof(b) - got, 0);
        if (n > 0) got += static_cast<size_t>(n);
        else if (n < 0 && errno == EINTR) continue;
        else break;
    }
#endif
    if (got < sizeof(b)) {
        const int fd = open("/dev/urandom", O_RDONLY);
        if (fd < 0) throw StoreError(6, "output_io_error", "Failed to generate UUID");
        while (got < sizeof(b)) {
            const ssize_t n = read(fd, b + got, sizeof(b) - got);
            if (n > 0) got += static_cast<size_t>(n);
            else if (n < 0 && errno == EINTR) continue;
            else {
                close(fd);
                throw StoreError(6, "output_io_error", "Failed to generate UUID");
            }
        }
        close(fd);
    }
#endif
    b[6] = static_cast<uint8_t>((b[6] & 0x0F) | 0x40);
    b[8] = static_cast<uint8_t>((b[8] & 0x3F) | 0x80);
    char out[37];
    std::snprintf(
        out,
        sizeof(out),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
    return std::string(out);
}

int64_t currentUnixMillis() {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
}

} // namespace platform
} // namespace sony2fuji
