#include "look_oracle.h"
#include <algorithm>
#include <cmath>
#include <iostream>

#ifdef _OPENMP
namespace {
constexpr size_t kParallelThreshold = 1u << 16;
}
#endif

namespace sony2fuji::look_oracle {

RGB LUT3D::getValue(int r, int g, int b) const {
    if (r < 0 || g < 0 || b < 0 || r >= size_ || g >= size_ || b >= size_) return RGB();
    return data_[static_cast<size_t>((b * size_ + g) * size_ + r)];
}

LUTApplicator::LUTApplicator(std::shared_ptr<LUT3D> lut)
    : lut_(std::move(lut)) {
}

RGB LUTApplicator::apply(const RGB& input) const {
    if (!lut_ || !lut_->isValid()) {
        return input;
    }

    // 将输入值限制在 [0, 1] 范围内
    const auto low = lut_->domainMin();
    const auto high = lut_->domainMax();
    float r = std::clamp((input.r-low.r)/(high.r-low.r), 0.0f, 1.0f);
    float g = std::clamp((input.g-low.g)/(high.g-low.g), 0.0f, 1.0f);
    float b = std::clamp((input.b-low.b)/(high.b-low.b), 0.0f, 1.0f);

    // 应用三线性插值
    return trilinearInterpolate(r, g, b);
}

ErrorCode LUTApplicator::applyToImage(ImageData& image) const {
    if (!lut_ || !lut_->isValid()) {
        return ErrorCode::InvalidFormat;
    }

    if (image.pixels.empty()) {
        return ErrorCode::ProcessingError;
    }

    const size_t pixel_count = image.pixels.size();

    // 对每个像素应用 LUT
#ifdef _OPENMP
#pragma omp parallel for if (pixel_count >= kParallelThreshold)
#endif
    for (size_t i = 0; i < pixel_count; ++i) {
        image.pixels[i] = apply(image.pixels[i]);
    }

    return ErrorCode::Success;
}

ErrorCode LUTApplicator::applyToImage(const ImageData& input, ImageData& output) const {
    if (!lut_ || !lut_->isValid()) {
        return ErrorCode::InvalidFormat;
    }

    if (input.pixels.empty()) {
        return ErrorCode::ProcessingError;
    }

    // 确保输出大小正确
    output.width = input.width;
    output.height = input.height;
    output.pixels.resize(input.pixels.size());

    // 应用 LUT
    const size_t pixel_count = input.pixels.size();
#ifdef _OPENMP
#pragma omp parallel for if (pixel_count >= kParallelThreshold)
#endif
    for (size_t i = 0; i < pixel_count; ++i) {
        output.pixels[i] = apply(input.pixels[i]);
    }

    return ErrorCode::Success;
}

RGB LUTApplicator::trilinearInterpolate(float r, float g, float b) const {
    int lutSize = lut_->getSize();

    // 将 [0, 1] 映射到 [0, lutSize-1]
    float fr = r * (lutSize - 1);
    float fg = g * (lutSize - 1);
    float fb = b * (lutSize - 1);

    // 获取整数部分和小数部分
    int r0 = static_cast<int>(std::floor(fr));
    int g0 = static_cast<int>(std::floor(fg));
    int b0 = static_cast<int>(std::floor(fb));

    int r1 = std::min(r0 + 1, lutSize - 1);
    int g1 = std::min(g0 + 1, lutSize - 1);
    int b1 = std::min(b0 + 1, lutSize - 1);

    // 插值因子
    float dr = fr - r0;
    float dg = fg - g0;
    float db = fb - b0;

    // 获取立方体的8个顶点
    RGB c000 = lut_->getValue(r0, g0, b0);
    RGB c001 = lut_->getValue(r0, g0, b1);
    RGB c010 = lut_->getValue(r0, g1, b0);
    RGB c011 = lut_->getValue(r0, g1, b1);
    RGB c100 = lut_->getValue(r1, g0, b0);
    RGB c101 = lut_->getValue(r1, g0, b1);
    RGB c110 = lut_->getValue(r1, g1, b0);
    RGB c111 = lut_->getValue(r1, g1, b1);

    // 沿 B 轴插值
    RGB c00 = lerpRGB(c000, c001, db);
    RGB c01 = lerpRGB(c010, c011, db);
    RGB c10 = lerpRGB(c100, c101, db);
    RGB c11 = lerpRGB(c110, c111, db);

    // 沿 G 轴插值
    RGB c0 = lerpRGB(c00, c01, dg);
    RGB c1 = lerpRGB(c10, c11, dg);

    // 沿 R 轴插值
    return lerpRGB(c0, c1, dr);
}

} // namespace sony2fuji
