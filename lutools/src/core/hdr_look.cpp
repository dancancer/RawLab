#include "core/hdr_look.h"
#include "core/parsed_resource_cache.h"
#include "core/processing_cancellation.h"
#include "core/sha256.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <utility>

namespace sony2fuji {
namespace {
bool isContentAddressedHDRLook(std::string_view path, std::string_view expectedHash) {
    if (expectedHash.size() != 64 || !std::all_of(expectedHash.begin(), expectedHash.end(),
            [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); })) return false;
    auto split = [](std::string_view s) {
        const auto p = s.find_last_of("/\\");
        return p == std::string_view::npos ? std::pair{std::string_view{}, s} : std::pair{s.substr(0, p), s.substr(p + 1)};
    };
    const auto [dir, file] = split(path);
    if (dir.empty() || file.size() != 69 || file.substr(0, 64) != expectedHash || file.substr(64) != ".cube") return false;
    const auto [grandDir, parent] = split(dir);
    return parent == "HDRLooks" || (parent == "HDR" && (split(grandDir).second == "Looks" || split(grandDir).second == "looks"));
}
} // namespace

HDRLook::HDRLook(const std::shared_ptr<LUT3D>& table, std::string fingerprint)
    : sampler_(table), low_(table->domainMin()), high_(table->domainMax()), size_(table->getSize()),
      fingerprint_(std::move(fingerprint)) {}

std::shared_ptr<const HDRLook> HDRLook::load(const std::string& path, std::string_view expectedHash, size_t* ioCount) {
    if (LUTParser::detectFormat(path) != "cube") throw std::invalid_argument("HDR look requires a declared CUBE");
    checkProcessingCancellation();
    static ParsedResourceCache<std::shared_ptr<const HDRLook>> cache;
    if (isContentAddressedHDRLook(path, expectedHash))
        if (auto cached = cache.find(path, expectedHash)) return *cached;
    if (ioCount) ++*ioCount;
    const auto filePath = std::filesystem::u8path(path);
    std::error_code error;
    if (!std::filesystem::is_regular_file(filePath, error)) throw std::invalid_argument("HDR look file is unavailable");
    std::ifstream file(filePath, std::ios::binary | std::ios::ate);
    const auto length = file.tellg();
    if (length <= 0 || length > 32 * 1024 * 1024) throw std::invalid_argument("Invalid HDR look file size");
    file.seekg(0);
    std::string bytes(static_cast<size_t>(length), '\0');
    if (!file.read(bytes.data(), bytes.size()) || file.peek() != std::char_traits<char>::eof())
        throw std::invalid_argument("HDR look file changed during reading");
    const auto digest = hash::sha256Bytes(bytes.data(), bytes.size());
    if (!expectedHash.empty() && digest != expectedHash) {
        cache.evict(path);
        throw std::invalid_argument("HDR look fingerprint changed");
    }
    checkProcessingCancellation();
    if (auto cached = cache.find(path, digest)) return *cached;
    auto table = std::make_shared<LUT3D>();
    if (table->loadFromData(bytes) != ErrorCode::Success || !table->hasHDRLookContract())
        throw std::invalid_argument("Invalid HDR CUBE declaration or domain");
    checkProcessingCancellation();
    return cache.put(path, digest, std::shared_ptr<const HDRLook>(new HDRLook(table, digest)));
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
