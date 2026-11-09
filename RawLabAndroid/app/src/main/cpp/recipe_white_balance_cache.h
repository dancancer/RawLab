#pragma once

#include <optional>
#include <string>
#include <sys/stat.h>
#include <tuple>
#include <utility>

namespace rawlab {
struct RecipeWhiteBalance {
    float temperature;
    float tint;
};

class RecipeWhiteBalanceCache {
    struct Key {
        std::string path;
        dev_t device;
        ino_t inode;
        off_t size;
        timespec modified;
        int processing;
        int x3fMode;
        int exposureMode;

        auto fields() const {
            return std::tie(path, device, inode, size, modified.tv_sec, modified.tv_nsec,
                            processing, x3fMode, exposureMode);
        }
    };
    struct Entry {
        Key key;
        // nullopt records a successful probe of a RAW without calibrated white balance.
        std::optional<RecipeWhiteBalance> camera;
    };
    std::optional<Entry> recent_;

public:
    template<class Probe>
    std::optional<RecipeWhiteBalance> resolve(const char* path, int processing, int x3fMode,
                                             int exposureMode, Probe probe) {
        struct stat file{};
        if (!path || ::stat(path, &file) != 0) return probe();
#if defined(__APPLE__)
        const auto modified = file.st_mtimespec;
#else
        const auto modified = file.st_mtim;
#endif
        Key key{path, file.st_dev, file.st_ino, file.st_size, modified, processing, x3fMode, exposureMode};
        if (recent_ && recent_->key.fields() == key.fields()) return recent_->camera;
        auto camera = probe();
        recent_ = Entry{std::move(key), camera};
        return camera;
    }
};
}
