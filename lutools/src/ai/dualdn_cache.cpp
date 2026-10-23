#include "dualdn_cache.h"
#include "model_package.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <random>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <sys/stat.h>
#endif

namespace sony2fuji::ai {
namespace {
using Json = nlohmann::json;
bool validKey(const std::string& key) {
    return key.size() == 64 && key.find_first_not_of("0123456789abcdef") == std::string::npos;
}
const char* suffix(CacheKind kind) {
    if (kind == CacheKind::Raw) return ".rawcache";
    if (kind == CacheKind::RGB) return ".rgbcache";
    throw std::invalid_argument("invalid AI cache kind");
}
size_t countFor(CacheKind kind, int width, int height) {
    suffix(kind);
    if (width <= 0 || height <= 0 || uint64_t(width) * height > 100000000)
        throw std::invalid_argument("invalid AI cache dimensions");
    return size_t(width) * height * (kind == CacheKind::Raw ? 1 : 3);
}
std::string digestJson(const Json& value) {
    const auto text = value.dump();
    return sha256Bytes(text.data(), text.size());
}
Json sourceIdentity(const std::filesystem::path& path) {
#ifdef _WIN32
    const HANDLE file = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot identify AI source file");
    BY_HANDLE_FILE_INFORMATION info{};
    FILE_BASIC_INFO basic{};
    const bool valid = GetFileInformationByHandle(file, &info) != 0 &&
        GetFileInformationByHandleEx(file, FileBasicInfo, &basic, sizeof(basic)) != 0;
    CloseHandle(file);
    if (!valid) throw std::runtime_error("Cannot identify AI source file");
    return {info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow,
        info.ftCreationTime.dwHighDateTime, info.ftCreationTime.dwLowDateTime, basic.ChangeTime.QuadPart,
        // Windows 的时间戳更新可能延后；内容摘要防止同尺寸、保留时间的覆盖复用旧结果。
        sha256File(path.u8string())};
#else
    struct stat info{};
    if (::stat(path.c_str(), &info)) throw std::runtime_error("Cannot identify AI source file");
#ifdef __APPLE__
    const auto changed = info.st_ctimespec;
#else
    const auto changed = info.st_ctim;
#endif
    return {info.st_dev, info.st_ino, changed.tv_sec, changed.tv_nsec};
#endif
}
}

std::string sourceIdentityKey(const std::string& path) {
    const auto file = std::filesystem::canonical(std::filesystem::u8path(path));
    const auto modified = std::filesystem::last_write_time(file).time_since_epoch();
    return digestJson({{"file", file.u8string()}, {"bytes", std::filesystem::file_size(file)},
        {"modified_ns", std::chrono::duration_cast<std::chrono::nanoseconds>(modified).count()},
        {"source_identity", sourceIdentity(file)}});
}

std::string rawCacheKey(const std::string& path, const std::string& modelDigest, int backend) {
    if (!validKey(modelDigest)) throw std::invalid_argument("invalid AI model digest");
    return digestJson({{"source", sourceIdentityKey(path)},
        {"model", modelDigest}, {"backend", backend}, {"protocol", "rawlab-dualdn-v1"},
        {"decoder", "rawlab-bayer-v1"},
        {"calibration", "sony-ilce-7cm2-20261022-bce08d93bc36"}});
}

std::string rgbCacheKey(const std::string& rawKey, const RAWProcessOptions& options) {
    if (!validKey(rawKey) || options.useAutoWhiteBalance)
        throw std::invalid_argument("invalid AI cache identity or unsupported auto white balance");
    Json key = {{"raw", rawKey}, {"bridge", 2}, {"demosaic", static_cast<int>(options.bayerDemosaic)}};
    if (options.useTemperatureWhiteBalance) {
        if (!std::isfinite(options.temperature) || !std::isfinite(options.tint)) throw std::invalid_argument("invalid AI white balance");
        key["wb"] = {"temperature", options.temperature, options.tint};
    } else if (options.useCustomWhiteBalance) {
        key["wb"] = Json::array({"custom"});
        for (float value : options.customWhiteBalance) {
            if (!std::isfinite(value) || value < 0) throw std::invalid_argument("invalid AI white balance");
            key["wb"].push_back(value);
        }
    } else key["wb"] = options.useCameraWhiteBalance ? "camera" : "daylight";
    return digestJson(key);
}

DenoiseCache::DenoiseCache(std::string directory) : directory_(std::move(directory)) {
    const uint16_t endian = 1;
    if (*reinterpret_cast<const uint8_t*>(&endian) != 1 || sizeof(float) != 4)
        throw std::runtime_error("AI cache requires little-endian float32");
    if (directory_.empty()) throw std::invalid_argument("AI cache directory is empty");
}

std::optional<Tensor> DenoiseCache::load(const std::string& key, CacheKind kind, int width, int height,
                                       const std::string& dependency, std::string* producer) const {
    if (producer) producer->clear();
    if (!validKey(key) || (!dependency.empty() && !validKey(dependency))) throw std::invalid_argument("invalid AI cache key");
    const size_t count = countFor(kind, width, height);
    const auto file = std::filesystem::u8path(directory_) / (key + suffix(kind));
    try {
        std::ifstream input(file, std::ios::binary);
        if (!input) return {};
        uint32_t length = 0; input.read(reinterpret_cast<char*>(&length), sizeof(length));
        if (!input || length == 0 || length > 4096 || std::filesystem::file_size(file) != 4 + uint64_t(length) + count * 4) return {};
        std::string text(length, '\0'); input.read(text.data(), length);
        const auto header = Json::parse(text);
        if (header.at("format") != "rawlab-dualdn-cache-v1" || header.at("key") != key ||
            header.at("width") != width || header.at("height") != height ||
            header.at("channels") != (kind == CacheKind::Raw ? 1 : 3) ||
            header.value("dependency", std::string()) != dependency) return {};
        Tensor result{width, height, kind == CacheKind::Raw ? 1 : 3, std::vector<float>(count)};
        input.read(reinterpret_cast<char*>(result.values.data()), count * sizeof(float));
        if (!input || sha256Bytes(result.values.data(), count * 4) != header.at("sha256")) return {};
        validateTensor(result);
        const auto savedProducer = header.value("producer", std::string());
        if (savedProducer.size() > 128) return {};
        std::error_code ignored;
        std::filesystem::last_write_time(file, std::filesystem::file_time_type::clock::now(), ignored);
        if (producer) *producer = savedProducer;
        return result;
    } catch (const std::bad_alloc&) { throw; }
    catch (const std::exception&) { return {}; }
}

void DenoiseCache::store(const std::string& key, CacheKind kind, int width, int height, const float* values, size_t count,
                         const std::string& dependency, const std::string& producer) const {
    if (!validKey(key) || (!dependency.empty() && !validKey(dependency)) || !values || count != countFor(kind, width, height) ||
        producer.size() > 128 || !std::all_of(values, values + count, [](float x) { return std::isfinite(x); }))
        throw std::invalid_argument("invalid AI cache payload");
    const auto root = std::filesystem::u8path(directory_);
    std::filesystem::create_directories(root);
    const auto target = root / (key + suffix(kind));
    std::random_device random;
    const auto temporary = root / (key + suffix(kind) + ".part-" + std::to_string(random()) + "-" + std::to_string(random()));
    const Json header = {{"format", "rawlab-dualdn-cache-v1"}, {"key", key}, {"width", width}, {"height", height},
        {"channels", kind == CacheKind::Raw ? 1 : 3}, {"sha256", sha256Bytes(values, count * 4)},
        {"dependency", dependency}, {"producer", producer}};
    const auto text = header.dump(); const uint32_t length = static_cast<uint32_t>(text.size());
    try {
        std::ofstream output(temporary, std::ios::binary);
        output.write(reinterpret_cast<const char*>(&length), sizeof(length));
        output.write(text.data(), text.size());
        output.write(reinterpret_cast<const char*>(values), count * 4); output.close();
        if (!output) throw std::runtime_error("Cannot write AI cache");
#ifdef _WIN32
        // 原子替换整个文件，确保相同张量的新 producer 和依赖信息也一起更新。
        if (!MoveFileExW(temporary.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING))
            throw std::system_error(GetLastError(), std::system_category(), "Cannot replace AI cache");
#else
        std::filesystem::rename(temporary, target);
#endif
    } catch (...) {
        std::error_code ignored; std::filesystem::remove(temporary, ignored); throw;
    }
}

void DenoiseCache::prune(uint64_t byteLimit, const std::set<std::string>& protectedKeys) const {
    struct Entry { std::filesystem::path path; uint64_t bytes; std::filesystem::file_time_type used; };
    std::vector<Entry> candidates;
    uint64_t bytes = 0;
    std::error_code error;
    const auto root = std::filesystem::u8path(directory_);
    if (!std::filesystem::is_directory(root, error)) return;
    for (const auto& entry : std::filesystem::directory_iterator(root, std::filesystem::directory_options::skip_permission_denied)) {
        const auto name = entry.path().filename().string();
        if (name.size() != 73 || !validKey(name.substr(0,64)) ||
            (name.substr(64) != ".rawcache" && name.substr(64) != ".rgbcache") ||
            entry.is_symlink() || !entry.is_regular_file()) continue;
        const auto size = entry.file_size(); bytes += size;
        if (!protectedKeys.count(name.substr(0,64))) candidates.push_back({entry.path(), size, entry.last_write_time()});
    }
    std::sort(candidates.begin(), candidates.end(), [](const Entry& a, const Entry& b) { return a.used < b.used; });
    for (const auto& entry : candidates) {
        if (bytes <= byteLimit) break;
        if (std::filesystem::remove(entry.path, error)) bytes -= entry.bytes;
    }
}
} // namespace sony2fuji::ai
