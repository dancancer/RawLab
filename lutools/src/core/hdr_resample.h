#pragma once
#include "sony2fuji/common.h"
#include "core/parallel_pixels.h"
#include <algorithm>
#include <cstdint>
#include <limits>

namespace sony2fuji::hdr {

template <class Reader>
inline RGB sampleResample(int x, int y, int width, int height, int outputWidth, int outputHeight,
    const Reader& read) {
    if (width <= 0 || height <= 0 || outputWidth <= 0 || outputHeight <= 0 ||
        x < 0 || x >= outputWidth || y < 0 || y >= outputHeight) {
        return {};
    }
    if (width == outputWidth && height == outputHeight) return read(x, y);

    struct AccumRGB {
        double r = 0, g = 0, b = 0;
    };

    const bool downX = outputWidth < width;
    const bool upX = outputWidth > width;
    const uint64_t left = downX ? static_cast<uint64_t>(x) * static_cast<uint64_t>(width) : 0;
    const uint64_t right = downX ? static_cast<uint64_t>(x + 1) * static_cast<uint64_t>(width) : 0;
    const int firstX = downX ? static_cast<int>(left / static_cast<uint64_t>(outputWidth)) : 0;
    const int endX = downX ? static_cast<int>((right - 1) / static_cast<uint64_t>(outputWidth) + 1) : 0;

    int x0 = x, x1 = x;
    double fx = 0.0;
    if (upX) {
        const double sx = width > 1
            ? std::clamp(double(x) * (width - 1) / (outputWidth - 1), 0.0, double(width - 1))
            : 0.0;
        x0 = static_cast<int>(sx);
        x1 = std::min(x0 + 1, width - 1);
        fx = sx - x0;
    }

    const auto sampleRow = [&](int sy) -> AccumRGB {
        if (downX) {
            double rr = 0, gg = 0, bb = 0;
            for (int sx = firstX; sx < endX; ++sx) {
                const uint64_t wx = std::min(right, static_cast<uint64_t>(sx + 1) * static_cast<uint64_t>(outputWidth)) -
                    std::max(left, static_cast<uint64_t>(sx) * static_cast<uint64_t>(outputWidth));
                const RGB p = read(sx, sy);
                const double w = static_cast<double>(wx);
                rr += static_cast<double>(p.r) * w;
                gg += static_cast<double>(p.g) * w;
                bb += static_cast<double>(p.b) * w;
            }
            return {rr, gg, bb};
        }
        if (upX) {
            const RGB p0 = read(x0, sy);
            if (x0 == x1 || fx == 0.0) return {p0.r, p0.g, p0.b};
            const RGB p1 = read(x1, sy);
            return {
                static_cast<double>(p0.r) + (static_cast<double>(p1.r) - static_cast<double>(p0.r)) * fx,
                static_cast<double>(p0.g) + (static_cast<double>(p1.g) - static_cast<double>(p0.g)) * fx,
                static_cast<double>(p0.b) + (static_cast<double>(p1.b) - static_cast<double>(p0.b)) * fx
            };
        }
        const RGB p = read(x, sy);
        return {p.r, p.g, p.b};
    };

    const double normX = downX ? static_cast<double>(width) : 1.0;

    if (outputHeight < height) {
        const uint64_t top = static_cast<uint64_t>(y) * static_cast<uint64_t>(height);
        const uint64_t bottom = static_cast<uint64_t>(y + 1) * static_cast<uint64_t>(height);
        const int firstY = static_cast<int>(top / static_cast<uint64_t>(outputHeight));
        const int endY = static_cast<int>((bottom - 1) / static_cast<uint64_t>(outputHeight) + 1);
        const double norm = normX * static_cast<double>(height);
        double rr = 0, gg = 0, bb = 0;
        for (int sy = firstY; sy < endY; ++sy) {
            const uint64_t wy = std::min(bottom, static_cast<uint64_t>(sy + 1) * static_cast<uint64_t>(outputHeight)) -
                std::max(top, static_cast<uint64_t>(sy) * static_cast<uint64_t>(outputHeight));
            const AccumRGB row = sampleRow(sy);
            const double w = static_cast<double>(wy);
            rr += row.r * w;
            gg += row.g * w;
            bb += row.b * w;
        }
        return {static_cast<float>(rr / norm), static_cast<float>(gg / norm), static_cast<float>(bb / norm)};
    }

    if (outputHeight == height) {
        const AccumRGB row = sampleRow(y);
        return {static_cast<float>(row.r / normX), static_cast<float>(row.g / normX), static_cast<float>(row.b / normX)};
    }

    const double sy = height > 1
        ? std::clamp(double(y) * (height - 1) / (outputHeight - 1), 0.0, double(height - 1))
        : 0.0;
    const int y0 = static_cast<int>(sy);
    const int y1 = std::min(y0 + 1, height - 1);
    const double fy = sy - y0;
    const AccumRGB r0 = sampleRow(y0);
    if (y0 == y1 || fy == 0.0) {
        return {static_cast<float>(r0.r / normX), static_cast<float>(r0.g / normX), static_cast<float>(r0.b / normX)};
    }
    const AccumRGB r1 = sampleRow(y1);
    return {
        static_cast<float>((r0.r + (r1.r - r0.r) * fy) / normX),
        static_cast<float>((r0.g + (r1.g - r0.g) * fy) / normX),
        static_cast<float>((r0.b + (r1.b - r0.b) * fy) / normX)
    };
}

inline ImageData resample(const ImageData& image, uint32_t width, uint32_t height) {
    if (width == 0 || height == 0 || image.width <= 0 || image.height <= 0 ||
        width > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
        height > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
        image.pixels.size() < static_cast<uint64_t>(image.width) * static_cast<uint64_t>(image.height)) {
        return {};
    }
    if (static_cast<uint32_t>(image.width) == width && static_cast<uint32_t>(image.height) == height) {
        return image;
    }
    const int dstW = static_cast<int>(width);
    const int dstH = static_cast<int>(height);
    ImageData output(dstW, dstH);
    parallelRowRanges(dstH, dstW, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            RGB* dstRow = output.pixels.data() + static_cast<size_t>(y) * static_cast<size_t>(dstW);
            for (int x = 0; x < dstW; ++x) {
                dstRow[x] = sampleResample(x, y, image.width, image.height, dstW, dstH,
                    [&](int sx, int sy) { return image.at(sx, sy); });
            }
        }
    });
    return output;
}

} // namespace sony2fuji::hdr
