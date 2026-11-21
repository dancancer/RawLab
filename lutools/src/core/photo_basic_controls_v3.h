#pragma once

#include "sony2fuji/common.h"
#include "photo_geometry.h"
#include "photo_tone_controls.h"

#include <vector>

namespace sony2fuji {

struct BasicToneV3 {
    float highlights = 0;
    float shadows = 0;
    bool active() const { return highlights != 0 || shadows != 0; }
};

struct BasicToneV3Field {
    int width = 0;
    int height = 0;
    std::vector<float> slope;
    std::vector<float> intercept;
    bool empty() const { return width <= 0 || height <= 0 || slope.empty() || intercept.empty(); }
};

// 在线性光中改变照明基底，保留局部细节和进入外观曲线前的高光余量。
BasicToneV3Field buildBasicToneV3Field(const ImageData& image,
    int sourceWidth = 0, int sourceHeight = 0);
void applyBasicToneV3WithField(ImageData& image, const BasicToneV3& options,
    const BasicToneV3Field& field, const SubRectMap& roiMap = {});
void applyBasicToneV3(ImageData& image, const BasicToneV3& options,
    int sourceWidth = 0, int sourceHeight = 0);

float basicContrastV3(float value, float amount);
RGB basicBlackWhiteV3(const RGB& pixel, const ToneControlsOptions& options);
RGB basicVibranceV3(const RGB& pixel, float amount);
void applyBasicBlackWhiteV3(ImageData& image, const ToneControlsOptions& options);
void applyBasicVibranceV3(ImageData& image, float amount);

} // namespace sony2fuji
