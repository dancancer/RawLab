#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/dcp_look.h"
#include "sony2fuji/lut_parser.h"
#include "core/pixel_buffer.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_effects.h"
#include "core/photo_tone_controls.h"
#include "core/photo_tone_curve.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>

namespace sony2fuji {

enum class RenderInputType : int32_t {
    Raw = 0,
    Buffer = 1,
    DisplayBuffer = 2
};

enum class RenderWhiteBalanceMode : int32_t {
    Camera = 0,
    Auto = 1,
    Custom = 2,
    Temperature = 3
};

enum class RenderOutputTarget : int32_t {
    File = 0,
    Buffer = 1
};

enum class RenderOutputFormat : int32_t {
    JPEG = 0,
    PNG = 1,
    RGB8 = 2,
    RGBA8 = 3,
    DNG = 4
};

enum class RenderSizeMode : int32_t {
    Exact = 0,
    FitLongEdge = 1,
    FitShortEdge = 2,
    Native = 3,
    LimitLongEdge = 4
};

enum class RenderIntent : int32_t {
    Preview = 0,
    Final = 1
};

struct RenderParams {
    RenderInputType inputType = RenderInputType::Raw;
    std::string inputPath;
    const void* inputPixels = nullptr;
    uint32_t inputWidth = 0;
    uint32_t inputHeight = 0;
    PixelBufferFormat inputPixelFormat = PixelBufferFormat::RGB8;
    ColorSpace inputColorSpace = ColorSpace::sRGB;
    bool inputIsLinear = false;

    RenderWhiteBalanceMode wbMode = RenderWhiteBalanceMode::Camera;
    float temperature = 6500.0f;
    float tint = 0.0f;
    std::array<float, 3> wbMul{1.0f, 1.0f, 1.0f};
    RGB relativeWB{1.0f, 1.0f, 1.0f};

    float exposureEV = 0.0f;
    float brightness = 1.0f;
    float contrast = 1.0f;
    float saturation = 1.0f;
    float highlights = 0.0f;
    float shadows = 0.0f;
    float toneCurve = 0.0f;
    float noiseReduction = 0.0f;
    float sharpening = 0.0f;

    std::string lutPath;
    float lutStrength = 1.0f;
    std::shared_ptr<LUT3D> lut;
    std::shared_ptr<const DcpLook> dcp;

    PhotoEffectsOptions effects{};
    int chromaDenoise = 0;
    bool preserveSourceResolution = false;
    HslOptions hsl{};
    ToneControlsOptions toneControls{};
    ColorGradingOptions colorGrading{};
    ToneCurve customCurve{};

    RenderOutputTarget outputTarget = RenderOutputTarget::Buffer;
    RenderOutputFormat outputFormat = RenderOutputFormat::RGB8;
    std::string outputPath;
    uint32_t jpegQuality = 95;

    RenderSizeMode sizeMode = RenderSizeMode::Native;
    uint32_t targetWidth = 0;
    uint32_t targetHeight = 0;
    uint32_t longEdge = 0;
    uint32_t shortEdge = 0;
    uint32_t previewLongEdge = 0;
    RenderIntent intent = RenderIntent::Final;

    bool needsToneAdjustments() const noexcept {
        return exposureEV != 0.0f || brightness != 1.0f ||
               contrast != 1.0f || saturation != 1.0f ||
               temperature != 6500.0f || tint != 0.0f ||
               wbMode == RenderWhiteBalanceMode::Custom ||
               relativeWB.r != 1.0f || relativeWB.g != 1.0f || relativeWB.b != 1.0f ||
               highlights != 0.0f || shadows != 0.0f ||
               toneCurve != 0.0f || customCurve.active();
    }

    bool validForGpu() const noexcept {
        return std::isfinite(exposureEV) && std::isfinite(brightness) &&
               std::isfinite(contrast) && std::isfinite(saturation) &&
               std::isfinite(temperature) && std::isfinite(tint) &&
               std::isfinite(highlights) && std::isfinite(shadows) &&
               std::isfinite(toneCurve) && std::isfinite(noiseReduction) &&
               std::isfinite(sharpening) && std::isfinite(lutStrength) &&
               std::isfinite(relativeWB.r) && std::isfinite(relativeWB.g) && std::isfinite(relativeWB.b) &&
               effects.valid() && hsl.valid() && toneControls.valid() && colorGrading.valid() &&
               customCurve.gpuSupported() && !(customCurve.custom() && toneCurve != 0.0f) &&
               chromaDenoise >= 0 && chromaDenoise <= 2;
    }
};

bool exceedsOutputPixelCap(uint32_t width, uint32_t height);
bool isJpegFileOutput(const RenderParams& params);
bool isDngFileOutput(const RenderParams& params);
bool exceedsOutputTargetCap(const RenderParams& params, uint32_t width, uint32_t height);
bool needsSourceSizePreflight(const RenderParams& params);

RenderStatus validateRenderParamsSize(const RenderParams& params);
RenderStatus validateRenderParams(const RenderParams& params, bool hasOutputBuffer);
RenderStatus validateRenderOutputFormat(const RenderParams& params);
RenderStatus computeTargetSize(const RenderParams& params,
                               uint32_t srcWidth,
                               uint32_t srcHeight,
                               uint32_t* outWidth,
                               uint32_t* outHeight);

} // namespace sony2fuji
