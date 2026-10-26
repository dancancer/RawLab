#define sha256File realSha256File
#include "../src/ai/model_sha256.cpp"
#undef sha256File
#include "ai/ai_session.h"
#include <iostream>

namespace { size_t fileReads = 0; }
namespace sony2fuji::ai {
std::string sha256File(const std::string& path) { ++fileReads; return realSha256File(path); }
}

int main(int argc, char** argv) {
    using namespace sony2fuji;
    using namespace sony2fuji::ai;
    namespace fs = std::filesystem;
    try {
        if (argc != 3 || !fs::create_directory(argv[2])) throw std::runtime_error("requires model and fresh cache directory");
        auto require = [](bool value, const char* reason) { if (!value) throw std::runtime_error(reason); };
        const fs::path source = fs::path(argv[2]) / "source.raw";
        { std::ofstream(source) << "source identity fixture"; }
        fileReads = 0;
        const auto package = loadModelPackage(argv[1]);
        const auto validationReads = fileReads;
        std::string runtime = "test-gpu-runtime-a";
        AISession session([&](Backend) { return runtime; });
        session.enabled = true;
        session.configure(argv[1], argv[2], Backend::CoreML);
        RAWProcessOptions options;
        fileReads = 0;
        const auto initialKey = session.renderKey(source.string(), options);
        require(fileReads == validationReads + 1, "model content read outside package validation");
        fileReads = 0;
        require(session.renderKey(source.string(), options) == initialKey && fileReads == 0,
            "render cache hit reread model or source content");
        auto storeResult = [&] {
            const auto identity = package.digest + ":" + runtime;
            const auto digest = sha256Bytes(identity.data(), identity.size());
            const auto raw = rawCacheKey(source.string(), digest, int(Backend::CoreML));
            const float values[] = {.1f, .2f, .3f};
            DenoiseCache(argv[2]).store(sceneRGBCacheKey(raw, options), CacheKind::SceneRGB, 1, 1,
                values, 3, {}, "test-gpu");
        };
        storeResult();
        const auto& loaded = session.result(source.string(), options, nullptr);
        require(loaded.isSceneRGB(), "complete GPU result was not loaded");
        session.enabled = false;
        session.configure(argv[1], argv[2], Backend::CoreML);
        require(loaded.scene.values.empty() && loaded.bayer.normalizedMosaic.empty(), "disabled AI retained full result memory");
        session.enabled = true;
        runtime = "test-gpu-runtime-b";
        storeResult();
        const auto changedSource = fs::path(argv[2]) / "second.raw";
        { std::ofstream(changedSource) << "second source identity fixture"; }
        const auto identity = package.digest + ":" + runtime;
        const auto raw = rawCacheKey(changedSource.string(), sha256Bytes(identity.data(), identity.size()), int(Backend::CoreML));
        const float result[] = {.3f, .2f, .1f};
        DenoiseCache(argv[2]).store(sceneRGBCacheKey(raw, options), CacheKind::SceneRGB, 1, 1, result, 3, {}, "test-gpu");
        require(session.result(changedSource.string(), options, nullptr).scene.values[0] == .3f,
            "render session did not refresh changed GPU runtime identity on miss");
        fs::remove_all(argv[2]);
        std::cout << "PASS model read counts, disabled AI release and runtime identity refresh\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
