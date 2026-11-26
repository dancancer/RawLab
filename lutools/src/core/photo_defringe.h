#pragma once

#include "sony2fuji/common.h"

namespace sony2fuji {

struct DefringeOptions {
    float purpleAmount = 0.0f; // [0, 20]
    float purpleHue = 50.0f;   // [0, 100]
    float greenAmount = 0.0f;  // [0, 20]
    float greenHue = 50.0f;    // [0, 100]

    bool valid() const;
    bool active() const { return purpleAmount > 0.0f || greenAmount > 0.0f; }
    bool isDefault() const {
        return purpleAmount == 0.0f && purpleHue == 50.0f &&
               greenAmount == 0.0f && greenHue == 50.0f;
    }

    bool operator==(const DefringeOptions& other) const {
        return purpleAmount == other.purpleAmount && purpleHue == other.purpleHue &&
               greenAmount == other.greenAmount && greenHue == other.greenHue;
    }
};

// 由滑块值派生的逐像素常量。CPU 与三个 GPU 后端共用这一份推导，GPU 只读取结果：
// Intel 宿主的 Metal 编译器曾把着色器里的 clamp(x / 20, 0, 1) 错误折叠成 clamp(x, 0, 1) / 20（#695）。
struct DefringeWeights {
    float purpleNorm = 0.0f;
    float purpleCenter = 290.0f;
    float greenNorm = 0.0f;
    float greenCenter = 120.0f;
};

DefringeWeights defringeWeights(const DefringeOptions& options);

void applyDefringe(ImageData& image, const DefringeOptions& options);

} // namespace sony2fuji
