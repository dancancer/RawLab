#pragma once

#include "sony2fuji/common.h"
#include <vector>

namespace sony2fuji {

struct SharpenV2Options {
    bool luminanceV2 = false;
    float radius = 1.0f;   // [0.5, 3.0]
    float detail = 25.0f;  // [0, 100]
    float masking = 0.0f;  // [0, 100]

    bool valid() const;
    bool active() const { return luminanceV2; }
    bool isDefault() const {
        return !luminanceV2 && radius == 1.0f && detail == 25.0f && masking == 0.0f;
    }

    bool operator==(const SharpenV2Options& other) const {
        return luminanceV2 == other.luminanceV2 && radius == other.radius &&
               detail == other.detail && masking == other.masking;
    }
};

// 由滑块值派生的逐像素常量。CPU 与三个 GPU 后端共用这一份推导，GPU 只读取结果，
// 避免 Intel 宿主 Metal 编译器错误折叠着色器里的 clamp(x / 100, 0, 1)（#695）。
struct SharpenV2Coefficients {
    float coring = 0.0f;      // |diff| 低于此值时细节权重平滑衰减
    float detailGain = 0.0f;  // clamp(amount, 0, 2) * (0.7 + 1.2 * detail/100)
    float maskLow = 0.0f;     // 边缘遮罩 smoothstep 起点；maskSpan == 0 表示不启用遮罩
    float maskSpan = 0.0f;
};

SharpenV2Coefficients sharpenV2Coefficients(float amount, const SharpenV2Options& options);

void computeSharpenEdgeMask(
    const std::vector<float>& luma,
    int width,
    int height,
    float radius,
    float masking,
    std::vector<float>& outMask
);

void applySharpenV2(ImageData& image, float amount, const SharpenV2Options& options);

} // namespace sony2fuji
