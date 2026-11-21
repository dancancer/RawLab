#include "ai/dualdn_cache.h"
#include "ai/model_package.h"
#include "core/sha256.h"
#include <nlohmann/json.hpp>
#include <array>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#include <psapi.h>
#else
#include <sys/resource.h>
#endif

#if defined(__APPLE__)
#include <malloc/malloc.h>
#endif

namespace {

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

uint64_t peakRssBytes() {
#if defined(_WIN32)
    PROCESS_MEMORY_COUNTERS pmc{};
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) {
        throw std::runtime_error("Cannot read peak working set");
    }
    return static_cast<uint64_t>(pmc.PeakWorkingSetSize);
#elif defined(__APPLE__)
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) != 0) throw std::runtime_error("Cannot read peak RSS");
    return static_cast<uint64_t>(usage.ru_maxrss);
#else
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) != 0) throw std::runtime_error("Cannot read peak RSS");
    return static_cast<uint64_t>(usage.ru_maxrss) * 1024ULL;
#endif
}

#if defined(__APPLE__)
uint64_t appleHeapInUseBytes() {
    malloc_statistics_t stats{};
    malloc_zone_statistics(nullptr, &stats);
    return static_cast<uint64_t>(stats.size_in_use);
}
#endif

// Stream-writes a 4096x4096 CacheKind::RGB fixture directly in CHW order so the writer
// itself does not raise process peak RSS before the verify/loadRGBCorrection gates run.
std::string writeStreamedRgbCache(const std::filesystem::path& cacheDir,
                                  const std::string& key,
                                  int width,
                                  int height,
                                  const std::string& dependency,
                                  const std::string& producer) {
    const size_t pixels = static_cast<size_t>(width) * static_cast<size_t>(height);
    constexpr size_t kChunkFloats = 65536;
    std::vector<float> chunk(std::min(pixels, kChunkFloats));
    sony2fuji::hash::Sha256 hasher;
    for (int plane = 0; plane < 3; ++plane) {
        size_t offset = 0;
        while (offset < pixels) {
            const size_t n = std::min(chunk.size(), pixels - offset);
            for (size_t i = 0; i < n; ++i) {
                chunk[i] = static_cast<float>(plane) + 0.0001f * static_cast<float>((offset + i) % 1024);
            }
            hasher.update(chunk.data(), n * sizeof(float));
            offset += n;
        }
    }
    const std::string payloadDigest = hasher.finish();
    nlohmann::json header = {
        {"format", "rawlab-dualdn-cache-v1"},
        {"key", key},
        {"width", width},
        {"height", height},
        {"channels", 3},
        {"sha256", payloadDigest},
        {"dependency", dependency},
        {"producer", producer}
    };
    const std::string headerRaw = header.dump();
    header["header_sha256"] = sony2fuji::hash::sha256Bytes(headerRaw.data(), headerRaw.size());
    const std::string text = header.dump();
    const uint32_t length = static_cast<uint32_t>(text.size());

    std::filesystem::create_directories(cacheDir);
    const auto target = cacheDir / (key + ".rgbcache");
    std::ofstream output(target, std::ios::binary);
    output.write(reinterpret_cast<const char*>(&length), sizeof(length));
    output.write(text.data(), text.size());
    for (int plane = 0; plane < 3; ++plane) {
        size_t offset = 0;
        while (offset < pixels) {
            const size_t n = std::min(chunk.size(), pixels - offset);
            for (size_t i = 0; i < n; ++i) {
                chunk[i] = static_cast<float>(plane) + 0.0001f * static_cast<float>((offset + i) % 1024);
            }
            output.write(reinterpret_cast<const char*>(chunk.data()), n * sizeof(float));
            offset += n;
        }
    }
    output.close();
    require(bool(output), "failed to write streamed 16.77MP RGB cache fixture");
    return payloadDigest;
}

} // namespace

int main(int argc, char** argv) {
    namespace fs = std::filesystem;
    fs::path root;
    bool created = false;
    try {
        require(argc == 2, "requires temporary directory path");
        root = fs::u8path(argv[1]);
        fs::remove_all(root);
        require(fs::create_directories(root), "cannot create temporary directory");
        created = true;

        constexpr int kWidth = 4096;
        constexpr int kHeight = 4096;
        constexpr size_t kPixels = static_cast<size_t>(kWidth) * static_cast<size_t>(kHeight);
        constexpr uint64_t kRgbBytes = kPixels * sizeof(sony2fuji::RGB); // 192 MiB
        constexpr uint64_t kMiB = 1024ULL * 1024ULL;

        const std::string depDigest = std::string(64, '1');
        const std::string rgbKey = std::string(64, '2');
        const std::string expectedDigest = writeStreamedRgbCache(root, rgbKey, kWidth, kHeight, depDigest, "CoreML");

        sony2fuji::ai::DenoiseCache cache(root.u8string());

        // Gate 1: streaming verify() must allocate zero full-image tensors (peak RSS delta < 32 MiB).
        const uint64_t baselineRss = peakRssBytes();
#if defined(__APPLE__)
        const uint64_t baselineHeap = appleHeapInUseBytes();
#endif
        std::string producer, payloadDigest;
        require(cache.verify(rgbKey, sony2fuji::ai::CacheKind::RGB, kWidth, kHeight, depDigest, &producer, &payloadDigest),
                "streaming verify failed on valid 16.77MP RGB cache");
        require(producer == "CoreML" && payloadDigest == expectedDigest,
                "streaming verify returned wrong producer or digest");

        const uint64_t afterVerifyRss = peakRssBytes();
        const uint64_t verifyRssDelta = afterVerifyRss > baselineRss ? (afterVerifyRss - baselineRss) : 0;
        std::cout << "16.77MP verify: baseline_rss=" << baselineRss
                  << " after_verify_rss=" << afterVerifyRss
                  << " rss_delta_mib=" << (double(verifyRssDelta) / double(kMiB)) << '\n';
        require(verifyRssDelta < 32 * kMiB,
                "DenoiseCache::verify exceeded 32 MiB peak RSS delta (full-tensor load regression)");
#if defined(__APPLE__)
        const uint64_t afterVerifyHeap = appleHeapInUseBytes();
        const uint64_t verifyHeapDelta = afterVerifyHeap > baselineHeap ? (afterVerifyHeap - baselineHeap) : 0;
        std::cout << "16.77MP verify apple_heap_delta_mib=" << (double(verifyHeapDelta) / double(kMiB)) << '\n';
        require(verifyHeapDelta < 16 * kMiB,
                "DenoiseCache::verify leaked or allocated large heap buffers");
#endif

        // Gate 2: loadRGBCorrection() must allocate only 1x 192 MiB vector<RGB> (not 2x = 384 MiB).
        const uint64_t preLoadRss = peakRssBytes();
        {
            std::string loadProducer, loadDigest;
            auto correction = cache.loadRGBCorrection(rgbKey, kWidth, kHeight, depDigest, &loadProducer, &loadDigest);
            require(correction && correction->size() == kPixels &&
                    loadProducer == "CoreML" && loadDigest == expectedDigest,
                    "loadRGBCorrection failed on valid 16.77MP RGB cache");
            for (size_t idx : {size_t(0), size_t(12345), kPixels - 1}) {
                const float base = 0.0001f * static_cast<float>(idx % 1024);
                const auto& p = (*correction)[idx];
                require(p.r == base && p.g == 1.0f + base && p.b == 2.0f + base,
                        "loadRGBCorrection pixel values diverged from CHW planes");
            }
            const uint64_t postLoadRss = peakRssBytes();
            const uint64_t loadRssDelta = postLoadRss > preLoadRss ? (postLoadRss - preLoadRss) : 0;
            std::cout << "16.77MP loadRGBCorrection: pre_rss=" << preLoadRss
                      << " post_rss=" << postLoadRss
                      << " rss_delta_mib=" << (double(loadRssDelta) / double(kMiB))
                      << " budget_mib=" << (double(kRgbBytes + 48 * kMiB) / double(kMiB)) << '\n';
            require(loadRssDelta <= kRgbBytes + 48 * kMiB,
                    "loadRGBCorrection exceeded 192 MiB + 48 MiB peak RSS budget (double allocation regression)");
#if defined(__APPLE__)
            const uint64_t postLoadHeap = appleHeapInUseBytes();
            const uint64_t loadHeapDelta = postLoadHeap > baselineHeap ? (postLoadHeap - baselineHeap) : 0;
            std::cout << "16.77MP loadRGBCorrection apple_heap_delta_mib="
                      << (double(loadHeapDelta) / double(kMiB)) << '\n';
            require(loadHeapDelta <= kRgbBytes + 16 * kMiB,
                    "loadRGBCorrection exceeded Apple heap size_in_use budget");
#endif
        }
#if defined(__APPLE__)
        const uint64_t freedHeap = appleHeapInUseBytes();
        const uint64_t residualHeap = freedHeap > baselineHeap ? (freedHeap - baselineHeap) : 0;
        std::cout << "16.77MP after drop apple_heap_residual_mib=" << (double(residualHeap) / double(kMiB)) << '\n';
        require(residualHeap < 4 * kMiB, "16.77MP correction buffer stayed resident after scope exit");
#endif

        fs::remove_all(root);
        std::cout << "PASS 16.77MP streaming DenoiseCache verify & single-allocation loadRGBCorrection\n";
        return 0;
    } catch (const std::exception& error) {
        if (created) {
            std::error_code ignored;
            fs::remove_all(root, ignored);
        }
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
