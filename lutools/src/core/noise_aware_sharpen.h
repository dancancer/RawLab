#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/gpu/lut_gpu.h"

namespace sony2fuji {

inline constexpr const char* kNoiseAwareSharpenCandidate = "p3-bounded-edge-endpoint-v2";

struct NoiseAwareSharpenDiagnostics {
    bool applied = false;
    bool gpuUsed = false;
    float noiseSigmaMedian = 0;
    float noiseSigmaMax = 0;
};

bool noiseAwareSharpenAvailable();
// 内部实验入口，不接入现有锐化参数。正强度先裁至 SDR，0 保留原始浮点值。
// amount 属于 [0, 2]，是受限端点的线性混合；失败不修改 image。
ErrorCode applyNoiseAwareSharpen(ImageData& image, float amount,
    NoiseAwareSharpenDiagnostics* diagnostics = nullptr, GpuMode gpuMode = GpuMode::Off);

} // namespace sony2fuji
