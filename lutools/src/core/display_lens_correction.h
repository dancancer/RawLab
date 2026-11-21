#pragma once
#include "sony2fuji/common.h"
#include "sony2fuji/lens_correction.h"

namespace sony2fuji {

// RGB 已由平台应用 EXIF 方向；校正坐标仍在镜头原始画幅中计算。
LensCorrectionReport applyDisplayLensCorrection(ImageData& image,
    std::shared_ptr<const LensCorrectionDatabase> database, const LensMetadata& metadata,
    const LensCorrectionOptions& options, int sourceOrientation);

}
