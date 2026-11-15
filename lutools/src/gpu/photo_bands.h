#pragma once

#include "sony2fuji/common.h"
#include <algorithm>
#include <stdexcept>

namespace sony2fuji {

inline constexpr size_t kPhotoTileBytes = 16 * 1024 * 1024;

struct PhotoBand {
    uint32_t rows, first, last;
};

// GLES 和 D3D11 共用输出分带与双线性采样 halo 决策；尺寸始终为整图坐标。
class PhotoBands {
public:
    PhotoBands(uint32_t sourceWidth, uint32_t sourceHeight, uint32_t width, uint32_t height,
               size_t byteLimit, size_t dispatchLimit)
        : sourceHeight_(sourceHeight), height_(height), limit_(byteLimit),
          sourceRowBytes_(size_t(sourceWidth) * sizeof(RGB)),
          scale_(height == 1 ? 0.f : float(sourceHeight - 1) / float(height - 1)) {
        const size_t outputRowBytes = size_t(width) * sizeof(RGB);
        if (!sourceWidth || !sourceHeight || !width || !height ||
            sourceRowBytes_ > limit_ / 2 || outputRowBytes > limit_ || width > dispatchLimit)
            throw std::runtime_error("Image row exceeds compute limits");
        maxRows_ = static_cast<uint32_t>(std::min<size_t>(height, std::min(limit_ / outputRowBytes, dispatchLimit / width)));
    }

    PhotoBand at(uint32_t row) const {
        auto rows = std::min(maxRows_, height_ - row);
        // 两边各多读一行，覆盖 CPU/GPU 浮点舍入在双线性采样边界上的差异。
        const uint32_t first = uint32_t(float(row) * scale_) > 0 ? uint32_t(float(row) * scale_) - 1 : 0;
        auto lastRow = [&](uint32_t n) {
            return std::min(sourceHeight_ - 1, uint32_t(float(row + n - 1) * scale_) + 2);
        };
        while (rows > 1 && size_t(lastRow(rows) - first + 1) * sourceRowBytes_ > limit_) rows = (rows + 1) / 2;
        const auto last = lastRow(rows);
        if (size_t(last - first + 1) * sourceRowBytes_ > limit_)
            throw std::runtime_error("Source halo exceeds the bounded upload budget");
        return {rows, first, last};
    }

private:
    uint32_t sourceHeight_, height_, maxRows_;
    size_t limit_, sourceRowBytes_;
    float scale_;
};

} // namespace sony2fuji
