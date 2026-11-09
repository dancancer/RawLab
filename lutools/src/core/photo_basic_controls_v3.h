#pragma once

#include "sony2fuji/common.h"
#include "photo_tone_controls.h"

namespace sony2fuji {

struct BasicToneV3 {
    float highlights = 0;
    float shadows = 0;
    bool active() const { return highlights != 0 || shadows != 0; }
};

// 在线性光中改变照明基底，保留局部细节和进入外观曲线前的高光余量。
void applyBasicToneV3(ImageData& image, const BasicToneV3& options,
    int sourceWidth = 0, int sourceHeight = 0);

float basicContrastV3(float value, float amount);
RGB basicBlackWhiteV3(const RGB& pixel, const ToneControlsOptions& options);
RGB basicVibranceV3(const RGB& pixel, float amount);
void applyBasicBlackWhiteV3(ImageData& image, const ToneControlsOptions& options);
void applyBasicVibranceV3(ImageData& image, float amount);

} // namespace sony2fuji
