#pragma once

#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_effects.h"
#include "core/hdr_detail.h"

#include "sony2fuji/common.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "core/photo_geometry.h"
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
};

struct HDRToneOptions {
    float blackPoint = 0, whitePoint = 0, curveStrength = 0;
    sony2fuji_tone_curve_config curve{SONY2FUJI_TONE_CURVE_CONFIG_VERSION,
        sizeof(sony2fuji_tone_curve_config), SONY2FUJI_CURVE_LEGACY, 0, {}};
    std::array<sony2fuji_tone_curve_config, 3> channels{{curve, curve, curve}};
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

    bool hasPhotoEffects() const { return processingVersion >= SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION && effects.active(); }
    bool hasDetail() const { return processingVersion >= SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION && detail.active(); }
};

// 来源为已定向、显示参考的扩展线性 sRGB。非法输入抛 invalid_argument，
// 数值溢出抛 overflow_error，分配失败保留 bad_alloc；来源始终不变。
HDRImagePair renderHDRPair(const HDRImagePair& source, const HDRRenderOptions& options);
// A uniquely owned source may transfer its two pixel vectors into the result.
// Callers that need the source after rendering must use the const& overload.
HDRImagePair renderHDRPair(HDRImagePair&& source, const HDRRenderOptions& options);
ImageData renderHDRHslProbe(ImageData image, const HDRRenderOptions& options);
HslColor analyzeHDRColor(const RGB& pixel);

// 供流式导出复用逐像素颜色算法；这里只处理一个行块，不声明 FINAL 图像来源。
void validateHDRRenderOptions(const HDRRenderOptions& options);
RGB hdrRelativeWhiteBalance(float temperature, float tint);
void editHDRPixels(ImageData& image, const HDRRenderOptions& options, bool hdr);
std::pair<int, int> hdrResizeSize(int width, int height, uint32_t longEdge);
RGB sampleHDRResize(int x, int y, int width, int height, int outputWidth, int outputHeight,
    const GeometryPixelReader& read);

} // namespace sony2fuji
