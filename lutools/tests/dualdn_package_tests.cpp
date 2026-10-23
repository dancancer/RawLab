#include "ai/model_package.h"
#include <nlohmann/json.hpp>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace sony2fuji::ai;
using Json = nlohmann::json;
void require(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }

int main(int argc, char** argv) {
    std::filesystem::path root;
    try {
        if (argc != 2) throw std::runtime_error("requires an empty temporary directory");
        root = std::filesystem::u8path(argv[1]);
        if (!std::filesystem::create_directory(root)) throw std::runtime_error("temporary directory already exists");
        const auto sample = root / "sample";
        { std::ofstream out(sample); }
        require(sha256File(sample.string()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty SHA-256");
        { std::ofstream out(sample); out << "abc"; }
        require(sha256File(sample.string()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc SHA-256");
        { std::ofstream out(sample); for (int i = 0; i < 1000000; ++i) out << 'a'; }
        require(sha256File(sample.string()) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "streaming SHA-256");
        // 独立 hashlib 生成的向量，覆盖压缩块和文件读取块两侧的非整倍数长度。
        const std::pair<int, const char*> boundaries[] = {
            {65, "fc518669b6eb4b4dd91827ecacef86689c725bd5bab888fd3b26dbb196eec954"},
            {65535, "11cad04d25d7e2ae2bde1131397c1ee623dcf0731e3e123f278fa192a9d72976"},
            {65536, "6fc179cfd193754e6109ad043f56d146c7e7d7c3623ffceae318266286f58388"},
            {65537, "3123afca912e156e19bcd2055eb92e944cf6e6fdb0eef16d65464342ad1f5a1a"},
            {131079, "9ad4f09f38f496df39bfb69a39cd4543c9b72ce556c5c1ef23d9c6aa15b7d2a9"}
        };
        for (const auto& [size, digest] : boundaries) {
            std::vector<uint8_t> bytes(size);
            for (int i = 0; i < size; ++i) bytes[i] = uint8_t((i * 37 + 11) % 256);
            { std::ofstream out(sample, std::ios::binary); out.write(reinterpret_cast<const char*>(bytes.data()), bytes.size()); }
            require(sha256File(sample.string()) == digest, "SHA-256 block boundary");
            require(sha256Bytes(bytes.data(), bytes.size()) == digest, "SHA-256 memory block boundary");
        }
        Json manifest = {{"format_version", 1}, {"protocol", "rawlab-dualdn-v1"},
            {"model_id", "dualdn-big-restormer-v1"}, {"source_revision", dualdnSourceRevision},
            {"weights_sha256", dualdnWeightsSHA256}, {"tile_size", 640}, {"production_geometry", true},
            {"raw_core", 384}, {"raw_halo", 128}, {"rgb_core", 512}, {"rgb_halo", 64},
            {"packed_order", {"R", "G_top", "G_bottom", "B"}},
            {"input_floor", 1e-8}, {"variance_floor", 1e-7}, {"sigma_semantics", "variance"},
            {"isp", {{"demosaic", "AHD"}, {"gamma", "Rec709"}, {"reference", "D65"}, {"alpha", 0}, {"bgu", false}}}};
        for (const auto* name : {"raw", "isp", "rgb"}) {
            auto file = root / (std::string(name) + ".onnx");
            { std::ofstream out(file); out << "test package integrity"; }
            manifest["graphs"][name] = {{"file", file.filename().string()}, {"sha256", sha256File(file.string())},
                                          {"bytes", std::filesystem::file_size(file)}};
        }
        auto write = [&] { std::ofstream(root / "manifest.json") << manifest.dump(); };
        write();
        const auto package = loadModelPackage(root.string());
        require(package.tileSize == 640 && package.digest.size() == 64, "valid model package rejected");
        auto rejects = [&] {
            bool failed = false; try { loadModelPackage(root.string()); } catch (const std::exception&) { failed = true; }
            require(failed, "corrupt model package accepted");
        };
        manifest["blind_rgb"] = {{"model_id", "unrecognized-rgb-model"}};
        write(); rejects();
        const auto blindFile = root/"blind_rgb.onnx", licenseFile = root/"Restormer-LICENSE.txt";
        { std::ofstream out(blindFile); out << "RGB model package integrity fixture"; }
        std::filesystem::copy_file(RESTORMER_TEST_LICENSE,licenseFile);
        manifest["blind_rgb"] = {{"model_id","restormer-real-srgb-v1"}, {"protocol","rawlab-scene-rgb-v1"},
            {"source_revision",restormerSourceRevision}, {"weights_sha256",restormerWeightsSHA256},
            {"tile_size",640}, {"core",512}, {"halo",64}, {"input","encoded_rgb"}, {"output","denoised_rgb"},
            {"file","blind_rgb.onnx"}, {"bytes",std::filesystem::file_size(blindFile)}, {"sha256",sha256File(blindFile.string())},
            {"license_file","Restormer-LICENSE.txt"}, {"license_sha256",restormerLicenseSHA256}};
        write();
        require(loadModelPackage(root.string()).blindRGBPath == blindFile.string(),"valid scene RGB package rejected");
        manifest["blind_rgb"]["sha256"] = std::string(64,'a'); write(); rejects();
        manifest["blind_rgb"]["sha256"] = sha256File(blindFile.string());
        manifest["blind_rgb"]["weights_sha256"] = std::string(64,'b'); write(); rejects();
        manifest["blind_rgb"]["weights_sha256"] = restormerWeightsSHA256;
        { std::ofstream out(licenseFile,std::ios::app); out << "changed"; }
        write(); rejects();
        std::filesystem::copy_file(RESTORMER_TEST_LICENSE,licenseFile,std::filesystem::copy_options::overwrite_existing);
        std::filesystem::create_directories(root/"blind_rgb.mlmodelc");
        const auto nativeRGB = root/"blind_rgb.mlmodelc/model.mil";
        { std::ofstream out(nativeRGB); out << "native RGB fixture"; }
        manifest["blind_rgb"]["coreml"] = {{"directory","blind_rgb.mlmodelc"}, {"precision","float32"},
            {"files",Json::array({{{"path","model.mil"}, {"bytes",std::filesystem::file_size(nativeRGB)}, {"sha256",sha256File(nativeRGB.string())}}})}};
        write();
        require(!loadModelPackage(root.string()).blindRGBCoreMLPath.empty(),"scene RGB native path missing");
        manifest["blind_rgb"]["coreml"]["files"][0]["path"] = "../sample"; write(); rejects();
        manifest["blind_rgb"]["coreml"]["files"][0]["path"] = "model.mil";
        const auto blindManifest = manifest["blind_rgb"];
        manifest.erase("blind_rgb");
        manifest["graphs"]["raw"]["file"] = "../sample"; write(); rejects();
        manifest["graphs"]["raw"]["file"] = "raw.onnx";
        manifest["tile_size"] = 64; write(); rejects();
        manifest["tile_size"] = 640; manifest["sigma_semantics"] = "standard deviation"; write(); rejects();
        manifest["sigma_semantics"] = "variance"; write();
        require(package.coreMLPaths[0].empty() && package.coreMLPaths[1].empty(), "legacy package acquired native models");
        manifest["coreml"] = {{"format", "mlmodelc"}, {"precision", "float32"}};
        for (const auto* name : {"raw", "rgb"}) {
            const auto directory = std::string(name) + ".mlmodelc";
            std::filesystem::create_directories(root / directory / "weights");
            const auto file = root / directory / "weights/weight.bin";
            { std::ofstream out(file); out << "native model fixture"; }
            manifest["coreml"][name] = {{"directory", directory}, {"files", Json::array({
                {{"path", "weights/weight.bin"}, {"sha256", sha256File(file.string())}, {"bytes", std::filesystem::file_size(file)}}
            })}};
        }
        write();
        const auto native = loadModelPackage(root.string());
        require(!native.coreMLPaths[0].empty() && !native.coreMLPaths[1].empty(), "native models not found");
        manifest["blind_rgb"] = blindManifest; write();
        require(!loadModelPackage(root.string()).blindRGBCoreMLPath.empty(),"combined native model bundle rejected");
        const auto nativeManifest = manifest["coreml"];
        manifest.erase("coreml"); manifest["blind_rgb"].erase("coreml"); write();
        const auto windows = loadModelPackage(root.string());
        require(windows.coreMLPaths[0].empty() && windows.blindRGBCoreMLPath.empty() && !windows.blindRGBPath.empty(),
                "removing Apple manifest fields broke portable RGB package");
        manifest["coreml"] = nativeManifest;
        manifest["coreml"]["precision"] = "float16"; write(); rejects();
        manifest["coreml"]["precision"] = "float32";
        manifest["coreml"]["raw"]["files"][0]["path"] = "../sample"; write(); rejects();
        manifest["coreml"]["raw"]["files"][0]["path"] = "weights/weight.bin"; write();
        { std::ofstream out(root / "raw.mlmodelc/extra.bin"); out << "untracked"; }
        rejects(); std::filesystem::remove(root / "raw.mlmodelc/extra.bin");
        { std::ofstream out(root / "raw.mlmodelc/weights/weight.bin", std::ios::app); out << "corrupt"; }
        rejects();
        manifest.erase("coreml"); write();
        { std::ofstream out(root / "raw.onnx", std::ios::app); out << "corrupt"; }
        rejects();
        std::filesystem::remove_all(root);
        std::cout << "PASS SHA-256 and DualDn package integrity/protocol\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
