#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/lut_parser.h"
#include <memory>

namespace sony2fuji {

/**
 * @brief LUT 应用器
 *
 * 使用三线性插值将 3D LUT 应用到图像数据
 */
class LUTApplicator {
public:
    explicit LUTApplicator(std::shared_ptr<LUT3D> lut);

    /**
     * @brief 应用 LUT 到单个像素
     * @param input 输入 RGB 值 (范围 [0, 1])
     * @return 输出 RGB 值
     */
    RGB apply(const RGB& input) const;

    /**
     * @brief 应用 LUT 到整张图像
     * @param image 输入/输出图像数据
     * @return 错误码
     */
    ErrorCode applyToImage(ImageData& image) const;

    /**
     * @brief 应用 LUT 到图像 (in-place)
     * @param input 输入图像
     * @param output 输出图像
     * @return 错误码
     */
    ErrorCode applyToImage(const ImageData& input, ImageData& output) const;

private:
    std::shared_ptr<LUT3D> lut_;

    /**
     * @brief 三线性插值
     * @param r, g, b 归一化的输入颜色值 [0, 1]
     * @return 插值后的 RGB 值
     */
    RGB trilinearInterpolate(float r, float g, float b) const;

};

} // namespace sony2fuji
