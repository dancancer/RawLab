#include "gpu/d3d11_shader_cache.h"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using namespace sony2fuji;

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

} // namespace

int main() {
    try {
        inProcessAndCrossProcessCacheHits();
        keyAndVersionInvalidationAndCorruptionRecovery();
        std::cout << "PASS: d3d11_shader_cache\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
