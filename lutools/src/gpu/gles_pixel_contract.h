#pragma once

#include "sony2fuji/lut_parser.h"
#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace sony2fuji {

// Explicit pixel/texel memory layout contract for OpenGL ES 3.1 compute photo rendering:
// 1. Storage buffers at bindings 0..2 exchange tightly packed linear float32 RGB triplets
//    (3 * 4 = 12 bytes per pixel; no padding channel between pixels or rows).
// 2. The 3D look LUT texture at unit 0 uses GL_RGBA32F / GL_RGBA / GL_FLOAT (16 bytes per texel)
//    with explicit GL_UNPACK_ALIGNMENT = 1 and GL_NEAREST / GL_CLAMP_TO_EDGE while
//    gles_photo_shader.h performs manual trilinear interpolation in shader code.
struct GlesPhotoPixelContract {
    static constexpr size_t kSsboChannels = 3;
    static constexpr size_t kSsboPixelBytes = kSsboChannels * sizeof(float);
    static constexpr size_t kLutChannels = 4;
    static constexpr size_t kLutTexelBytes = kLutChannels * sizeof(float);
    static constexpr int kLutUnpackAlignment = 1;
    static constexpr size_t kWorkgroupSize = 128;
};

static_assert(std::is_standard_layout_v<RGB>, "GLES SSBO RGB must have standard layout");
static_assert(sizeof(RGB) == GlesPhotoPixelContract::kSsboPixelBytes,
              "GLES SSBO RGB stride must equal 3 tightly packed float32 channels");
static_assert(offsetof(RGB, r) == 0 && offsetof(RGB, g) == sizeof(float) &&
                  offsetof(RGB, b) == 2 * sizeof(float),
              "GLES SSBO RGB fields must be packed as R, G, B without internal padding");

inline bool validGlesLut3DContract(const LUT3D& lut, int maxTexture3DSize, size_t uploadedFloatCount) {
    const int size = lut.getSize();
    if (size <= 1 || maxTexture3DSize <= 0 || size > maxTexture3DSize) return false;
    const size_t side = static_cast<size_t>(size);
    if (side > (std::numeric_limits<size_t>::max)() / side) return false;
    const size_t plane = side * side;
    if (plane > (std::numeric_limits<size_t>::max)() / side) return false;
    const size_t voxels = plane * side;
    if (voxels > (std::numeric_limits<size_t>::max)() / GlesPhotoPixelContract::kLutChannels) return false;
    return uploadedFloatCount == voxels * GlesPhotoPixelContract::kLutChannels;
}

} // namespace sony2fuji
