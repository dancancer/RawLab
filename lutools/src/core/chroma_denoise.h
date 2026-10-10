#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/gpu/lut_gpu.h"

namespace sony2fuji {

struct ChromaDenoiseDiagnostics {
    int flatTiles = 0;
    float confidence = 0;
    bool applied = false;
    bool gpuUsed = false;
};

bool chromaDenoiseAvailable();
// 输入必须为显影后的 display-sRGB；0 关闭，1 细节优先，2 去噪优先。
ErrorCode applyChromaDenoise(ImageData& image, int mode,
    ChromaDenoiseDiagnostics* diagnostics = nullptr, GpuMode gpuMode = GpuMode::Off);

} // namespace sony2fuji
