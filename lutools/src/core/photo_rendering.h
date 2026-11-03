#pragma once

#include "sony2fuji/color_converter.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji {

// A declared scene workflow default, not a camera calibration or JPEG meter.
inline float sceneExposureEV(float cameraBaselineEV) {
    const float metadata = std::isfinite(cameraBaselineEV) && std::abs(cameraBaselineEV)<=8 ? cameraBaselineEV : 0;
    return .7f + metadata;
}

// Zero-black, unit-white log-logistic view curve. Middle gray is invariant;
// the 1.5 exponent controls contrast, while highlights approach white smoothly.
// This is a fixed mathematical subset, not darktable's full color pipeline.
inline float neutralDisplayLinear(float linear) {
    if (linear<=0) return 0;
    constexpr float gray=.1845f;
    const float shoulder=(1-gray)/gray*std::pow(gray/linear,1.5f);
    return 1/(1+shoulder);
}

inline float neutralDisplay(float linear) {
    return GammaConverter::applySRGBGamma(neutralDisplayLinear(linear));
}

} // namespace sony2fuji
