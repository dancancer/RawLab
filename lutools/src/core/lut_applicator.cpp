#include "sony2fuji/lut_applicator.h"
#include "lut_interpolation.h"
#include <algorithm>
#include <cmath>
#include <iostream>

#ifdef _OPENMP
namespace {
constexpr size_t kParallelThreshold = 1u << 16;
}
#endif

namespace sony2fuji {

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

    if (lut_->isVLT()) {
        // VLT 的最后一个间隔是 255 个码值；普通 CUBE 的等距坐标会造成偏差。
        auto coordinate = [](float x) { const float code = x*4095.f;
            return (code <= 3840.f ? code/256.f : 15.f+(code-3840.f)/255.f)/16.f; };
        r = coordinate(r); g = coordinate(g); b = coordinate(b);
    }

    if (lut_->hasColorContract() && lut_->colorContract().interpolation == LUTInterpolation::Tetrahedral)
        return detail::tetrahedralLUT(lut_->data_.data(), lut_->getSize(), r, g, b);
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
    return detail::interpolateLUT(lut_->data_.data(), lut_->getSize(), r, g, b);
}

} // namespace sony2fuji
