#pragma once

namespace sony2fuji {

// 连续 RGB 和单通道 float 缓冲；噪声分析在 CPU 完成，空间滤波在 Metal 执行。
// 失败不修改 output；内部使用，不改变现有 GPU dispatcher 或 C ABI。
bool metalNoiseAwareSharpen(const float* rgb, const float* luma, const float* residual,
    const float* noiseVariance, int width, int height, float amount, float* output);

}
