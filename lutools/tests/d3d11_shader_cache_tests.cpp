#include "gpu/d3d11_shader_cache.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using namespace sony2fuji;

namespace sony2fuji {

// 预热后的 getOrCompile 会直接命中磁盘；压测必须仍走生产覆盖写入路径。
struct ShaderBytecodeCacheTestAccess {
    static void write(const ShaderBytecodeCache& cache, const ShaderCacheKey& key,
                      const std::vector<uint8_t>& bytecode) {
        cache.writeToDisk(key, bytecode, kD3D11ShaderCacheVersion);
    }
};

} // namespace sony2fuji

namespace {

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

struct TempDir {
    std::filesystem::path path;
    TempDir() {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        path = std::filesystem::temp_directory_path() / ("rawlab_shader_cache_test_" + unique);
        std::filesystem::create_directories(path);
    }
    ~TempDir() {
        std::error_code ec;
        std::filesystem::remove_all(path, ec);
    }
};

void inProcessAndCrossProcessCacheHits() {
    TempDir dir;
    const std::string source = "cbuffer Params : register(b0) { float gain; }; [numthreads(16,16,1)] void main() {}";
    const auto key = makeD3D11ShaderCacheKey("RawLab photo shader", source, "main", "cs_5_0", 0x8001);
    const std::vector<uint8_t> fakeDxbc{0x44, 0x58, 0x42, 0x43, 1, 2, 3, 4, 5, 6};

    int compilerInvocations = 0;
    {
        ShaderBytecodeCache cache(dir.path);
        const auto first = cache.getOrCompile(key, [&]() {
            ++compilerInvocations;
            return fakeDxbc;
        });
        require(first == fakeDxbc, "first compile must return bytecode");
        require(compilerInvocations == 1, "first call must compile once");

        const auto second = cache.getOrCompile(key, [&]() {
            ++compilerInvocations;
            return fakeDxbc;
        });
        require(second == fakeDxbc, "in-process cache hit must return identical bytecode");
        require(compilerInvocations == 1, "in-process cache hit must not recompile");
        require(cache.stats().memoryHits == 1, "expected 1 in-memory cache hit");
    }

    // 模拟跨进程重启：新建缓存实例读取同一磁盘目录，不应再次调用编译器。
    {
        ShaderBytecodeCache restarted(dir.path);
        const auto loaded = restarted.getOrCompile(key, [&]() {
            ++compilerInvocations;
            return fakeDxbc;
        });
        require(loaded == fakeDxbc, "cross-process disk cache hit must return identical bytecode");
        require(compilerInvocations == 1, "cross-process disk cache hit must not recompile");
        require(restarted.stats().diskHits == 1, "expected 1 disk cache hit");
    }
}

void keyAndVersionInvalidationAndCorruptionRecovery() {
    TempDir dir;
    const std::string sourceA = "void main() { /* v1 */ }";
    const std::string sourceB = "void main() { /* v2 */ }";
    const auto keyA = makeD3D11ShaderCacheKey("RawLab filters", sourceA, "main", "cs_5_0", 1);
    const auto keyB = makeD3D11ShaderCacheKey("RawLab filters", sourceB, "main", "cs_5_0", 1);
    const auto keyFlags = makeD3D11ShaderCacheKey("RawLab filters", sourceA, "main", "cs_5_0", 2);
    const auto keyV2 = makeD3D11ShaderCacheKey("RawLab filters", sourceA, "main", "cs_5_0", 1, 2);

    require(keyA.id != keyB.id, "source change must change cache key");
    require(keyA.id != keyFlags.id, "compile flags change must change cache key");
    require(keyA.id != keyV2.id, "schema version bump must change cache key");

    const std::vector<uint8_t> dxbcA{0x44, 0x58, 0x42, 0x43, 10, 20, 30};
    const std::vector<uint8_t> dxbcV2{0x44, 0x58, 0x42, 0x43, 40, 50, 60};
    int compiles = 0;

    {
        ShaderBytecodeCache cache(dir.path);
        cache.getOrCompile(keyA, [&]() { ++compiles; return dxbcA; });
        require(compiles == 1, "initial compile expected");

        // 版本号升级必须失效旧缓存。
        const auto v2Out = cache.getOrCompile(keyV2, [&]() { ++compiles; return dxbcV2; }, 2);
        require(v2Out == dxbcV2 && compiles == 2, "version bump must miss and recompile");
    }

    // 破坏磁盘缓存文件字节后，应安全回退重编并覆盖修复。
    const auto blobFile = dir.path / (keyA.id + ".dxbc");
    require(std::filesystem::exists(blobFile), "expected serialized blob file on disk");
    {
        std::fstream corrupt(blobFile, std::ios::binary | std::ios::in | std::ios::out);
        corrupt.seekp(0, std::ios::end);
        const auto sz = static_cast<std::streamoff>(corrupt.tellp());
        require(sz > 4, "serialized blob unexpectedly small");
        corrupt.seekp(sz - 1);
        const char bad = static_cast<char>(0xFF);
        corrupt.write(&bad, 1);
    }

    {
        ShaderBytecodeCache afterCorrupt(dir.path);
        const auto recovered = afterCorrupt.getOrCompile(keyA, [&]() { ++compiles; return dxbcA; });
        require(recovered == dxbcA && compiles == 3, "corrupt disk blob must recompile cleanly");
    }
    {
        ShaderBytecodeCache afterRepair(dir.path);
        const auto repaired = afterRepair.getOrCompile(keyA, [&]() { ++compiles; return dxbcA; });
        require(repaired == dxbcA && compiles == 3, "repaired disk blob must hit on next restart");
    }
}

#if defined(_WIN32)
void diskReadersShareAtomicReplacementHandles() {
    TempDir dir;
    const auto key = makeD3D11ShaderCacheKey("RawLab replacement", "void main() {}", "main", "cs_5_0", 0);
    const std::vector<uint8_t> expected{0x44, 0x58, 0x42, 0x43, 7, 8, 9};
    ShaderBytecodeCache seed(dir.path);
    seed.getOrCompile(key, [&]() { return expected; });

    // MoveFileEx 替换期间持有 DELETE 访问；读端也必须允许该共享模式。
    const HANDLE replacement = CreateFileW((dir.path / (key.id + ".dxbc")).c_str(), DELETE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    require(replacement != INVALID_HANDLE_VALUE, "failed to open atomic replacement fixture handle");
    ShaderBytecodeCache reader(dir.path);
    int fallbackCompiles = 0;
    const auto loaded = reader.getOrCompile(key, [&]() {
        ++fallbackCompiles;
        return expected;
    });
    CloseHandle(replacement);
    require(fallbackCompiles == 0 && reader.stats().compiles == 0 && reader.stats().diskHits == 1 &&
            loaded == expected,
        "disk reader must share the DELETE handle used by atomic replacement without recompiling");
}
#endif

void concurrentWritersAndReadersNeverObserveBrokenBlob() {
    TempDir dir;
    const std::string source = "void main() { /* concurrent */ }";
    std::vector<uint8_t> expected(64 * 1024);
    for (size_t i = 0; i < expected.size(); ++i) expected[i] = static_cast<uint8_t>((i * 131 + 7) & 0xFF);

    constexpr int kRounds = 400;
    std::vector<ShaderCacheKey> hotKeys;
    const auto seedTime = std::filesystem::file_time_type::clock::now() - std::chrono::hours(24);
    for (int i = 0; i < 4; ++i) {
        hotKeys.push_back(makeD3D11ShaderCacheKey(
            "RawLab concurrent", source + std::to_string(i), "main", "cs_5_0", 0x8001));
        const auto serialized = serializeShaderBlob(hotKeys.back(), expected);
        std::ofstream out(dir.path / (hotKeys.back().id + ".dxbc"), std::ios::binary);
        out.write(reinterpret_cast<const char*>(serialized.data()),
                  static_cast<std::streamsize>(serialized.size()));
        out.close();
        require(!out.fail(), "failed to prewrite hot-key disk fixture");
        std::filesystem::last_write_time(dir.path / (hotKeys.back().id + ".dxbc"), seedTime);
    }

    std::atomic<int> fallbackCompiles{0}, brokenDiskReads{0}, writeAttempts{0};
    std::atomic<bool> start{false};
    std::atomic<bool> readerDone{false};

    auto writerFn = [&]() {
        ShaderBytecodeCache writer(dir.path);
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        do {
            for (const auto& key : hotKeys) {
                ShaderBytecodeCacheTestAccess::write(writer, key, expected);
                writeAttempts.fetch_add(1, std::memory_order_release);
            }
        } while (!readerDone.load(std::memory_order_acquire));
    };

    auto readerFn = [&]() {
        while (writeAttempts.load(std::memory_order_acquire) == 0) std::this_thread::yield();
        for (int round = 0; round < kRounds; ++round) {
            const auto& key = hotKeys[static_cast<size_t>(round) % hotKeys.size()];
            ShaderBytecodeCache reader(dir.path);
            const auto blob = reader.getOrCompile(key, [&]() {
                fallbackCompiles.fetch_add(1, std::memory_order_relaxed);
                return expected;
            });
            const auto stats = reader.stats();
            if (stats.compiles != 0 || stats.diskHits != 1 || blob != expected) {
                brokenDiskReads.fetch_add(1, std::memory_order_relaxed);
            }
        }
        readerDone.store(true, std::memory_order_release);
    };

    std::thread w1(writerFn), w2(writerFn), w3(writerFn), r1(readerFn);
    start.store(true, std::memory_order_release);
    w1.join();
    w2.join();
    w3.join();
    r1.join();
    std::cout << "Concurrent disk reads: fallbackCompiles=" << fallbackCompiles.load()
              << ", brokenDiskReads=" << brokenDiskReads.load() << "/" << kRounds
              << ", writeAttempts=" << writeAttempts.load() << '\n';
    require(fallbackCompiles.load() == 0 && brokenDiskReads.load() == 0,
        "concurrent hot-key disk read must hit intact bytecode without fallback compilation");
    for (const auto& entry : std::filesystem::directory_iterator(dir.path)) {
        require(entry.path().filename().string().find(".tmp") == std::string::npos,
            "concurrent writers left a temporary shader cache file after join");
    }
    // 同字节的预写夹具不能证明覆盖成功；旧时间戳必须被每个热键的新文件替换。
    for (const auto& key : hotKeys) {
        require(std::filesystem::last_write_time(dir.path / (key.id + ".dxbc")) >
                    seedTime + std::chrono::hours(1),
            "concurrent writers did not replace every prewritten hot-key blob");
    }
}

} // namespace

int main() {
    try {
        inProcessAndCrossProcessCacheHits();
        keyAndVersionInvalidationAndCorruptionRecovery();
#if defined(_WIN32)
        diskReadersShareAtomicReplacementHandles();
#endif
        concurrentWritersAndReadersNeverObserveBrokenBlob();
        std::cout << "PASS: d3d11_shader_cache\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
