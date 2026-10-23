#pragma once
#include "dualdn_geometry.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/raw_processor.h"

namespace sony2fuji::ai {
using Matrix = ColorConverter::Matrix3x3;
Matrix officialCameraToXYZ(const RAWBayerSource& source);
bool supportsDualDnBridge(const RAWBayerSource& source);
float inverseRec709(float encoded);
// 输入为 canonical RGGB 的 sensor 坐标。输出仍为 camera 通道，交给原生显影应用矩阵/曝光。
Tensor rgbCameraCorrection(const Tensor& denoisedMosaic, const Tensor& noisyMosaic, const Tensor& skip, const Tensor& result,
                           const std::array<float, 4>& wb, const Matrix& cameraToXYZ);
} // namespace sony2fuji::ai
