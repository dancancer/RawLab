#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/dcp_look.h"
#include "sony2fuji/lut_parser.h"
#include "sony2fuji/processing_version.h"
#include "sony2fuji/sony2fuji.h"
#include "core/pixel_buffer.h"
#include "core/photo_geometry.h"
#include "core/photo_sharpen_v2.h"
#include "core/photo_tone_curve.h"
#include "core/render_params.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <memory>

namespace sony2fuji {

struct BasicToneV3Field;
struct ClarityField;
struct DehazeAnalysis;
struct FilmOpticsField;

// CPU 渲染唯一的阶段顺序：整图（导出、预览、HSL 取样）、ROI 引导图和 ROI 瓦片都调用
// runCpuStageChain，新增算子只需在这里按顺序插入一次。CpuStagePass 只描述各路径合法的差异。
struct CpuStagePass {
    enum class Kind {
        Full,     // 整图：空间分析在本图上计算，去雾分析写入 dehaze 缓存
        RoiGuide, // ROI 引导小图：按同一顺序构建分析场，只跑到最后一个需要的场，不做降噪、锐化、色度降噪和特效
        RoiTile,  // ROI 瓦片：复用引导图分析场，经 roiMap 映射到整图坐标
    };
    Kind kind = Kind::Full;
    bool basicV3 = false;
    BasicToneV3 basicTone{};
    // 进入链条前的线性 sRGB 转换与曝光/白平衡增益。
    bool applyMatrix = false;
    ColorConverter::Matrix3x3 toSrgb{{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}};
    RGB exposureWB{1.0f, 1.0f, 1.0f};
    bool displayInput = false;
    GpuConfig lookConfig{};
    // Basic、去雾和清晰度按整幅画布尺寸分析。
    int analysisWidth = 0;
    int analysisHeight = 0;
    SubRectMap roiMap{};
    // HSL 取样只需要 HSL 之前的像素。
    bool stopBeforeHsl = false;
    // 现状：ROI 引导图和瓦片在黑白点之后会再执行一次黑白混合，整图只执行一次。
    // 这里保留该行为以保证 ROI 输出逐字节不变，是否改为与整图一致待单独决定。
    const BwMixerOptions* repeatBwAfterBlackWhite = nullptr;
    // 分析场：Full 可带入尺寸匹配的 Basic 场并以 dehaze 作去雾缓存；RoiGuide 写出、RoiTile 读入同一组场。
    const BasicToneV3Field* basicField = nullptr;
    BasicToneV3Field* basicFieldOut = nullptr;
    DehazeAnalysis* dehaze = nullptr;
    ClarityField* clarity = nullptr;
    FilmOpticsField* filmOptics = nullptr;
};

// 引导图只构建细节阶段的分析场：清晰度场取清晰度之前的像素，胶片光学场取纹理之后的像素。
struct DetailGuideFields {
    ClarityField* clarity = nullptr;
    FilmOpticsField* filmOptics = nullptr;
};

inline float clampFloat(float value, float low, float high) {
    return std::max(low, std::min(high, value));
}

inline float clamp01(float value) {
    return clampFloat(value, 0.0f, 1.0f);
}

RGB whiteBalanceForTempTint(float temperature, float tint);

void applyExposureAndWhiteBalance(RGB& pixel, float exposureScale, const RGB& wb);

RGB sampleBilinear(const ImageData& image, double x, double y);

ImageData resizeBilinear(
    const ImageData& source,
    uint32_t targetWidth,
    uint32_t targetHeight
);

void applyPostLookStages(
    ImageData& image,
    const RenderParams& params,
    const ToneControlsOptions& toneControls,
    const HslOptions& hsl,
    const ColorGradingOptions& colorGrading,
    const std::array<ToneCurve, 3>& channels,
    bool basicV3,
    bool applyHslAndGrading,
    const BwMixerOptions* repeatBwAfterBlackWhite = nullptr
);

void applyDetailAdjustments(
    ImageData& image,
    float noiseReduction,
    float sharpening,
    float clarity,
    int sourceWidth,
    int sourceHeight,
    ProcessingVersion version,
    const ClarityField* clarityField = nullptr,
    const SubRectMap& roiMap = {},
    float texture = 0.0f,
    const SharpenV2Options& sharpenV2 = {},
    int textureSourceWidth = 0,
    int textureSourceHeight = 0,
    const FilmOpticsOptions& filmOptics = {},
    const FilmOpticsField* filmOpticsField = nullptr,
    const DetailGuideFields* guideFields = nullptr
);

// 从线性源空间转换开始、到特效为止的完整 CPU 阶段链；几何与输出编码由调用方负责。
// Basic v3 影调生效后 params 的 highlights/shadows 归零，后续影调阶段不再重复应用。
RenderStatus runCpuStageChain(ImageData& image, RenderParams& params, const CpuStagePass& pass);

void applyOutputSharpening(ImageData& image, OutputSharpening level);

RenderStatus applyPhotoLook(
    ImageData& image,
    const std::shared_ptr<LUT3D>& lut,
    const std::shared_ptr<const DcpLook>& dcp,
    float strength,
    bool displayInput,
    const GpuConfig& config
);

RenderStatus ensureLinear(
    ImageData& image,
    ColorSpace space,
    bool* isLinear
);

RenderStatus loadLUT(
    const char* lutPath,
    std::shared_ptr<LUT3D>* outLut
);

} // namespace sony2fuji
