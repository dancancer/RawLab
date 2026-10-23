#pragma once
#include <array>
#include <cstddef>
#include <string>

namespace sony2fuji::ai {
inline constexpr const char* dualdnSourceRevision = "7ec5f6a21c04321beb0d3297d6e9ac5f50635555";
inline constexpr const char* dualdnWeightsSHA256 = "9bd36c18afd6148d3b5d50c215d77cc17a745851ed2735f1b655013e71c38e1d";
inline constexpr const char* restormerSourceRevision = "b19fa6e7104cb946ac8c5d6368117962ed0e751b";
inline constexpr const char* restormerWeightsSHA256 = "4cae18bed8a291b9a5deeeab48756bbe6f61fcf7f31a4cca0969b24608601387";
inline constexpr const char* restormerLicenseSHA256 = "50fdf21f3caa7c42c51e0145d6cdb70a4f0d456955797d1f94de14c640a2c702";
struct ModelPackage {
    std::string modelID, digest;
    int tileSize = 0;
    std::array<std::string, 3> paths; // RAW、ISP、RGB。
    std::array<std::string, 2> coreMLPaths; // 可选的 RAW/RGB 原生 float32 模型。
    std::string blindRGBPath, blindRGBCoreMLPath;
};
std::string sha256File(const std::string& path);
std::string sha256Bytes(const void* data, size_t size);
ModelPackage loadModelPackage(const std::string& directory);
} // namespace sony2fuji::ai
