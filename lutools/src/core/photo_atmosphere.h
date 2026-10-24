#pragma once

#include "sony2fuji/common.h"
#include <cstdint>

namespace sony2fuji {

struct AtmosphereOptions {
    float clarity = 0;
    float dehaze = 0;
    bool valid() const;
    bool active() const { return clarity != 0 || dehaze != 0; }
};

// 固定源图分析，不随窗口、强度和下游调色变化。内容签名也覆盖 buffer 原地更新。
struct DehazeAnalysis {
    uint64_t fingerprint = 0;
    uint64_t builds = 0;
    int sourceWidth = 0, sourceHeight = 0;
    int width = 0, height = 0;
    RGB airlight;
    std::vector<float> slope, intercept, variance;
};

void applyDehaze(ImageData& image, float amount, DehazeAnalysis* cache = nullptr);
void applyClarity(ImageData& image, float amount);

} // namespace sony2fuji
