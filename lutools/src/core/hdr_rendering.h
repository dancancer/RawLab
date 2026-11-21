#pragma once

#include "core/hdr_types.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_effects.h"
#include "core/photo_tone_curve.h"
#include "core/hdr_detail.h"

#include "sony2fuji/common.h"
#include "core/photo_geometry.h"
#include <array>
#include <cstdint>
#include <memory>

namespace sony2fuji {

class HDRLook;

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
    // 渲染后 SDR 平面的内容亮度峰值（≥1）；渲染尾段无几何/效果/细节时由 edit 融合扫描写出，0 表示未测量。
    float editedSdrHeadroom = 0;
};

struct HDRToneOptions {
    float blackPoint = 0, whitePoint = 0, curveStrength = 0;
    ToneCurveConfig curve{};
    std::array<ToneCurveConfig, 3> channels{};
};

struct HDRColorOptions {
    float vibrance = 0;
    HslOptions hsl;
    ColorGradingOptions grading;
};

struct HDRRenditionOptions {
    float peakLimitEV = 0;
    float sdrExposureEV = 0;
    float sdrContrast = 0;
    float sdrSaturation = 0;
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
    HDRToneOptions tone;
    HDRColorOptions color;
    HDRRenditionOptions rendition;
    PhotoEffectsOptions effects;
    HDRDetailOptions detail;
    std::shared_ptr<const HDRLook> look;
    float lookStrength = 0;

    bool hasPhotoEffects() const { return processingVersion >= kHdrProcessingEffectsVersion && effects.active(); }
    bool hasDetail() const { return processingVersion >= kHdrProcessingDetailVersion && detail.active(); }
};

// 来源为已定向、显示参考的扩展线性 sRGB。非法输入抛 invalid_argument，
// 数值溢出抛 overflow_error，分配失败保留 bad_alloc；来源始终不变。
HDRImagePair renderHDRPair(const HDRImagePair& source, const HDRRenderOptions& options);
// A uniquely owned source may transfer its two pixel vectors into the result.
// Callers that need the source after rendering must use the const& overload.
HDRImagePair renderHDRPair(HDRImagePair&& source, const HDRRenderOptions& options);
struct HDRRoiSpec {
    double normX0 = 0.0;
    double normY0 = 0.0;
    double normX1 = 1.0;
    double normY1 = 1.0;
    uint32_t maxOutputLongEdge = 0;
    float baseContentHeadroom = 0.0f;
    uint32_t sourceOffsetX = 0;
    uint32_t sourceOffsetY = 0;
    uint32_t fullSourceWidth = 0;
    uint32_t fullSourceHeight = 0;
};

struct HDRRoiSourceBounds {
    RoiSubRect sourceRect;
    OutputRoiPlan plan;
    int detailHalo = 0;
    int paddedOx0 = 0;
    int paddedOy0 = 0;
    int paddedOx1 = 0;
    int paddedOy1 = 0;
    int fullScaledWidth = 0;
    int fullScaledHeight = 0;
    int paddedOutWidth = 0;
    int paddedOutHeight = 0;
    int cropLeft = 0;
    int cropTop = 0;
};

HDRRoiSourceBounds computeHDRRoiSourceBounds(uint32_t fullSourceWidth, uint32_t fullSourceHeight,
    const HDRRenderOptions& options, const HDRRoiSpec& roi);

HDRImagePair renderHDRPairROI(const HDRImagePair& source, const HDRRenderOptions& options,
    const HDRRoiSpec& roi, HDRRoiSourceBounds* outBounds = nullptr);

ImageData extractHDRPlaneForROI(const ImageData& src, uint32_t fullWidth, uint32_t fullHeight,
    const RoiSubRect& rect, uint32_t offsetX = 0, uint32_t offsetY = 0, bool isPreCropped = false);

// Shared entry when caller already extracted/resampled sub-rectangles covering bounds.sourceRect.
HDRImagePair renderHDRSubRectROI(ImageData subHdr, ImageData subSdr,
    uint32_t fullSourceWidth, uint32_t fullSourceHeight,
    float sourceHeadroom, uint64_t decodeRevision, HDRQuality sourceQuality,
    const HDRRenderOptions& options, const HDRRoiSpec& roi,
    const HDRRoiSourceBounds& bounds,
    const ImageData* veilSourceHdr = nullptr, const ImageData* veilSourceSdr = nullptr);

ImageData renderHDRHslProbe(ImageData image, const HDRRenderOptions& options);
HslColor analyzeHDRColor(const RGB& pixel);

// 供流式导出复用逐像素颜色算法；这里只处理一个行块，不声明 FINAL 图像来源。
void validateHDRRenderOptions(const HDRRenderOptions& options);
RGB hdrRelativeWhiteBalance(float temperature, float tint);
bool editHDRPixels(ImageData& image, const HDRRenderOptions& options, bool hdr, float* contentMax = nullptr);
std::pair<int, int> hdrResizeSize(int width, int height, uint32_t longEdge);
RGB sampleHDRResize(int x, int y, int width, int height, int outputWidth, int outputHeight,
    const GeometryPixelReader& read);

} // namespace sony2fuji
