#pragma once
#include <string>

namespace sony2fuji { struct RAWBayerSource; }

namespace sony2fuji::ai {
struct NoiseParameters {
    float k = 0, b = 0;
    bool interpolated = false;
    int lowerISO = 0, upperISO = 0;
    std::string calibrationID;
};
// 配置仅适用于实验 Sony ILCE-7CM2、14-bit full-resolution lossless RAW、black=512/white=16383。
// 解码层另行校验 RAW 模式/归一化；不能由 ISO 查表结果推断其他条件已通过。
NoiseParameters selectNoiseProfile(const std::string& cameraModel, float iso);
NoiseParameters selectNoiseProfile(const RAWBayerSource& source);
} // namespace sony2fuji::ai
