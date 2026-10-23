#pragma once
#include <array>
#include <cstddef>
#include <string>

namespace sony2fuji::ai {
inline constexpr const char* dualdnSourceRevision = "7ec5f6a21c04321beb0d3297d6e9ac5f50635555";
inline constexpr const char* dualdnWeightsSHA256 = "9bd36c18afd6148d3b5d50c215d77cc17a745851ed2735f1b655013e71c38e1d";
struct ModelPackage {
    std::string modelID, digest;
    int tileSize = 0;
    std::array<std::string, 3> paths; // RAW、ISP、RGB。
    std::array<std::string, 2> coreMLPaths; // 可选的 RAW/RGB 原生 float32 模型。
};
std::string sha256File(const std::string& path);
std::string sha256Bytes(const void* data, size_t size);
ModelPackage loadModelPackage(const std::string& directory);
} // namespace sony2fuji::ai
