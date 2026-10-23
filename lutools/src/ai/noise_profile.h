#pragma once
#include <string>
#include <stdexcept>

namespace sony2fuji { struct RAWBayerSource; }

namespace sony2fuji::ai {
struct NoiseParameters {
    float k = 0, b = 0;
    bool interpolated = false;
    int lowerISO = 0, upperISO = 0;
    std::string calibrationID;
    int samples = 0;
    float signalSpan = 0, relativeError = 0;
};
class NoiseEstimateUnavailable : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};
inline constexpr const char* noiseProtocol = "rawlab-bayer-noise-v3:haar-mad-v2:sony-ilce-7cm2-20261022-bce08d93bc36";
// 字符串接口只查询原有标定；source 接口对其他有效 Bayer 估计当前图像的归一化方差。
NoiseParameters selectNoiseProfile(const std::string& cameraModel, float iso);
NoiseParameters selectNoiseProfile(const RAWBayerSource& source);
NoiseParameters estimateRawNoise(const RAWBayerSource& source);
} // namespace sony2fuji::ai
