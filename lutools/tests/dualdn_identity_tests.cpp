// 只在此测试翻译单元包裹真实文件摘要，生产代码不增加计数器或替代读路径。
#define sha256File realSha256File
#include "../src/ai/model_sha256.cpp"
#undef sha256File
#include "ai/dualdn_cache.h"
#include <chrono>
#include <fstream>
#include <future>
#include <iostream>
#include <thread>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#endif

namespace {
size_t fileReads = 0;
std::function<void()> onSha256File;
}
namespace sony2fuji::ai {
std::string sha256File(const std::string& path) {
    ++fileReads;
    if (onSha256File) onSha256File();
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
            struct FallbackGuard {
                FallbackGuard() { forceMetadataFallbackForTests(true); }
                ~FallbackGuard() { onSha256File = {}; forceMetadataFallbackForTests(false); }
            } guard;
            const auto before = fileReads;
            std::vector<fs::path> fallbackFiles;
            std::vector<std::string> fallbackKeys;
            for (int i = 0; i < 3; ++i) {
                const auto model = fs::path(argv[1]) / ("fallback-model-" + std::to_string(i));
                { std::ofstream(model) << std::string(64 + i, char('a' + i)); }
                fallbackFiles.push_back(model);
                fallbackKeys.push_back(sourceMetadataKey(model.string()));
            }
            if (fileReads != before + 3)
                throw std::runtime_error("metadata fallback must hash each file exactly once");
            for (int frame = 0; frame < 5; ++frame)
                for (size_t i = 0; i < fallbackFiles.size(); ++i)
                    if (sourceMetadataKey(fallbackFiles[i].string()) != fallbackKeys[i])
                        throw std::runtime_error("metadata fallback changed the key for an unchanged file");
            if (fileReads != before + 3)
                throw std::runtime_error("metadata fallback reread whole files for every package stamp");
            const auto preservedMtime = fs::last_write_time(fallbackFiles[0]);
            std::this_thread::sleep_for(std::chrono::milliseconds(30));
            {
                std::fstream stream(fallbackFiles[0], std::ios::in | std::ios::out | std::ios::binary);
                stream.write(std::string(64, 'x').data(), 64);
            }
            fs::last_write_time(fallbackFiles[0], preservedMtime);
            const auto sameSizeChanged = sourceMetadataKey(fallbackFiles[0].string());
            if (sameSizeChanged == fallbackKeys[0] || fileReads != before + 4 ||
                sourceMetadataKey(fallbackFiles[0].string()) != sameSizeChanged || fileReads != before + 4)
                throw std::runtime_error("same-size preserved-mtime overwrite failed in metadata fallback");
            { std::ofstream(fallbackFiles[1]) << std::string(66, 'z'); }
            const auto changed = sourceMetadataKey(fallbackFiles[1].string());
            if (changed == fallbackKeys[1] || fileReads != before + 5)
                throw std::runtime_error("metadata fallback did not rehash exactly once after the change");
            const auto blocker = fs::path(argv[1]) / "fallback-blocker", raced = fs::path(argv[1]) / "fallback-raced";
            { std::ofstream(blocker) << "block"; std::ofstream(raced) << "v1"; }
            std::promise<void> entered, release;
            auto enteredFuture = entered.get_future();
            auto releaseFuture = release.get_future().share();
            onSha256File = [&] { onSha256File = {}; entered.set_value(); releaseFuture.wait(); };
            auto first = std::async(std::launch::async, [&] { return sourceMetadataKey(blocker.string()); });
            enteredFuture.wait();
            auto second = std::async(std::launch::async, [&] { return sourceMetadataKey(raced.string()); });
            std::this_thread::sleep_for(std::chrono::milliseconds(15));
            { std::ofstream(raced) << "v22"; }
            release.set_value();
            const auto firstKey = first.get();
            const auto racedKey = second.get();
            const auto readsAfterRace = fileReads;
            if (firstKey.empty() || sourceMetadataKey(raced.string()) != racedKey || fileReads != readsAfterRace)
                throw std::runtime_error("concurrent metadata fallback returned or cached a stale chimeric key");
            const auto targetA = fs::path(argv[1]) / "sym-a", targetB = fs::path(argv[1]) / "sym-b", link = fs::path(argv[1]) / "sym-link";
            { std::ofstream(targetA) << "aaa"; std::ofstream(targetB) << "bbbb"; }
            std::error_code linkError;
            fs::create_symlink(targetA, link, linkError);
            if (!linkError) {
                // 退路槽以 canonical 路径为键：先取 targetA 的干净基准摘要（此时槽未受污染），再用满 LRU filler
                // 逐出该槽，link 查询才会重新整文件哈希，切链钩子获得真实的哈希中途污染窗口。
                const auto readsBeforeLink = fileReads;
                const auto clean = sourceMetadataKey(targetA.string());
                if (fileReads != readsBeforeLink + 1)
                    throw std::runtime_error("symlink fixture must hash the clean target exactly once");
                for (int i = 0; i < 130; ++i) {
                    const auto filler = fs::path(argv[1]) / ("link-evict-" + std::to_string(i));
                    { std::ofstream(filler) << i; }
                    sourceMetadataKey(filler.string());
                }
                onSha256File = [&] { onSha256File = {}; fs::remove(link); fs::create_symlink(targetB, link); };
                const auto viaLink = sourceMetadataKey(link.string());
                const auto readsAfterLink = fileReads;
                if (viaLink != clean)
                    throw std::runtime_error("link hashing must follow the canonical target, not the live link path");
                if (sourceMetadataKey(targetA.string()) != clean || fileReads != readsAfterLink ||
                    sourceMetadataKey(link.string()) == clean)
                    throw std::runtime_error("symlink target switch poisoned canonical metadata fallback slot");
            }
            const auto oldest = fs::path(argv[1]) / "fallback-oldest", torn = fs::path(argv[1]) / "fallback-torn";
            { std::ofstream(oldest) << "keep"; std::ofstream(torn) << "before"; }
            const auto oldestKey = sourceMetadataKey(oldest.string());
            for (int i = 0; i < 127; ++i) {
                const auto filler = fs::path(argv[1]) / ("fallback-lru-" + std::to_string(i));
                { std::ofstream(filler) << i; }
                sourceMetadataKey(filler.string());
            }
            onSha256File = [&] { onSha256File = {}; std::ofstream(torn) << "written-during-hash"; };
            sourceMetadataKey(torn.string());
            const auto readsBeforeOldest = fileReads;
            if (sourceMetadataKey(oldest.string()) != oldestKey || fileReads != readsBeforeOldest)
                throw std::runtime_error("mid-hash modification inserted a torn entry into metadata fallback LRU");
            const auto cleanTorn = sourceMetadataKey(torn.string());
            if (fileReads != readsBeforeOldest + 1 || sourceMetadataKey(torn.string()) != cleanTorn || fileReads != readsBeforeOldest + 1)
                throw std::runtime_error("metadata fallback did not converge after mid-hash modification");
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
