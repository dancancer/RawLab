#pragma once
#include "sony2fuji/color_converter.h"
#include "sony2fuji/lut_parser.h"
#include <algorithm>
#include <cmath>
#include <memory>

/* df4dc03 的函数体原样保留；仅测试使用，不随优化更新。 */
namespace sony2fuji::look_oracle {
class LUT3D {
public:
    LUT3D(int size, std::vector<RGB> data, RGB low = {0, 0, 0}, RGB high = {1, 1, 1})
        : size_(size), data_(std::move(data)), low_(low), high_(high) {}
    int getSize() const { return size_; }
    bool isValid() const { return size_ > 0 && !data_.empty(); }
    const RGB& domainMin() const { return low_; }
    const RGB& domainMax() const { return high_; }
    RGB getValue(int r, int g, int b) const;
private:
    int size_;
    std::vector<RGB> data_;
    RGB low_, high_;
};

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
    /* 原样 oracle 保留 NaN 强转；仅豁免其已知检查，生产路径不豁免。 */
#if defined(__clang__)
    __attribute__((no_sanitize("float-cast-overflow")))
#endif
    RGB trilinearInterpolate(float r, float g, float b) const;

    /**
     * @brief 线性插值辅助函数
     */
    static float lerp(float a, float b, float t) {
        return a + t * (b - a);
    }

    /**
     * @brief RGB 线性插值
     */
    static RGB lerpRGB(const RGB& a, const RGB& b, float t) {
        return RGB(
            lerp(a.r, b.r, t),
            lerp(a.g, b.g, t),
            lerp(a.b, b.b, t)
        );
    }
};

class GammaConverter : public sony2fuji::GammaConverter {
public:
    static float applySRGBGamma(float linear);
    static float applyFLog2(float linear);
    static RGB applyFLog2ToRGB(const RGB& rgb);
    static FLog2Diagnostics applyFLog2ToImage(ImageData& image, const FLog2Options& options);
};

inline float neutralDisplay(float linear) {
    if (linear<=0) return 0;
    constexpr float gray=.1845f;
    const float shoulder=(1-gray)/gray*std::pow(gray/linear,1.5f);
    return GammaConverter::applySRGBGamma(1/(1+shoulder));
}
} // namespace sony2fuji::look_oracle
