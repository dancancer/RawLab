#include "model_package.h"
#include <nlohmann/json.hpp>
#include <filesystem>
#include <fstream>
#include <set>
#include <stdexcept>

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
            !fs::is_regular_file(file) || fs::file_size(file) != bytes || sha256File(file.string()) != entry.at("sha256"))
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
    return folder.string();
}
}

ModelPackage loadModelPackage(const std::string& directory) {
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
    result.digest = sha256File(path.string());
    const char* names[] = {"raw", "isp", "rgb"};
    for (size_t i = 0; i < 3; ++i) {
        const auto& graph = manifest.at("graphs").at(names[i]);
        const std::string name = std::string(names[i]) + ".onnx";
        if (graph.at("file") != name || !graph.at("bytes").is_number_unsigned())
            throw std::invalid_argument("Invalid DualDn graph filename or size");
        const auto file = root / name;
        const auto bytes = graph.at("bytes").get<uint64_t>();
        if (bytes == 0 || bytes > 512 * 1024 * 1024 || !std::filesystem::is_regular_file(file) ||
            std::filesystem::file_size(file) != bytes || sha256File(file.string()) != graph.at("sha256"))
            throw std::invalid_argument("DualDn graph SHA-256/size mismatch: " + name);
        result.paths[i] = file.string();
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
            sha256File(file.string()) != graph.at("sha256") || std::filesystem::is_symlink(license) ||
            !std::filesystem::is_regular_file(license) || sha256File(license.string()) != restormerLicenseSHA256)
            throw std::invalid_argument("Scene RGB model or license SHA-256/size mismatch");
        result.blindRGBPath = file.string();
        if (graph.contains("coreml")) {
            const auto& native = graph.at("coreml");
            if (native.at("precision") != "float32") throw std::invalid_argument("Unsupported scene RGB Core ML precision");
            result.blindRGBCoreMLPath = nativeModelPath(root, native, "blind_rgb");
        }
    }
    return result;
}
} // namespace sony2fuji::ai
