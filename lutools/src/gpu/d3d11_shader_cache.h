#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#if defined(_WIN32)
#include <process.h>
#else
#include <unistd.h>
#endif

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <iostream>
#include <stdexcept>
#endif

namespace sony2fuji {

inline constexpr uint32_t kD3D11ShaderCacheVersion = 1;

namespace detail {

inline uint64_t fnv1a64(std::string_view data, uint64_t seed = 14695981039346656037ULL) {
    uint64_t h = seed;
    for (unsigned char c : data) {
        h ^= c;
        h *= 1099511628211ULL;
    }
    return h;
}

inline uint64_t fnv1a64Bytes(const uint8_t* data, size_t size, uint64_t seed = 14695981039346656037ULL) {
    return fnv1a64(std::string_view(reinterpret_cast<const char*>(data), size), seed);
}

inline std::string hex64(uint64_t v) {
    static constexpr char kHex[] = "0123456789abcdef";
    std::string out(16, '0');
    for (int i = 15; i >= 0; --i) {
        out[static_cast<size_t>(i)] = kHex[v & 0xF];
        v >>= 4;
    }
    return out;
}

struct ShaderBlobHeader {
    char magic[8];
    uint32_t version;
    uint32_t flags;
    uint64_t sourceLength;
    uint64_t hash1;
    uint64_t hash2;
    uint64_t bytecodeSize;
    uint64_t payloadChecksum;
};

static_assert(sizeof(ShaderBlobHeader) == 56, "ShaderBlobHeader must stay packed without tail padding");

} // namespace detail

struct ShaderCacheKey {
    std::string id;
    uint64_t hash1 = 0;
    uint64_t hash2 = 0;
    uint64_t sourceLength = 0;
    uint32_t flags = 0;
};

inline ShaderCacheKey makeD3D11ShaderCacheKey(
    std::string_view sourceName,
    std::string_view source,
    std::string_view entryPoint,
    std::string_view target,
    uint32_t flags,
    uint32_t version = kD3D11ShaderCacheVersion) {
    auto mix = [&](uint64_t seed) {
        uint64_t h = seed;
        auto feed = [&](std::string_view part) {
            h = detail::fnv1a64(part, h);
            h ^= 0xff;
            h *= 1099511628211ULL;
        };
        feed(std::string_view(reinterpret_cast<const char*>(&version), sizeof(version)));
        feed(sourceName);
        feed(entryPoint);
        feed(target);
        feed(std::string_view(reinterpret_cast<const char*>(&flags), sizeof(flags)));
        feed(source);
        return h;
    };
    const uint64_t h1 = mix(14695981039346656037ULL);
    const uint64_t h2 = mix(0x9e3779b97f4a7c15ULL);
    ShaderCacheKey key;
    key.hash1 = h1;
    key.hash2 = h2;
    key.sourceLength = static_cast<uint64_t>(source.size());
    key.flags = flags;
    key.id = "v" + std::to_string(version) + "_" + detail::hex64(h1) + "_" + detail::hex64(h2);
    return key;
}

inline std::vector<uint8_t> serializeShaderBlob(const ShaderCacheKey& key, const std::vector<uint8_t>& bytecode,
                                                uint32_t version = kD3D11ShaderCacheVersion) {
    detail::ShaderBlobHeader header{};
    std::memcpy(header.magic, "RLDXBC01", 8);
    header.version = version;
    header.flags = key.flags;
    header.sourceLength = key.sourceLength;
    header.hash1 = key.hash1;
    header.hash2 = key.hash2;
    header.bytecodeSize = static_cast<uint64_t>(bytecode.size());
    header.payloadChecksum = detail::fnv1a64Bytes(bytecode.data(), bytecode.size());
    std::vector<uint8_t> out(sizeof(header) + bytecode.size());
    std::memcpy(out.data(), &header, sizeof(header));
    if (!bytecode.empty()) {
        std::memcpy(out.data() + sizeof(header), bytecode.data(), bytecode.size());
    }
    return out;
}

inline bool deserializeShaderBlob(const ShaderCacheKey& key, const std::vector<uint8_t>& raw,
                                  std::vector<uint8_t>& bytecode,
                                  uint32_t version = kD3D11ShaderCacheVersion) {
    if (raw.size() <= sizeof(detail::ShaderBlobHeader)) return false;
    detail::ShaderBlobHeader header{};
    std::memcpy(&header, raw.data(), sizeof(header));
    if (std::memcmp(header.magic, "RLDXBC01", 8) != 0) return false;
    if (header.version != version || header.flags != key.flags ||
        header.sourceLength != key.sourceLength ||
        header.hash1 != key.hash1 || header.hash2 != key.hash2) {
        return false;
    }
    const size_t payloadBytes = raw.size() - sizeof(header);
    if (header.bytecodeSize == 0 || header.bytecodeSize != payloadBytes) return false;
    const uint8_t* payload = raw.data() + sizeof(header);
    if (detail::fnv1a64Bytes(payload, payloadBytes) != header.payloadChecksum) return false;
    bytecode.assign(payload, payload + payloadBytes);
    return true;
}

class ShaderBytecodeCache {
public:
    struct Stats {
        size_t memoryHits = 0;
        size_t diskHits = 0;
        size_t compiles = 0;
    };

    explicit ShaderBytecodeCache(std::filesystem::path diskDirectory = {})
        : diskDirectory_(std::move(diskDirectory)) {}

    template <class CompileFn>
    std::vector<uint8_t> getOrCompile(const ShaderCacheKey& key, CompileFn&& compile,
                                      uint32_t version = kD3D11ShaderCacheVersion) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto it = memory_.find(key.id);
            if (it != memory_.end()) {
                ++stats_.memoryHits;
                return it->second;
            }
        }

        if (!diskDirectory_.empty()) {
            std::vector<uint8_t> loaded;
            if (readFromDisk(key, loaded, version)) {
                std::lock_guard<std::mutex> lock(mutex_);
                auto [it, inserted] = memory_.emplace(key.id, std::move(loaded));
                if (inserted) ++stats_.diskHits;
                else ++stats_.memoryHits;
                return it->second;
            }
        }

        std::vector<uint8_t> compiled = compile();
        if (!compiled.empty() && !diskDirectory_.empty()) {
            writeToDisk(key, compiled, version);
        }
        std::lock_guard<std::mutex> lock(mutex_);
        auto [it, inserted] = memory_.emplace(key.id, std::move(compiled));
        if (inserted) ++stats_.compiles;
        return it->second;
    }

    Stats stats() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return stats_;
    }

    void clearMemoryForTesting() {
        std::lock_guard<std::mutex> lock(mutex_);
        memory_.clear();
    }

private:
    friend struct ShaderBytecodeCacheTestAccess;

    std::filesystem::path blobPath(const ShaderCacheKey& key) const {
        return diskDirectory_ / (key.id + ".dxbc");
    }

    bool readFromDisk(const ShaderCacheKey& key, std::vector<uint8_t>& out, uint32_t version) const {
        std::error_code ec;
        const auto path = blobPath(key);
        if (!std::filesystem::is_regular_file(path, ec)) return false;
        std::ifstream in(path, std::ios::binary | std::ios::ate);
        if (!in) return false;
        const auto size = in.tellg();
        if (size <= static_cast<std::streamoff>(sizeof(detail::ShaderBlobHeader)) ||
            size > static_cast<std::streamoff>(16 * 1024 * 1024)) {
            return false;
        }
        in.seekg(0);
        std::vector<uint8_t> raw(static_cast<size_t>(size));
        if (!in.read(reinterpret_cast<char*>(raw.data()), size)) return false;
        return deserializeShaderBlob(key, raw, out, version);
    }

    void writeToDisk(const ShaderCacheKey& key, const std::vector<uint8_t>& bytecode, uint32_t version) const {
        std::error_code ec;
        std::filesystem::create_directories(diskDirectory_, ec);
        if (ec) return;
        static std::atomic<uint64_t> tempSequence{0};
#if defined(_WIN32)
        const unsigned long pid = static_cast<unsigned long>(_getpid());
#else
        const unsigned long pid = static_cast<unsigned long>(getpid());
#endif
        const uint64_t seq = tempSequence.fetch_add(1, std::memory_order_relaxed);
        const auto target = blobPath(key);
        const auto temp = diskDirectory_ / (key.id + ".tmp." + std::to_string(pid) + "." + std::to_string(seq));
        const auto serialized = serializeShaderBlob(key, bytecode, version);
        {
            std::ofstream out(temp, std::ios::binary | std::ios::trunc);
            if (!out) return;
            out.write(reinterpret_cast<const char*>(serialized.data()),
                      static_cast<std::streamsize>(serialized.size()));
            out.flush();
            if (!out) {
                out.close();
                std::filesystem::remove(temp, ec);
                return;
            }
            out.close();
            if (out.fail()) {
                std::filesystem::remove(temp, ec);
                return;
            }
        }
#if defined(_WIN32)
        if (!MoveFileExW(temp.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            std::filesystem::remove(temp, ec);
        }
#else
        std::filesystem::rename(temp, target, ec);
        if (ec) std::filesystem::remove(temp, ec);
#endif
    }

    std::filesystem::path diskDirectory_;
    mutable std::mutex mutex_;
    std::unordered_map<std::string, std::vector<uint8_t>> memory_;
    Stats stats_;
};

#if defined(_WIN32)
inline std::filesystem::path defaultD3D11ShaderCacheDirectory() {
    wchar_t buffer[MAX_PATH]{};
    const DWORD len = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
        return std::filesystem::path(buffer) / L"RawLab" / L"shader-cache";
    }
    const DWORD tmpLen = GetTempPathW(MAX_PATH, buffer);
    if (tmpLen > 0 && tmpLen < MAX_PATH) {
        return std::filesystem::path(buffer) / L"RawLab" / L"shader-cache";
    }
    return {};
}

inline ShaderBytecodeCache& sharedD3D11ShaderCache() {
    static ShaderBytecodeCache cache(defaultD3D11ShaderCacheDirectory());
    return cache;
}

template <class CheckFn>
inline std::vector<uint8_t> compileD3D11Shader(
    std::string_view sourceName,
    std::string_view source,
    std::string_view entryPoint,
    std::string_view target,
    UINT flags,
    CheckFn&& checkedFn) {
    const auto key = makeD3D11ShaderCacheKey(sourceName, source, entryPoint, target, static_cast<uint32_t>(flags));
    return sharedD3D11ShaderCache().getOrCompile(key, [&]() {
        Microsoft::WRL::ComPtr<ID3DBlob> code, errors;
        const std::string nameCopy(sourceName);
        const std::string entryCopy(entryPoint);
        const std::string targetCopy(target);
        const HRESULT compiled = D3DCompile(
            source.data(), source.size(), nameCopy.c_str(), nullptr, nullptr,
            entryCopy.c_str(), targetCopy.c_str(), flags, 0, &code, &errors);
        if (FAILED(compiled) && errors) {
            OutputDebugStringA(static_cast<const char*>(errors->GetBufferPointer()));
            std::cerr << static_cast<const char*>(errors->GetBufferPointer()) << '\n';
        }
        checkedFn(compiled);
        const auto* begin = static_cast<const uint8_t*>(code->GetBufferPointer());
        return std::vector<uint8_t>(begin, begin + code->GetBufferSize());
    });
}
#endif

} // namespace sony2fuji
