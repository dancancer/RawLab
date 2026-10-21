#pragma once

#include "sony2fuji/common.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <optional>
#include <stdexcept>

namespace denoise_quality {

struct Region { int x, y, width, height; };

inline Region pixelRegion(int width, int height, const std::array<double, 4>& rect) {
    if (width <= 0 || height <= 0) throw std::invalid_argument("invalid image dimensions");
    for (double value : rect)
        if (!std::isfinite(value)) throw std::invalid_argument("nonfinite region");
    if (rect[0] < 0 || rect[1] < 0 || rect[2] <= 0 || rect[3] <= 0 ||
        rect[0] + rect[2] > 1 + 1e-12 || rect[1] + rect[3] > 1 + 1e-12)
        throw std::invalid_argument("region must be inside the image");
    const int x = static_cast<int>(std::floor(rect[0] * width));
    const int y = static_cast<int>(std::floor(rect[1] * height));
    const int right = std::min(width, static_cast<int>(std::ceil((rect[0] + rect[2]) * width)));
    const int bottom = std::min(height, static_cast<int>(std::ceil((rect[1] + rect[3]) * height)));
    return {x, y, right - x, bottom - y};
}

struct ReferenceError {
    double rgbRmse = 0, lumaRmse = 0, chromaRmse = 0;
    std::array<double, 3> meanRgbError{};
    std::optional<double> lumaContrastGain;
    std::optional<double> lumaLaplacianGain, referenceLaplacianRms;
};

struct Metrics {
    double lumaMean = 0, lumaStddev = 0, chromaStddev = 0;
    std::optional<ReferenceError> referenceError;
};

struct Moments {
    size_t count = 0;
    double mean = 0, squared = 0;
    void add(double value) {
        ++count;
        const double delta = value - mean;
        mean += delta / count;
        squared += delta * (value - mean);
    }
    double variance() const { return std::max(0.0, squared / count); }
};

inline bool validImage(const sony2fuji::ImageData& image) {
    return image.width > 0 && image.height > 0 &&
        image.pixels.size() == static_cast<size_t>(image.width) * image.height;
}

inline Metrics measure(const sony2fuji::ImageData& image, const sony2fuji::ImageData* reference,
                       const Region& roi) {
    if (!validImage(image) || roi.x < 0 || roi.y < 0 || roi.width <= 0 || roi.height <= 0 ||
        roi.width > image.width - roi.x || roi.height > image.height - roi.y ||
        (reference && (!validImage(*reference) || reference->width != image.width || reference->height != image.height)))
        throw std::invalid_argument("invalid image, reference dimensions or region");
    Moments luma, rg, bg, referenceLuma;
    ReferenceError error;
    double product = 0;
    for (int y = roi.y; y < roi.y + roi.height; ++y) for (int x = roi.x; x < roi.x + roi.width; ++x) {
        const auto& p = image.at(x, y);
        if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b))
            throw std::invalid_argument("nonfinite image pixel");
        const double value = (double(p.r) + p.g + p.b) / 3;
        luma.add(value); rg.add(double(p.r) - p.g); bg.add(double(p.b) - p.g);
        if (reference) {
            const auto& q = reference->at(x, y);
            if (!std::isfinite(q.r) || !std::isfinite(q.g) || !std::isfinite(q.b))
                throw std::invalid_argument("nonfinite reference pixel");
            const double target = (double(q.r) + q.g + q.b) / 3;
            const double dr = double(p.r) - q.r, dg = double(p.g) - q.g, db = double(p.b) - q.b;
            error.rgbRmse += dr * dr + dg * dg + db * db;
            error.lumaRmse += (value - target) * (value - target);
            error.chromaRmse += (dr - dg) * (dr - dg) + (db - dg) * (db - dg);
            error.meanRgbError[0] += dr; error.meanRgbError[1] += dg; error.meanRgbError[2] += db;
            referenceLuma.add(target);
            product += value * target;
        }
    }
    Metrics result{luma.mean, std::sqrt(luma.variance()), std::sqrt((rg.variance() + bg.variance()) / 2), {}};
    if (reference) {
        error.rgbRmse = std::sqrt(error.rgbRmse / (3 * luma.count));
        error.lumaRmse = std::sqrt(error.lumaRmse / luma.count);
        error.chromaRmse = std::sqrt(error.chromaRmse / (2 * luma.count));
        for (auto& value : error.meanRgbError) value /= luma.count;
        if (referenceLuma.variance() > 1e-20)
            error.lumaContrastGain = (product / luma.count - luma.mean * referenceLuma.mean) / referenceLuma.variance();
        if (roi.width >= 3 && roi.height >= 3) {
            const auto lumaAt = [](const sony2fuji::ImageData& data, int x, int y) {
                const auto& p = data.at(x, y);
                return (double(p.r) + p.g + p.b) / 3;
            };
            const auto laplacian = [&](const sony2fuji::ImageData& data, int x, int y) {
                return lumaAt(data, x, y) - .25 * (lumaAt(data, x-1, y) + lumaAt(data, x+1, y) +
                    lumaAt(data, x, y-1) + lumaAt(data, x, y+1));
            };
            double targetSquared = 0, product = 0;
            for (int y = roi.y+1; y < roi.y+roi.height-1; ++y)
                for (int x = roi.x+1; x < roi.x+roi.width-1; ++x) {
                    const double target = laplacian(*reference, x, y);
                    targetSquared += target * target;
                    product += laplacian(image, x, y) * target;
                }
            const double count = double(roi.width-2) * (roi.height-2);
            error.referenceLaplacianRms = std::sqrt(targetSquared / count);
            // 参考能量同时输出，避免把平坦区或参考噪声中的不稳定投影当作细节质量。
            if (*error.referenceLaplacianRms > 1e-10)
                error.lumaLaplacianGain = product / targetSquared;
        }
        result.referenceError = error;
    }
    return result;
}

} // namespace denoise_quality
