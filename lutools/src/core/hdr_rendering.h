#pragma once

#include "sony2fuji/common.h"
#include "core/photo_geometry.h"
#include <cstdint>

namespace sony2fuji {

enum class HDRQuality : uint32_t { Preview = 0, Final = 1 };

struct HDRImagePair {
    ImageData hdr;
    ImageData sdr;
    uint32_t nativeWidth = 0, nativeHeight = 0;
    uint32_t outputNativeWidth = 0, outputNativeHeight = 0;
    HDRQuality sourceQuality = HDRQuality::Final;
    HDRQuality renderQuality = HDRQuality::Final;
    uint64_t decodeRevision = 0;
    bool isProxy = false;
    float sourceHeadroom = 0;
    float editedHeadroom = 0;
};

struct HDRRenderOptions {
    uint32_t processingVersion = 1;
    float exposureEV = 0;
    float temperature = 6500;
    float tint = 0;
    float contrast = 0;
    float highlights = 0;
    float shadows = 0;
    float saturation = 0;
    GeometryOptions geometry;
    HDRQuality intent = HDRQuality::Final;
    uint32_t longEdge = 0;
};

// 来源为已定向、显示参考的扩展线性 sRGB。非法输入抛 invalid_argument，
// 数值溢出抛 overflow_error，分配失败保留 bad_alloc；来源始终不变。
HDRImagePair renderHDRPair(const HDRImagePair& source, const HDRRenderOptions& options);

} // namespace sony2fuji
