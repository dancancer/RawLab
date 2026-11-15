// 只在此测试翻译单元包裹真实文件摘要，生产代码不增加计数器或替代读路径。
#define sha256File realSha256File
#include "../src/ai/model_sha256.cpp"
#undef sha256File
#include "ai/dualdn_cache.h"
#include <iostream>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#endif

namespace { size_t fileReads = 0; }
namespace sony2fuji::ai {
std::string sha256File(const std::string& path) {
    ++fileReads;
    return realSha256File(path);
}
}

int main(int argc, char** argv) {
    namespace fs = std::filesystem;
    using namespace sony2fuji::ai;
    try {
        if (argc != 2 || !fs::create_directory(argv[1])) throw std::runtime_error("requires fresh test directory");
        const fs::path file = fs::path(argv[1]) / "source.raw";
        { std::ofstream(file) << "original"; }
        const auto identity = sourceIdentityKey(file.string());
        if (fileReads != 1) throw std::runtime_error("first source identity must read content once");
        for (int i = 0; i < 5; ++i)
            if (sourceIdentityKey(file.string()) != identity) throw std::runtime_error("stable identity changed");
        if (fileReads != 1) throw std::runtime_error("cached source identity reread content");
        const auto modified = fs::last_write_time(file);
        { std::ofstream(file) << "replaced"; }
        fs::last_write_time(file, modified);
        if (sourceIdentityKey(file.string()) == identity || fileReads != 2)
            throw std::runtime_error("preserved-time overwrite was not rehashed exactly once");
        auto previous = sourceIdentityKey(file.string());
        for (int i = 0; i < 20; ++i) {
            { std::ofstream(file) << (i % 2 ? "changed!" : "original"); }
            fs::last_write_time(file, modified);
            const auto current = sourceIdentityKey(file.string());
            if (current == previous || fileReads != size_t(i + 3))
                throw std::runtime_error("rapid preserved-time overwrite reused a cached digest");
            previous = current;
        }
        // 模型路径常排在 AppData 下；不断打开照片不能使已校验模型的指纹失效。
        std::vector<fs::path> models;
        std::vector<std::string> stamps;
        for (int i = 0; i < 7; ++i) {
            const auto model = fs::path(argv[1]) / ("a-model-" + std::to_string(i));
            { std::ofstream(model) << "model"; }
            models.push_back(model); stamps.push_back(sourceMetadataKey(model.string()));
        }
        for (int i = 0; i < 256; ++i) {
            const auto photo = fs::path(argv[1]) / ("z-photo-" + std::to_string(i));
            { std::ofstream(photo) << i; }
            sourceIdentityKey(photo.string());
            for (size_t model = 0; model < models.size(); ++model)
                if (sourceMetadataKey(models[model].string()) != stamps[model])
                    throw std::runtime_error("Opening photo " + std::to_string(i) + " evicted a model lease");
        }
        const auto hot = fs::path(argv[1]) / "a-hot-photo.raw";
        { std::ofstream(hot) << "frequently rendered"; }
        const auto hotKey = sourceIdentityKey(hot.string());
        for (int i = 0; i < 256; ++i) {
            const auto photo = fs::path(argv[1]) / ("z-lru-photo-" + std::to_string(i));
            { std::ofstream(photo) << i; }
            sourceIdentityKey(photo.string());
            const auto before = fileReads;
            if (sourceIdentityKey(hot.string()) != hotKey || fileReads != before)
                throw std::runtime_error("Frequently rendered photo was evicted instead of the least recently used photo");
        }
        // 非 USN 卷 packageStamp() 每帧逐个模型文件调用退路：stat 身份不变时整文件摘要必须只读一次。
        {
            forceMetadataFallbackForTests(true);
            const auto before = fileReads;
            std::vector<fs::path> fallbackFiles;
            std::vector<std::string> fallbackKeys;
            for (int i = 0; i < 3; ++i) {
                const auto model = fs::path(argv[1]) / ("fallback-model-" + std::to_string(i));
                { std::ofstream(model) << std::string(64 + i, char('a' + i)); }
                fallbackFiles.push_back(model);
                fallbackKeys.push_back(sourceMetadataKey(model.string()));
            }
            if (fileReads != before + 3) {
                forceMetadataFallbackForTests(false);
                throw std::runtime_error("metadata fallback must hash each file exactly once");
            }
            for (int frame = 0; frame < 5; ++frame)
                for (size_t i = 0; i < fallbackFiles.size(); ++i)
                    if (sourceMetadataKey(fallbackFiles[i].string()) != fallbackKeys[i]) {
                        forceMetadataFallbackForTests(false);
                        throw std::runtime_error("metadata fallback changed the key for an unchanged file");
                    }
            if (fileReads != before + 3) {
                forceMetadataFallbackForTests(false);
                throw std::runtime_error("metadata fallback reread whole files for every package stamp");
            }
            { std::ofstream(fallbackFiles[1]) << std::string(66, 'z'); }
            const auto changed = sourceMetadataKey(fallbackFiles[1].string());
            forceMetadataFallbackForTests(false);
            if (changed == fallbackKeys[1]) throw std::runtime_error("metadata fallback reused a stale key after the file changed");
            if (fileReads != before + 4) throw std::runtime_error("metadata fallback did not rehash exactly once after the change");
        }
#ifdef _WIN32
        const auto writer = CreateFileW(file.c_str(), GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (writer == INVALID_HANDLE_VALUE) throw std::runtime_error("cannot open shared writer fixture");
        try { sourceIdentityKey(file.string()); }
        catch (...) { CloseHandle(writer); throw; }
        CloseHandle(writer);
#endif
        fs::remove_all(argv[1]);
        std::cout << "PASS source content read counts and preserved-time overwrite\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
