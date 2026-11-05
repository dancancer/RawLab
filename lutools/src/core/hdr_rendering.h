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
// A uniquely owned source may transfer its two pixel vectors into the result.
// Callers that need the source after rendering must use the const& overload.
HDRImagePair renderHDRPair(HDRImagePair&& source, const HDRRenderOptions& options);

// 供流式导出复用逐像素颜色算法；这里只处理一个行块，不声明 FINAL 图像来源。
void validateHDRRenderOptions(const HDRRenderOptions& options);
void editHDRPixels(ImageData& image, const HDRRenderOptions& options, bool hdr);
std::pair<int, int> hdrResizeSize(int width, int height, uint32_t longEdge);
RGB sampleHDRResize(int x, int y, int width, int height, int outputWidth, int outputHeight,
    const GeometryPixelReader& read);

} // namespace sony2fuji
