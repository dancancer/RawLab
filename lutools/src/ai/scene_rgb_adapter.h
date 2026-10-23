#pragma once
#include "dualdn_geometry.h"
#include "sony2fuji/common.h"

namespace sony2fuji::ai {
// 缓存保存未应用基础曝光的线性 sRGB 差值，原始负值和超白不经过模型往返。
inline constexpr const char* sceneRGBProtocol = "rawlab-restormer-scene-v1";
Tensor sceneRGBCorrection(const ImageData& source, float gain, const PredictTile& predict,
                          const Progress& progress = {}, TileGeometry geometry = {640, 64});
void applySceneRGBCorrection(ImageData& image, const Tensor& correction, ColorSpace space, float gain);
} // namespace sony2fuji::ai
