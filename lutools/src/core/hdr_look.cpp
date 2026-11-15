#include "core/hdr_look.h"
#include "core/processing_cancellation.h"
#include "core/sha256.h"
#include "core/resource_file_stamp.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <list>
#include <stdexcept>

namespace sony2fuji {

HDRLook::HDRLook(const std::shared_ptr<LUT3D>& table, std::string fingerprint)
    : sampler_(table), low_(table->domainMin()), high_(table->domainMax()), size_(table->getSize()),
      fingerprint_(std::move(fingerprint)) {}

std::shared_ptr<const HDRLook> HDRLook::load(const std::string& path, std::string_view expectedHash) {
    if (LUTParser::detectFormat(path) != "cube") throw std::invalid_argument("HDR look requires a declared CUBE");
    checkProcessingCancellation();
    const auto filePath = std::filesystem::u8path(path);
    const auto stamp = resourceFileStamp(filePath);
    if (!stamp) throw std::invalid_argument("HDR look file is unavailable");
    if (!stamp->size || stamp->size > 32 * 1024 * 1024) throw std::invalid_argument("Invalid HDR look file size");
    struct Entry {
        std::string path;
        ResourceFileStamp stamp;
        std::shared_ptr<const HDRLook> look;
    };
    static std::mutex mutex;
    static std::list<Entry> cache;
    std::lock_guard<std::mutex> lock(mutex);
    const auto found = std::find_if(cache.begin(), cache.end(), [&](const Entry& entry) { return entry.path == path; });
    auto reuse = [&] {
        if (!expectedHash.empty() && found->look->fingerprint() != expectedHash)
            throw std::invalid_argument("HDR look fingerprint changed");
        cache.splice(cache.begin(), cache, found);
        return cache.front().look;
    };
    if (found != cache.end() && found->stamp == *stamp) return reuse();
    std::ifstream file(filePath, std::ios::binary);
    std::string bytes(static_cast<size_t>(stamp->size), '\0');
    if (!file.read(bytes.data(), bytes.size()) || file.peek() != std::char_traits<char>::eof() ||
        !(resourceFileStamp(filePath) == stamp))
        throw std::invalid_argument("HDR look file changed during reading");
    const auto digest = hash::sha256Bytes(bytes.data(), bytes.size());
    if (!expectedHash.empty() && digest != expectedHash) throw std::invalid_argument("HDR look fingerprint changed");
    checkProcessingCancellation();
    if (found != cache.end() && found->look->fingerprint() == digest) {
        found->stamp = *stamp;
        return reuse();
    }
    auto table = std::make_shared<LUT3D>();
    if (table->loadFromData(bytes) != ErrorCode::Success || !table->hasHDRLookContract())
        throw std::invalid_argument("Invalid HDR CUBE declaration or domain");
    checkProcessingCancellation();
    auto look = std::shared_ptr<const HDRLook>(new HDRLook(table, digest));
    if (found != cache.end()) cache.erase(found);
    cache.push_front({path, *stamp, look});
    if (cache.size() > 8) cache.pop_back();
    return look;
}

RGB HDRLook::apply(const RGB& pixel, float strength) const {
    const RGB boundary{std::clamp(pixel.r, low_.r, high_.r), std::clamp(pixel.g, low_.g, high_.g),
        std::clamp(pixel.b, low_.b, high_.b)};
    const auto mapped = sampler_.apply(boundary);
    return {pixel.r + (mapped.r - boundary.r) * strength,
        pixel.g + (mapped.g - boundary.g) * strength,
        pixel.b + (mapped.b - boundary.b) * strength};
}

} // namespace sony2fuji
