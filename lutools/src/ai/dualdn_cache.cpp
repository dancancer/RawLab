#include "dualdn_cache.h"
#include "cache_reader.h"
#include "model_package.h"
#include "noise_profile.h"
#include "scene_rgb_adapter.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <random>
#include <map>
#include <mutex>
#include <thread>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include "windows_file_changes.h"
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
    if (kind == CacheKind::SceneRGB) return ".scenecache";
    throw std::invalid_argument("invalid AI cache kind");
}
size_t countFor(CacheKind kind, int width, int height) {
    suffix(kind);
    if (width <= 0 || height <= 0 || uint64_t(width) * height > 128000000)
        throw std::invalid_argument("invalid AI cache dimensions");
    return size_t(width) * height * (kind == CacheKind::Raw ? 1 : 3);
}
std::string digestJson(const Json& value) {
    const auto text = value.dump();
    return sha256Bytes(text.data(), text.size());
}
struct SourceMetadata {
    Json identity;
    Json changed;
    Json sequence;
    bool cacheable = true;
    std::string stamp() const { return digestJson({identity, changed, sequence}); }
};
SourceMetadata sourceMetadata(const std::filesystem::path& path, bool model = false) {
#ifdef _WIN32
    // 允许其他程序同时打开写句柄；变更租约与摘要前后校验负责检测实际修改。
    const HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot identify AI source file");
    BY_HANDLE_FILE_INFORMATION info{};
    FILE_BASIC_INFO basic{};
    const bool valid = GetFileInformationByHandle(file, &info) != 0 &&
        GetFileInformationByHandleEx(file, FileBasicInfo, &basic, sizeof(basic)) != 0;
    const auto generation = valid ? fileChangeGeneration(path, model) : std::nullopt;
    CloseHandle(file);
    if (!valid) throw std::runtime_error("Cannot identify AI source file");
    return {{{"file", path.u8string()}, {"volume", info.dwVolumeSerialNumber},
        {"index", {info.nFileIndexHigh, info.nFileIndexLow}},
        {"created", basic.CreationTime.QuadPart}, {"modified", basic.LastWriteTime.QuadPart},
        {"bytes", (uint64_t(info.nFileSizeHigh) << 32) | info.nFileSizeLow}},
        basic.ChangeTime.QuadPart, generation ? Json(*generation) : Json(), generation.has_value()};
#else
    struct stat info{};
    if (::stat(path.c_str(), &info)) throw std::runtime_error("Cannot identify AI source file");
#ifdef __APPLE__
    const auto modified = info.st_mtimespec, changed = info.st_ctimespec;
#else
    const auto modified = info.st_mtim, changed = info.st_ctim;
#endif
    return {{{"file", path.u8string()}, {"device", info.st_dev}, {"index", info.st_ino},
        {"modified", {modified.tv_sec, modified.tv_nsec}}, {"bytes", info.st_size}},
        {changed.tv_sec, changed.tv_nsec}};
#endif
}
}

std::string sourceMetadataKey(const std::string& path) {
    const auto metadata = sourceMetadata(std::filesystem::canonical(std::filesystem::u8path(path)), true);
    // 不支持变更通知的文件系统不能安全复用元数据；只在该退路读取内容。
    return metadata.cacheable ? metadata.stamp() : digestJson({metadata.stamp(), sha256File(path)});
}

std::string sourceIdentityKey(const std::string& path) {
    struct Entry { std::string stamp, key; uint64_t used; };
    static std::mutex mutex;
    static std::map<std::string, Entry> cache;
    static uint64_t access = 0;
    const auto file = std::filesystem::canonical(std::filesystem::u8path(path));
    std::lock_guard<std::mutex> lock(mutex);
    const auto metadata = sourceMetadata(file);
    const auto stamp = metadata.stamp();
    const auto found = cache.find(file.u8string());
    if (metadata.cacheable && found != cache.end() && found->second.stamp == stamp) {
        found->second.used = ++access;
        return found->second.key;
    }
    const auto content = sha256File(file.u8string());
    const auto after = sourceMetadata(file);
    if (after.identity != metadata.identity || after.changed != metadata.changed ||
        (metadata.cacheable && (after.sequence != metadata.sequence || !after.cacheable)))
        throw std::runtime_error("AI source changed while computing its identity");
    // ctime/ChangeTime 只触发摘要刷新，权限和标签变化不改变最终照片身份。
    const auto key = digestJson({metadata.identity, content});
    if (found == cache.end() && cache.size() >= 128) {
        const auto oldest = std::min_element(cache.begin(), cache.end(),
            [](const auto& left, const auto& right) { return left.second.used < right.second.used; });
        cache.erase(oldest);
    }
    cache[file.u8string()] = {stamp, key, ++access};
    return key;
}

std::string rawCacheKeyFromIdentity(const std::string& sourceIdentity, const std::string& modelDigest, int backend) {
    if (!validKey(modelDigest) || !validKey(sourceIdentity)) throw std::invalid_argument("invalid AI cache digest");
    return digestJson({{"source", sourceIdentity},
        {"model", modelDigest}, {"backend", backend}, {"protocol", "rawlab-dualdn-v1"},
        {"decoder", "rawlab-bayer-v2"}, {"noise", noiseProtocol}});
}

std::string rawCacheKey(const std::string& path, const std::string& modelDigest, int backend) {
    return rawCacheKeyFromIdentity(sourceIdentityKey(path), modelDigest, backend);
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

std::string sceneRGBCacheKey(const std::string& rawKey, const RAWProcessOptions& options) {
    Json key = {{"source_wb", rgbCacheKey(rawKey,options)}, {"adapter", sceneRGBProtocol}};
    const auto& lens = options.lensCorrection;
    if (lens.active()) key["lens"] = {lens.distortion,lens.tca,lens.autoCrop,lens.profileID,
        options.lensDatabase ? options.lensDatabase->cacheIdentity() : "missing"};
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
    const bool readDimensions = kind == CacheKind::SceneRGB && width == 0 && height == 0;
    if (!readDimensions) countFor(kind, width, height);
    const auto file = std::filesystem::u8path(directory_) / (key + suffix(kind));
    try {
        CacheReader input(file);
        if (!input) return {};
        uint32_t length = 0; input.read(reinterpret_cast<char*>(&length), sizeof(length));
        if (!input || length == 0 || length > 4096) return {};
        std::string text(length, '\0'); input.read(text.data(), length);
        auto header = Json::parse(text);
        if (kind == CacheKind::SceneRGB || header.contains("header_sha256")) {
            const auto expected = header.at("header_sha256").get<std::string>();
            header.erase("header_sha256");
            if (digestJson(header) != expected) return {};
        }
        if (readDimensions) { width = header.at("width").get<int>(); height = header.at("height").get<int>(); }
        const size_t count = countFor(kind, width, height);
        if (input.size() != 4 + uint64_t(length) + count * 4) return {};
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
    Json header = {{"format", "rawlab-dualdn-cache-v1"}, {"key", key}, {"width", width}, {"height", height},
        {"channels", kind == CacheKind::Raw ? 1 : 3}, {"sha256", sha256Bytes(values, count * 4)},
        {"dependency", dependency}, {"producer", producer}};
    header["header_sha256"] = digestJson(header);
    const auto text = header.dump(); const uint32_t length = static_cast<uint32_t>(text.size());
    try {
        std::ofstream output(temporary, std::ios::binary);
        output.write(reinterpret_cast<const char*>(&length), sizeof(length));
        output.write(text.data(), text.size());
        output.write(reinterpret_cast<const char*>(values), count * 4); output.close();
        if (!output) throw std::runtime_error("Cannot write AI cache");
#ifdef _WIN32
        // 原子替换整个文件，确保相同张量的新 producer 和依赖信息也一起更新。
        // Windows 即使允许共享删除，也可能在旧读者关闭前拒绝替换；保留原子发布，有限等待短暂读取。
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (!MoveFileExW(temporary.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING)) {
            const auto error = GetLastError();
            if ((error != ERROR_ACCESS_DENIED && error != ERROR_SHARING_VIOLATION) ||
                std::chrono::steady_clock::now() >= deadline)
                throw std::system_error(error, std::system_category(), "Cannot replace AI cache");
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
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
        if (name.size() < 73 || !validKey(name.substr(0,64)) ||
            (name.substr(64) != ".rawcache" && name.substr(64) != ".rgbcache" && name.substr(64) != ".scenecache") ||
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
