#include "sony2fuji/lut_applicator.h"
#include "lut_interpolation.h"
#include "parallel_pixels.h"
#include <algorithm>
#include <cmath>
#include <iostream>

namespace sony2fuji {
namespace {

inline float vltCoordinate(float x) {
    const float code = x * 4095.f;
    return (code <= 3840.f ? code / 256.f : 15.f + (code - 3840.f) / 255.f) / 16.f;
}

void applyLutBuffer(const RGB* table, int size, const RGB& low, const RGB& high,
    bool isVlt, bool tetrahedral, const RGB* src, RGB* dst, size_t count) {
    const float spanR = high.r - low.r;
    const float spanG = high.g - low.g;
    const float spanB = high.b - low.b;
    const bool unitDomain = low.r == 0.0f && low.g == 0.0f && low.b == 0.0f &&
        high.r == 1.0f && high.g == 1.0f && high.b == 1.0f;
    parallelPixelRanges(count, [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            const RGB& input = src[i];
            float r = std::clamp(unitDomain ? input.r : (input.r - low.r) / spanR, 0.0f, 1.0f);
            float g = std::clamp(unitDomain ? input.g : (input.g - low.g) / spanG, 0.0f, 1.0f);
            float b = std::clamp(unitDomain ? input.b : (input.b - low.b) / spanB, 0.0f, 1.0f);
            if (isVlt) {
                r = vltCoordinate(r);
                g = vltCoordinate(g);
                b = vltCoordinate(b);
            }
            dst[i] = tetrahedral
                ? detail::tetrahedralLUT(table, size, r, g, b)
                : detail::interpolateLUT(table, size, r, g, b);
        }
    });
}

} // namespace

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
        r = vltCoordinate(r); g = vltCoordinate(g); b = vltCoordinate(b);
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

    const bool tetrahedral = lut_->hasColorContract() &&
        lut_->colorContract().interpolation == LUTInterpolation::Tetrahedral;
    applyLutBuffer(lut_->data_.data(), lut_->getSize(), lut_->domainMin(), lut_->domainMax(),
        lut_->isVLT(), tetrahedral, image.pixels.data(), image.pixels.data(), image.pixels.size());
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

    const bool tetrahedral = lut_->hasColorContract() &&
        lut_->colorContract().interpolation == LUTInterpolation::Tetrahedral;
    applyLutBuffer(lut_->data_.data(), lut_->getSize(), lut_->domainMin(), lut_->domainMax(),
        lut_->isVLT(), tetrahedral, input.pixels.data(), output.pixels.data(), input.pixels.size());
    return ErrorCode::Success;
}

RGB LUTApplicator::trilinearInterpolate(float r, float g, float b) const {
    return detail::interpolateLUT(lut_->data_.data(), lut_->getSize(), r, g, b);
}

} // namespace sony2fuji
