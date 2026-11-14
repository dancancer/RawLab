#pragma once

// Helpers shared by the encoders that publish through a staging file in the target
// directory. They keep the published file's permissions identical to a plain write.

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <string>

#ifndef _WIN32
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace sony2fuji {

#ifndef _WIN32
// A freshly created output used to inherit umask semantics (0666 & ~umask) through
// std::ofstream, while mkstemp always creates 0600. Encoders therefore create their
// staging file with 0666 and copy the destination's mode when they replace an
// existing file, so an export to a shared directory stays readable and a private
// file does not become world-readable.
//
// The mode is read through an O_NOFOLLOW descriptor plus fstat instead of stat():
// a symbolic-link destination (ELOOP) gets the default umask mode instead of one
// copied through the link, and the type check cannot be raced by a destination
// that is swapped between stat() and the publish rename.
inline void preserveDestinationMode(int fd, const std::filesystem::path& destination) noexcept {
    // O_NONBLOCK keeps a FIFO destination from blocking the export open.
    const int destinationFd =
        ::open(destination.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (destinationFd < 0) return; // missing, not a regular file, or a symlink
    struct stat existing{};
    const bool copyMode = ::fstat(destinationFd, &existing) == 0 && S_ISREG(existing.st_mode);
    (void)::close(destinationFd);
    if (copyMode) (void)::fchmod(fd, existing.st_mode & 0777);
}

// Unique enough for a same-directory staging file: pid plus a process-wide counter.
// Callers retry with O_EXCL, so a collision is impossible to publish by accident.
inline std::string stagingSuffix() {
    static std::atomic<uint64_t> counter{0};
    const auto uniq = counter.fetch_add(1, std::memory_order_relaxed);
    return std::to_string(static_cast<long>(::getpid())) + "-" + std::to_string(uniq);
}
#endif

} // namespace sony2fuji
