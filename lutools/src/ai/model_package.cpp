#include "model_package.h"
#include "dualdn_cache.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
#ifndef _WIN32
#include <unistd.h>
#endif

namespace sony2fuji::ai {
namespace {
std::string nativeModelPath(const std::filesystem::path& root, const nlohmann::json& graph, const char* name) {
    namespace fs = std::filesystem;
    const std::string directory = std::string(name) + ".mlmodelc";
    const auto folder = root / directory;
    if (graph.at("directory") != directory || fs::is_symlink(folder) || !fs::is_directory(folder))
        throw std::invalid_argument("Invalid Core ML model directory");
    const auto& files = graph.at("files");
    if (!files.is_array() || files.empty() || files.size() > 64)
        throw std::invalid_argument("Invalid Core ML file manifest");
    std::set<std::string> expected;
    uint64_t total = 0;
    for (const auto& entry : files) {
        const auto name = entry.at("path").get<std::string>();
        const auto relative = fs::u8path(name);
        if (name.empty() || name.find('\\') != std::string::npos || relative.is_absolute() ||
            relative.lexically_normal() != relative || relative.generic_u8string() != name || !expected.insert(name).second)
            throw std::invalid_argument("Invalid Core ML resource path");
        for (const auto& part : relative)
            if (part == "." || part == "..") throw std::invalid_argument("Core ML resource escapes its directory");
        const auto file = folder / relative;
        if (!entry.at("bytes").is_number_unsigned()) throw std::invalid_argument("Invalid Core ML resource size");
        const auto bytes = entry.at("bytes").get<uint64_t>();
        total += bytes;
        if (bytes == 0 || bytes > 512 * 1024 * 1024 || total > 512 * 1024 * 1024 || fs::is_symlink(file) ||
            !fs::is_regular_file(file) || fs::file_size(file) != bytes || sha256File(file.u8string()) != entry.at("sha256"))
            throw std::invalid_argument("Core ML resource SHA-256/size mismatch");
    }
    size_t count = 0;
    for (const auto& entry : fs::recursive_directory_iterator(folder)) {
        if (fs::is_symlink(entry.symlink_status())) throw std::invalid_argument("Core ML resources cannot contain symlinks");
        if (entry.is_directory()) continue;
        if (!entry.is_regular_file() || ++count > 64 || !expected.count(entry.path().lexically_relative(folder).generic_u8string()))
            throw std::invalid_argument("Untracked Core ML resource");
    }
    if (count != expected.size()) throw std::invalid_argument("Missing Core ML resource");
    return folder.u8string();
}

std::atomic<std::uint64_t> packageValidations{0};

// 包目录内容指纹（不读文件内容）：每个条目的 relpath + 类型 + 身份戳，排序后拼接。普通文件
// 复用 AISession::packageStamp() 同源的 sourceMetadataKey（POSIX dev/ino/ctime、Windows
// 卷/索引/创建/变更时间 + 模型变更租约；正常卷零内容读取），与 Windows 粗 mtime tick 及
// "保 size+mtime 篡改" 契约对齐。文件集合、任一身份或权限变化都改变指纹并触发全量重验；
// 遍历/取戳失败（含目录不可达、文件不可读）返回 false，调用方退回直接全量校验，错误仍由
// validate 原样抛出（与缓存引入前同语义）。
bool packageStateFingerprint(const std::filesystem::path& root, std::string& out) {
    namespace fs = std::filesystem;
    try {
        std::vector<std::string> lines;
        std::error_code error;
        for (fs::recursive_directory_iterator it(root, fs::directory_options::none, error), end;
             !error && it != end; it.increment(error)) {
            const auto relative = it->path().lexically_relative(root).generic_u8string();
            if (fs::is_symlink(it->symlink_status())) lines.push_back("L " + relative);
            else if (it->is_directory()) lines.push_back("D " + relative);
            else if (it->is_regular_file()) {
#ifndef _WIN32
                // stat 对无读权限文件照样成功；旧语义里 validate 会在 ifstream 读取处报错，
                // 故不可读必须让缓存让路（Windows 由 sourceMetadataKey 内 GENERIC_READ 句柄把关）。
                if (::access(it->path().c_str(), R_OK) != 0) return false;
#endif
                lines.push_back("F " + relative + " " + sourceMetadataKey(it->path().u8string()));
            }
            else lines.push_back("X " + relative);
        }
        if (error) return false;
        std::sort(lines.begin(), lines.end());
        out = root.generic_u8string();
        for (const auto& line : lines) { out += '\n'; out += line; }
        return true;
    } catch (...) { return false; }
}

// 进程级已校验包缓存：每个新 AISession（缩略图/批量/编辑器）构造都会 loadModelPackage，
// 未命中才全量 SHA-256（Mac 正式包实测每次校验需读 622MB），命中直接复用已校验包。
// 键、校验与指纹一律走 canonical 目录（软链写法在入口处收敛，缓存内只存 canonical
// 路径前缀，返回前按调用方写法重拼）；指纹取放与校验同在锁内，校验后复核目录未变才
// 入库——锁外不做决定性命中，锁内校验也让并发构造的两个 session 只重算一次。
struct PackageCache {
    std::mutex mutex;
    std::map<std::string, std::pair<std::string, ModelPackage>> entries;
};
PackageCache& packageCache() { static PackageCache cache; return cache; }

// 缓存条目内部只存 canonical 前缀；返回前按调用方本次传入的写法重拼相对部分。
ModelPackage rebasePackage(const ModelPackage& stored, const std::filesystem::path& canonical,
                           const std::filesystem::path& caller) {
    if (canonical == caller) return stored;
    auto re = [&](const std::string& value) {
        if (value.empty()) return value; // 未配置的可选路径保持空。
        const auto full = std::filesystem::u8path(value);
        return (caller / full.lexically_relative(canonical)).u8string();
    };
    auto out = stored;
    for (auto& path : out.paths) path = re(path);
    for (auto& path : out.coreMLPaths) path = re(path);
    out.blindRGBPath = re(out.blindRGBPath);
    out.blindRGBCoreMLPath = re(out.blindRGBCoreMLPath);
    return out;
}
}

static ModelPackage validateModelPackage(const std::string& directory) {
    packageValidations.fetch_add(1, std::memory_order_relaxed);
    const auto root = std::filesystem::u8path(directory);
    const auto path = root / "manifest.json";
    if (!std::filesystem::is_regular_file(path) || std::filesystem::file_size(path) > 65536)
        throw std::invalid_argument("Missing or oversized DualDn manifest");
    std::ifstream input(path);
    const auto manifest = nlohmann::json::parse(input);
    const nlohmann::json isp = {{"demosaic", "AHD"}, {"gamma", "Rec709"},
                               {"reference", "D65"}, {"alpha", 0}, {"bgu", false}};
    if (manifest.at("format_version") != 1 || manifest.at("protocol") != "rawlab-dualdn-v1" ||
        manifest.at("model_id") != "dualdn-big-restormer-v1" ||
        manifest.at("source_revision") != dualdnSourceRevision || manifest.at("weights_sha256") != dualdnWeightsSHA256 ||
        manifest.at("tile_size") != 640 || manifest.at("production_geometry") != true ||
        manifest.at("raw_core") != 384 || manifest.at("raw_halo") != 128 ||
        manifest.at("rgb_core") != 512 || manifest.at("rgb_halo") != 64 ||
        manifest.at("packed_order") != nlohmann::json({"R", "G_top", "G_bottom", "B"}) ||
        manifest.at("input_floor") != 1e-8 || manifest.at("variance_floor") != 1e-7 ||
        manifest.at("sigma_semantics") != "variance" || manifest.at("isp") != isp)
        throw std::invalid_argument("Unsupported DualDn model protocol");
    ModelPackage result;
    result.modelID = manifest.at("model_id"); result.tileSize = 640;
    // 路径字符串供 UTF-8 接口读取，不能经过 Windows 本地代码页。
    result.digest = sha256File(path.u8string());
    const char* names[] = {"raw", "isp", "rgb"};
    for (size_t i = 0; i < 3; ++i) {
        const auto& graph = manifest.at("graphs").at(names[i]);
        const std::string name = std::string(names[i]) + ".onnx";
        if (graph.at("file") != name || !graph.at("bytes").is_number_unsigned())
            throw std::invalid_argument("Invalid DualDn graph filename or size");
        const auto file = root / name;
        const auto bytes = graph.at("bytes").get<uint64_t>();
        if (bytes == 0 || bytes > 512 * 1024 * 1024 || !std::filesystem::is_regular_file(file) ||
            std::filesystem::file_size(file) != bytes || sha256File(file.u8string()) != graph.at("sha256"))
            throw std::invalid_argument("DualDn graph SHA-256/size mismatch: " + name);
        result.paths[i] = file.u8string();
    }
    if (manifest.contains("coreml")) {
        const auto& native = manifest.at("coreml");
        if (native.at("format") != "mlmodelc" || native.at("precision") != "float32")
            throw std::invalid_argument("Unsupported Core ML model protocol");
        result.coreMLPaths[0] = nativeModelPath(root, native.at("raw"), "raw");
        result.coreMLPaths[1] = nativeModelPath(root, native.at("rgb"), "rgb");
    }
    if (manifest.contains("blind_rgb")) {
        const auto& graph = manifest.at("blind_rgb");
        if (graph.at("model_id") != "restormer-real-srgb-v1" || graph.at("protocol") != "rawlab-scene-rgb-v1" ||
            graph.at("source_revision") != restormerSourceRevision || graph.at("weights_sha256") != restormerWeightsSHA256 ||
            graph.at("tile_size") != 640 || graph.at("core") != 512 || graph.at("halo") != 64 ||
            graph.at("input") != "encoded_rgb" || graph.at("output") != "denoised_rgb" ||
            graph.at("file") != "blind_rgb.onnx" || !graph.at("bytes").is_number_unsigned() ||
            graph.at("license_file") != "Restormer-LICENSE.txt" || graph.at("license_sha256") != restormerLicenseSHA256)
            throw std::invalid_argument("Unsupported scene RGB model protocol");
        const auto file = root / "blind_rgb.onnx", license = root / "Restormer-LICENSE.txt";
        const auto bytes = graph.at("bytes").get<uint64_t>();
        if (bytes == 0 || bytes > 512 * 1024 * 1024 || std::filesystem::is_symlink(file) ||
            !std::filesystem::is_regular_file(file) || std::filesystem::file_size(file) != bytes ||
            sha256File(file.u8string()) != graph.at("sha256") || std::filesystem::is_symlink(license) ||
            !std::filesystem::is_regular_file(license) || sha256File(license.u8string()) != restormerLicenseSHA256)
            throw std::invalid_argument("Scene RGB model or license SHA-256/size mismatch");
        result.blindRGBPath = file.u8string();
        if (graph.contains("coreml")) {
            const auto& native = graph.at("coreml");
            if (native.at("precision") != "float32") throw std::invalid_argument("Unsupported scene RGB Core ML precision");
            result.blindRGBCoreMLPath = nativeModelPath(root, native, "blind_rgb");
        }
    }
    return result;
}

ModelPackage loadModelPackage(const std::string& directory) {
    std::error_code error;
    const auto canonical = std::filesystem::canonical(std::filesystem::u8path(directory), error);
    // canonical 失败（目录缺失/不可达）硬失败，不回退未规范化串；消息与原缺失语义一致。
    if (error) throw std::invalid_argument("Missing or oversized DualDn manifest");
    const auto caller = std::filesystem::u8path(directory);
    const auto canonicalDirectory = canonical.u8string();
    auto& cache = packageCache();
    std::lock_guard<std::mutex> lock(cache.mutex);
    std::string key;
    // 枚举异常只跳过缓存这一优化层；校验仍对 canonical 执行，错误语义与缓存引入前一致。
    if (!packageStateFingerprint(canonical, key))
        return rebasePackage(validateModelPackage(canonicalDirectory), canonical, caller);
    const auto entry = cache.entries.find(canonicalDirectory);
    if (entry != cache.entries.end() && entry->second.first == key)
        return rebasePackage(entry->second.second, canonical, caller);
    auto result = validateModelPackage(canonicalDirectory);
    std::string after; // 校验后复核：目录在校验期间变过就不入库，也不信任旧条目。
    if (packageStateFingerprint(canonical, after) && after == key) {
        cache.entries.insert_or_assign(canonicalDirectory, std::make_pair(std::move(key), std::move(result)));
        result = cache.entries.at(canonicalDirectory).second;
    } else cache.entries.erase(canonicalDirectory);
    return rebasePackage(result, canonical, caller);
}

std::uint64_t modelPackageValidationCount() {
    return packageValidations.load(std::memory_order_relaxed);
}
} // namespace sony2fuji::ai
