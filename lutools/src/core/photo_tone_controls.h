#pragma once

#include "sony2fuji/common.h"

namespace sony2fuji {

// 算法 v1：显示编码 sRGB。两个独立阶段之间保留原 tone/curve/saturation。
struct ToneControlsOptions {
    float blackPoint = 0;
    float whitePoint = 0;
    float vibrance = 0;
    bool valid() const;
    bool active() const { return blackPoint != 0 || whitePoint != 0 || vibrance != 0; }
};

float blackWhiteOffset(float luminance, const ToneControlsOptions& options);
RGB applyBlackWhite(const RGB& pixel, const ToneControlsOptions& options);
RGB applyVibrance(const RGB& pixel, const ToneControlsOptions& options);
void applyBlackWhite(ImageData& image, const ToneControlsOptions& options);
void applyVibrance(ImageData& image, const ToneControlsOptions& options);

} // namespace sony2fuji
