#include "ai/dualdn_cache.h"
#include "ai/model_package.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#endif

using namespace sony2fuji;
using namespace sony2fuji::ai;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }

int main(int argc, char** argv) {
    try {
        require(argc == 2, "requires fresh temporary directory");
        const auto root = std::filesystem::u8path(argv[1]);
        require(std::filesystem::create_directory(root), "temporary directory already exists");
        const auto raw = root / "source.raw";
        { std::ofstream(raw) << "immutable RAW fixture"; }
        const auto key = rawCacheKey(raw.string(), std::string(64, 'a'), 0);
        const auto originalStamp = std::filesystem::last_write_time(raw);
        const auto replacement = root / "replacement.raw";
        { std::ofstream(replacement) << "immutable RAW fixture"; }
        std::filesystem::last_write_time(replacement, originalStamp);
#ifdef _WIN32
        require(MoveFileExW(replacement.c_str(), raw.c_str(), MOVEFILE_REPLACE_EXISTING) != 0,
                "failed to replace RAW fixture atomically");
#else
        std::filesystem::rename(replacement, raw);
#endif
        require(rawCacheKey(raw.string(), std::string(64, 'a'), 0) != key,
                "atomic replacement with preserved size/time reused stale AI data");
        const auto beforeOverwrite = sourceIdentityKey(raw.string());
        { std::fstream stream(raw, std::ios::in | std::ios::out | std::ios::binary); stream.put('I'); }
        std::filesystem::last_write_time(raw, originalStamp);
        require(sourceIdentityKey(raw.string()) != beforeOverwrite,
                "in-place replacement with preserved size/time reused stale AI data");
        RAWProcessOptions options;
        const auto rgbKey = rgbCacheKey(key, options);
        const auto sceneKey = sceneRGBCacheKey(key, options);
        options.lensCorrection.distortion = true;
        require(sceneRGBCacheKey(key, options) != sceneKey && rgbCacheKey(key, options) == rgbKey,
                "lens settings did not isolate scene RGB cache");
        options.lensCorrection.distortion = false;
        options.exposure = 2; options.brightness = 1.2f; options.applyBaselineExposure = false;
        require(rgbCacheKey(key, options) == rgbKey, "exposure invalidated AI cache");
        require(sceneRGBCacheKey(key, options) == sceneKey, "exposure invalidated scene RGB cache");
        options.useTemperatureWhiteBalance = true; options.temperature = 4000;
        require(rgbCacheKey(key, options) != rgbKey, "white balance did not invalidate RGB cache");
        require(rawCacheKey(raw.string(), std::string(64, 'b'), 0) != key, "model change did not invalidate RAW cache");
        auto originalTime = std::filesystem::last_write_time(raw);
        { std::ofstream(raw, std::ios::app) << "changed"; }
        std::filesystem::last_write_time(raw, originalTime);
        require(rawCacheKey(raw.string(), std::string(64, 'a'), 0) != key, "file size change did not invalidate RAW cache");
        DenoiseCache cache((root / "cache").string());
        std::vector<float> values{-.2f, 0, .1f, .4f, .8f, 1.2f};
        cache.store(key, CacheKind::Raw, 3, 2, values.data(), values.size());
        const auto restored = cache.load(key, CacheKind::Raw, 3, 2);
        require(restored && restored->values == values, "cache did not preserve finite float32 values");
        std::string producer = "stale";
        require(cache.load(key, CacheKind::Raw, 3, 2, {}, &producer) && producer.empty(),
                "legacy cache invented a producer");
        cache.store(key, CacheKind::Raw, 3, 2, values.data(), values.size(), {}, "CoreML");
        require(cache.load(key, CacheKind::Raw, 3, 2, {}, &producer) && producer == "CoreML",
                "cache did not retain actual producer");
        require(!cache.load(key, CacheKind::Raw, 2, 3), "wrong geometry accepted");
        const auto file = root / "cache" / (key + ".rawcache");
        { std::fstream stream(file, std::ios::in | std::ios::out | std::ios::binary); stream.seekp(-1, std::ios::end); stream.put('\0'); }
        require(!cache.load(key, CacheKind::Raw, 3, 2), "corrupt cache accepted");
        require(!cache.load(key, CacheKind::Raw, 3, 2, {}, &producer) && producer.empty(),
                "failed cache load retained a stale producer");
        cache.store(key, CacheKind::Raw, 3, 2, values.data(), values.size());
        require(cache.load(key, CacheKind::Raw, 3, 2)->values == values, "corrupt cache could not be repaired");
        const auto rawPayload = sha256Bytes(values.data(), values.size() * sizeof(float));
        cache.store(sceneKey, CacheKind::SceneRGB, 2, 1, values.data(), values.size(), {}, "CoreML");
        const auto scene = cache.load(sceneKey, CacheKind::SceneRGB, 0, 0);
        require(scene && scene->width == 2 && scene->height == 1 && scene->values == values,
                "scene RGB cache lost canvas or exact values");
        const auto sceneFile = root/"cache"/(sceneKey+".scenecache");
        {
            std::fstream stream(sceneFile,std::ios::in|std::ios::out|std::ios::binary);
            uint32_t length = 0; stream.read(reinterpret_cast<char*>(&length),4);
            std::string header(length,'\0'); stream.read(header.data(),length);
            header.replace(header.find("\"width\":2"),9,"\"width\":1");
            header.replace(header.find("\"height\":1"),10,"\"height\":2");
            stream.seekp(4); stream.write(header.data(),header.size());
        }
        require(!cache.load(sceneKey,CacheKind::SceneRGB,0,0),"same-size scene header corruption was reused");
        cache.store(sceneKey,CacheKind::SceneRGB,2,1,values.data(),values.size());
        cache.store(rgbKey, CacheKind::RGB, 1, 2, values.data(), values.size(), rawPayload);
        require(cache.load(rgbKey, CacheKind::RGB, 1, 2, rawPayload).has_value(), "matching RAW dependency rejected");
        auto rebuiltRaw = values; rebuiltRaw[0] += .01f;
        const auto rebuiltPayload = sha256Bytes(rebuiltRaw.data(), rebuiltRaw.size() * sizeof(float));
        require(!cache.load(rgbKey, CacheKind::RGB, 1, 2, rebuiltPayload),
                "RGB correction from a different RAW payload was reused");
        cache.store(key, CacheKind::Raw, 3, 2, rebuiltRaw.data(), rebuiltRaw.size());
        require(cache.load(key, CacheKind::Raw, 3, 2)->values == rebuiltRaw,
                "replacement RAW payload was silently discarded");
        { std::ofstream(root / "cache" / "keep-me.rawcache") << "not owned by the cache"; }
        cache.prune(0, {rgbKey});
        require(!cache.load(sceneKey, CacheKind::SceneRGB, 0, 0), "scene RGB cache was never pruned");
        require(!cache.load(key, CacheKind::Raw, 3, 2) && cache.load(rgbKey, CacheKind::RGB, 1, 2, rawPayload), "pruning removed protected entry");
        require(std::filesystem::exists(raw) && std::filesystem::exists(root / "cache" / "keep-me.rawcache"), "pruning removed unrelated files");
        std::filesystem::remove_all(root);
        std::cout << "PASS AI cache identity, exact floats, corruption recovery and scoped eviction\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
