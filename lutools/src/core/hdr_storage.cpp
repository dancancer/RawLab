#include "core/hdr_storage.h"
#include "core/processing_cancellation.h"
#include "platform/hdr_image.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <limits>
#include <mutex>
#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace sony2fuji::hdr::storage {
namespace fs = std::filesystem;
namespace {
[[noreturn]] void ioError(const char* message) {
    throw Error(SONY2FUJI_STATUS_OUTPUT_IO_ERROR, SONY2FUJI_HDR_REASON_OUTPUT_IO,
        SONY2FUJI_HDR_FIELD_EXPORT, message);
}
constexpr const char* marker = ".rawlab-stream.lock";
#ifdef _WIN32
using Handle = HANDLE;
const Handle invalid = INVALID_HANDLE_VALUE;
void close(Handle handle) { if (handle != invalid) CloseHandle(handle); }
Handle lockMarker(const fs::path& path, bool create) {
    // 不共享读写，使存活任务的标记无法被另一个回收者打开；允许持有期间重命名/删除。
    auto handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_DELETE, nullptr,
        create ? CREATE_NEW : OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (handle == invalid) return invalid;
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(handle, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))) {
        close(handle); return invalid;
    }
    return handle;
}
#else
using Handle = int;
constexpr Handle invalid = -1;
void close(Handle handle) { if (handle >= 0) ::close(handle); }
Handle lockMarker(const fs::path& path, bool create) {
    const int fd = ::open(path.c_str(), O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT | O_EXCL : 0), 0600);
    if (fd < 0) return invalid;
    struct stat status{};
    if (fstat(fd, &status) || !S_ISREG(status.st_mode) || status.st_uid != geteuid() || flock(fd, LOCK_EX | LOCK_NB)) {
        close(fd); return invalid;
    }
    return fd;
}
#endif
}
struct Directory::State { Handle lock = invalid; ~State() { close(lock); } };
void Directory::recover(const fs::path& root) {
    std::error_code error;
    for (fs::directory_iterator it(root, error), end; !error && it != end; it.increment(error)) {
        const auto candidate = it->path();
        if (candidate.filename().u8string().rfind("RawLab-HDR-", 0) != 0 ||
            !fs::is_directory(it->symlink_status(error))) continue;
#ifdef _WIN32
        const auto attributes = GetFileAttributesW(candidate.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
#endif
        auto lock = lockMarker(candidate / marker, false);
        if (lock == invalid) continue;
        std::error_code ignored;
        fs::remove_all(candidate, ignored);
        close(lock);
    }
}
void requireSpace(const fs::path& root, uint64_t required) {
    Directory::recover(root);
    std::error_code error;
    const auto available = fs::space(root, error);
    if (error || required > available.available) ioError("Insufficient temporary disk space for HDR export");
}
Directory::Directory(const fs::path& root, uint64_t required) : state_(std::make_unique<State>()) {
    requireSpace(root, required);
    std::error_code error;
#ifdef _WIN32
    static std::atomic<uint64_t> serial{0};
    for (unsigned attempt = 0; attempt < 100; ++attempt) {
        const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
        auto candidate = root / ("RawLab-HDR-" + std::to_string(GetCurrentProcessId()) + "-" +
            std::to_string(nonce) + "-" + std::to_string(++serial));
        if (fs::create_directory(candidate, error)) { path = std::move(candidate); break; }
    }
    if (path.empty()) ioError("Cannot create private HDR export directory");
#else
    auto name = (root / "RawLab-HDR-XXXXXX").string();
    if (!mkdtemp(name.data())) ioError("Cannot create private HDR export directory");
    path = name;
#endif
    const auto pending = path / ".initializing";
    state_->lock = lockMarker(pending, true);
    if (state_->lock != invalid) fs::rename(pending, path / marker, error);
    if (state_->lock == invalid || error) {
        state_.reset(); fs::remove_all(path, error);
        ioError("Cannot lock private HDR export directory");
    }
}
Directory::~Directory() { std::error_code error; fs::remove_all(path, error); }

struct File::State {
    Handle handle = invalid;
    mutable std::mutex mutex;
    uint64_t end = 0;
    ~State() { close(handle); }
};
File::File(const fs::path& path, bool create) : state_(std::make_unique<State>()) {
#ifdef _WIN32
    state_->handle = CreateFileW(path.c_str(), create ? GENERIC_READ | GENERIC_WRITE : GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, create ? CREATE_NEW : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
#else
    state_->handle = ::open(path.c_str(), O_CLOEXEC | O_NOFOLLOW | (create ? O_RDWR | O_CREAT | O_EXCL : O_RDONLY), 0600);
#endif
    if (state_->handle == invalid) ioError("Cannot open HDR export scratch file");
}
File::~File() = default;
void File::resize(uint64_t bytes) {
    if (bytes > uint64_t(INT64_MAX)) ioError("Invalid HDR scratch length");
#ifdef _WIN32
    std::lock_guard<std::mutex> lock(state_->mutex);
    LARGE_INTEGER position{}; position.QuadPart = static_cast<LONGLONG>(bytes);
    if (!SetFilePointerEx(state_->handle, position, nullptr, FILE_BEGIN) || !SetEndOfFile(state_->handle))
        ioError("Cannot allocate HDR scratch storage");
#else
    if (ftruncate(state_->handle, off_t(bytes))) ioError("Cannot allocate HDR scratch storage");
#endif
    state_->end = bytes;
}
uint64_t File::size() const {
#ifdef _WIN32
    LARGE_INTEGER length{};
    if (!GetFileSizeEx(state_->handle, &length) || length.QuadPart < 0) ioError("Cannot inspect HDR scratch storage");
    return uint64_t(length.QuadPart);
#else
    struct stat info{};
    if (fstat(state_->handle, &info) || info.st_size < 0) ioError("Cannot inspect HDR scratch storage");
    return uint64_t(info.st_size);
#endif
}
void File::write(uint64_t offset, const void* data, size_t bytes) {
    if (offset > uint64_t(INT64_MAX) || bytes > uint64_t(INT64_MAX) - offset) ioError("Invalid HDR scratch range");
    auto* cursor = static_cast<const uint8_t*>(data);
#ifdef _WIN32
    std::lock_guard<std::mutex> lock(state_->mutex);
#endif
    while (bytes) {
        checkProcessingCancellation();
#ifdef _WIN32
        LARGE_INTEGER position{}; position.QuadPart = static_cast<LONGLONG>(offset);
        DWORD count = 0;
        if (!SetFilePointerEx(state_->handle, position, nullptr, FILE_BEGIN) ||
            !WriteFile(state_->handle, cursor, DWORD(std::min<size_t>(bytes, 1u << 30)), &count, nullptr))
            ioError("Cannot write HDR export scratch pixels");
#else
        const auto count = pwrite(state_->handle, cursor, bytes, off_t(offset));
        if (count < 0 && errno == EINTR) continue;
#endif
        if (count <= 0) ioError("Cannot write HDR export scratch pixels");
        cursor += count; bytes -= size_t(count); offset += uint64_t(count);
    }
}
void File::append(const void* data, size_t bytes) { write(state_->end, data, bytes); state_->end += bytes; }
void File::read(uint64_t offset, void* data, size_t bytes) const {
    if (offset > uint64_t(INT64_MAX) || bytes > uint64_t(INT64_MAX) - offset) ioError("Invalid HDR scratch range");
    auto* cursor = static_cast<uint8_t*>(data);
#ifdef _WIN32
    std::lock_guard<std::mutex> lock(state_->mutex);
#endif
    while (bytes) {
        checkProcessingCancellation();
#ifdef _WIN32
        LARGE_INTEGER position{}; position.QuadPart = static_cast<LONGLONG>(offset);
        DWORD count = 0;
        if (!SetFilePointerEx(state_->handle, position, nullptr, FILE_BEGIN) ||
            !ReadFile(state_->handle, cursor, DWORD(std::min<size_t>(bytes, 1u << 30)), &count, nullptr))
            ioError("Cannot read HDR export scratch pixels");
#else
        const auto count = pread(state_->handle, cursor, bytes, off_t(offset));
        if (count < 0 && errno == EINTR) continue;
#endif
        if (count <= 0) ioError("Truncated HDR export scratch pixels");
        cursor += count; bytes -= size_t(count); offset += uint64_t(count);
    }
}
struct Mapping::State {
    File file;
    void* data = nullptr;
    size_t bytes;
#ifdef _WIN32
    HANDLE mapping = nullptr;
#endif
    State(const fs::path& path, size_t size) : file(path), bytes(size) {}
    ~State() {
#ifdef _WIN32
        if (data) UnmapViewOfFile(data);
        if (mapping) CloseHandle(mapping);
#else
        if (data) munmap(data, bytes);
#endif
    }
};
Mapping::Mapping(const fs::path& path, size_t size) : state_(std::make_unique<State>(path, size)) {
    if (!size || state_->file.size() != size) ioError("Invalid compact HDR input length");
#ifdef _WIN32
    state_->mapping = CreateFileMappingW(state_->file.state_->handle, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (state_->mapping) state_->data = MapViewOfFile(state_->mapping, FILE_MAP_READ, 0, 0, size);
#else
    auto data = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, state_->file.state_->handle, 0);
    if (data != MAP_FAILED) state_->data = data;
#endif
    if (!state_->data) throw std::bad_alloc();
}
Mapping::~Mapping() = default;
const void* Mapping::data() const { return state_->data; }
}
