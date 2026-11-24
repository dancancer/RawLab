#include "core/photo_geometry.h"
#include "core/parallel_pixels.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <new>
#include <stdexcept>

namespace sony2fuji {
namespace {

struct Point {
    double x, y;
};

struct Canvas {
    int rotated_width, rotated_height;
    int width, height;
    int left, top, right, bottom;
    double cosine, sine;
};

Canvas canvasFor(int width, int height, const GeometryOptions& options) {
    constexpr double radians = 3.14159265358979323846 / 180;
    Canvas canvas{};
    canvas.rotated_width = options.quarter_turns % 2 ? height : width;
    canvas.rotated_height = options.quarter_turns % 2 ? width : height;
    canvas.cosine = std::cos(options.straighten_degrees * radians);
    canvas.sine = std::sin(options.straighten_degrees * radians);
    const double sine = std::abs(canvas.sine);
    const double perspective_scale = 1 / (1 + .25 * std::abs(options.perspective_horizontal) +
        .25 * std::abs(options.perspective_vertical));
    const double w = std::max(1, static_cast<int>(std::floor(canvas.rotated_width * perspective_scale)));
    const double h = std::max(1, static_cast<int>(std::floor(canvas.rotated_height * perspective_scale)));
    const double scale = std::min(w / (w * canvas.cosine + h * sine),
        h / (w * sine + h * canvas.cosine));
    canvas.width = std::max(1, static_cast<int>(std::floor(w * scale)));
    canvas.height = std::max(1, static_cast<int>(std::floor(h * scale)));
    canvas.left = static_cast<int>(std::floor(double(options.crop_x) * canvas.width));
    canvas.top = static_cast<int>(std::floor(double(options.crop_y) * canvas.height));
    // Clamp the small normalized-edge tolerance accepted at Float UI boundaries.
    canvas.right = std::min(canvas.width, std::max(canvas.left + 1,
        static_cast<int>(std::ceil(std::min(1.0,
            double(options.crop_x) + options.crop_width) * canvas.width))));
    canvas.bottom = std::min(canvas.height, std::max(canvas.top + 1,
        static_cast<int>(std::ceil(std::min(1.0,
            double(options.crop_y) + options.crop_height) * canvas.height))));
    return canvas;
}

Point sourcePoint(Point point, const Canvas& canvas, const GeometryOptions& options,
    int width, int height) {
    if (options.flip_horizontal) point.x = canvas.rotated_width - 1 - point.x;
    if (options.flip_vertical) point.y = canvas.rotated_height - 1 - point.y;
    switch (options.quarter_turns) {
        case 1: return {point.y, height - 1 - point.x};
        case 2: return {width - 1 - point.x, height - 1 - point.y};
        case 3: return {width - 1 - point.y, point.x};
        default: return point;
    }
}

RGB interpolate(const RGB& first, const RGB& second, float fraction) {
    return {first.r + (second.r - first.r) * fraction,
        first.g + (second.g - first.g) * fraction,
        first.b + (second.b - first.b) * fraction};
}

template<class Reader> RGB sampleBilinear(int width, int height, const Reader& read, Point point) {
    // Pixels cover half a pixel past their centers. Extend those edge pixels
    // when the inscribed canvas samples that support; never introduce black.
    const double x = std::clamp(point.x, 0.0, double(width - 1));
    const double y = std::clamp(point.y, 0.0, double(height - 1));
    // 钳位后非负，截断等同 floor。
    const int left = static_cast<int>(x), top = static_cast<int>(y);
    const int right = std::min(left + 1, width - 1);
    const int bottom = std::min(top + 1, height - 1);
    const float dx = static_cast<float>(x - left), dy = static_cast<float>(y - top);
    return interpolate(interpolate(read(left, top), read(right, top), dx),
        interpolate(read(left, bottom), read(right, bottom), dx), dy);
}

bool tryTransformedPoint(double x, double y, const Canvas& canvas, const GeometryOptions& options, Point& out) {
    const double dy = canvas.top + y - (canvas.height - 1) * .5;
    const double dx = canvas.left + x - (canvas.width - 1) * .5;
    // 两种存储路径共用乘加顺序，不累加坐标或改用倒数。
    const double rotated_x = canvas.cosine * dx + canvas.sine * dy;
    const double rotated_y = -canvas.sine * dx + canvas.cosine * dy;
    const double denominator = 1 + .25 * options.perspective_horizontal * (2 * rotated_x / canvas.rotated_width) +
        .25 * options.perspective_vertical * (2 * rotated_y / canvas.rotated_height);
    if (std::abs(denominator) <= 1e-6) return false;
    out = {(canvas.rotated_width - 1) * .5 + rotated_x / denominator,
        (canvas.rotated_height - 1) * .5 + rotated_y / denominator};
    return true;
}

Point transformedPoint(double x, double y, const Canvas& canvas, const GeometryOptions& options) {
    Point out{};
    if (tryTransformedPoint(x, y, canvas, options, out)) return out;
    const double dy = canvas.top + y - (canvas.height - 1) * .5;
    const double dx = canvas.left + x - (canvas.width - 1) * .5;
    const double rotated_x = canvas.cosine * dx + canvas.sine * dy;
    const double rotated_y = -canvas.sine * dx + canvas.cosine * dy;
    const double denominator = 1 + .25 * options.perspective_horizontal * (2 * rotated_x / canvas.rotated_width) +
        .25 * options.perspective_vertical * (2 * rotated_y / canvas.rotated_height);
    return {(canvas.rotated_width - 1) * .5 + rotated_x / denominator,
        (canvas.rotated_height - 1) * .5 + rotated_y / denominator};
}

void copyRectangle(const RGB* source, RGB* target, int width, int height,
    ptrdiff_t step_x, ptrdiff_t step_y, int target_stride) {
    for (int y = 0; y < height; ++y) {
        checkProcessingCancellation();
        const auto* source_row = source + y * step_y;
        auto* target_row = target + size_t(y) * target_stride;
        if (step_x == 1) {
            std::copy_n(source_row, width, target_row);
        } else {
            for (int x = 0; x < width; ++x) target_row[x] = source_row[x * step_x];
        }
    }
}

void copyInteger(const ImageData& image, ImageData& result, const Canvas& canvas,
    const GeometryOptions& options) {
    const Point origin = sourcePoint({double(canvas.left), double(canvas.top)}, canvas,
        options, image.width, image.height);
    const Point next_x = sourcePoint({double(canvas.left) + 1, double(canvas.top)}, canvas,
        options, image.width, image.height);
    const Point next_y = sourcePoint({double(canvas.left), double(canvas.top) + 1}, canvas,
        options, image.width, image.height);
    const ptrdiff_t start = ptrdiff_t(origin.y) * image.width + ptrdiff_t(origin.x);
    const ptrdiff_t step_x = ptrdiff_t(next_x.y - origin.y) * image.width + ptrdiff_t(next_x.x - origin.x);
    const ptrdiff_t step_y = ptrdiff_t(next_y.y - origin.y) * image.width + ptrdiff_t(next_y.x - origin.x);
    // 转置分块，让源图与目标图的局部行留在缓存中。
    const int tile_width = options.quarter_turns % 2 ? 32 : result.width;
    const int tile_height = options.quarter_turns % 2 ? 32 : result.height;
    for (int top = 0; top < result.height;) {
        checkProcessingCancellation();
        const int bottom = top + std::min(tile_height, result.height - top);
        for (int left = 0; left < result.width;) {
            const int right = left + std::min(tile_width, result.width - left);
            const auto* source = image.pixels.data() + start + top * step_y + left * step_x;
            auto* target = result.pixels.data() + size_t(top) * result.width + left;
            copyRectangle(source, target, right - left, bottom - top, step_x, step_y, result.width);
            left = right;
        }
        top = bottom;
    }
}

void resample(const ImageData& image, ImageData& result, const Canvas& canvas,
    const GeometryOptions& options) {
    parallelRowRanges(result.height, result.width, [&](int firstRow, int lastRow) {
        std::array<Point, 256> points;
        for (int y = firstRow; y < lastRow; ++y) {
            auto* target = result.pixels.data() + size_t(y) * result.width;
            for (int begin = 0; begin < result.width;) {
                const int count = std::min(int(points.size()), result.width - begin);
                // 分批计算坐标，让独立除法流水执行。
                for (int i = 0; i < count; ++i) {
                    points[i] = transformedPoint(begin + i, y, canvas, options);
                }
                for (int i = 0; i < count; ++i)
                    target[begin + i] = sampleBilinear(image.width, image.height,
                        [&](int x, int y) { return image.at(x, y); },
                        sourcePoint(points[i], canvas, options, image.width, image.height));
                begin += count;
            }
        }
    });
}

} // namespace

bool GeometryOptions::valid() const {
    return std::isfinite(crop_x) && std::isfinite(crop_y) && std::isfinite(crop_width) &&
        std::isfinite(crop_height) && std::isfinite(straighten_degrees) &&
        std::isfinite(perspective_horizontal) && std::isfinite(perspective_vertical) &&
        crop_x >= 0 && crop_y >= 0 && crop_x < 1 && crop_y < 1 &&
        crop_width > 0 && crop_height > 0 && double(crop_x) + crop_width <= 1.000001 &&
        double(crop_y) + crop_height <= 1.000001 && quarter_turns >= 0 && quarter_turns <= 3 &&
        straighten_degrees >= -45 && straighten_degrees <= 45 &&
        perspective_horizontal >= -1 && perspective_horizontal <= 1 &&
        perspective_vertical >= -1 && perspective_vertical <= 1;
}

bool GeometryOptions::active() const {
    return crop_x != 0 || crop_y != 0 || crop_width != 1 || crop_height != 1 ||
        quarter_turns != 0 || flip_horizontal || flip_vertical || straighten_degrees != 0 ||
        perspective_horizontal != 0 || perspective_vertical != 0;
}

std::pair<int, int> geometryOutputSize(int width, int height, const GeometryOptions& options) {
    if (width <= 0 || height <= 0 || !options.valid()) return {0, 0};
    const auto canvas = canvasFor(width, height, options);
    return {canvas.right - canvas.left, canvas.bottom - canvas.top};
}

std::pair<int, int> geometryInferSourceSize(int outputWidth, int outputHeight,
    const GeometryOptions& options) {
    if (outputWidth <= 0 || outputHeight <= 0 || !options.valid()) return {0, 0};
    if (!options.active()) return {outputWidth, outputHeight};
    constexpr double radiansPerDeg = 3.14159265358979323846 / 180.0;
    const double radians = double(options.straighten_degrees) * radiansPerDeg;
    const double cosine = std::cos(radians);
    const double absSine = std::abs(std::sin(radians));
    const double perspScale = 1.0 / (1.0 + 0.25 * std::abs(double(options.perspective_horizontal)) +
        0.25 * std::abs(double(options.perspective_vertical)));
    const double cw = double(outputWidth) / std::max(0.0001, double(options.crop_width));
    const double ch = double(outputHeight) / std::max(0.0001, double(options.crop_height));
    const double straightenScale = std::min(cw / (cw * cosine + ch * absSine),
        ch / (cw * absSine + ch * cosine));
    const double denomScale = std::max(1e-4, perspScale * straightenScale);
    const int rw = std::max(1, static_cast<int>(std::llround(cw / denomScale)));
    const int rh = std::max(1, static_cast<int>(std::llround(ch / denomScale)));
    const int turns = ((options.quarter_turns % 4) + 4) % 4;
    return (turns % 2 != 0) ? std::make_pair(rh, rw) : std::make_pair(rw, rh);
}

bool geometryOutputNormToSourceNorm(int sourceWidth, int sourceHeight,
    const GeometryOptions& options, double outX, double outY,
    double& outSourceX, double& outSourceY) {
    if (sourceWidth <= 0 || sourceHeight <= 0 || !options.valid() ||
        !std::isfinite(outX) || !std::isfinite(outY) ||
        outX < -1e-4 || outX > 1.0 + 1e-4 || outY < -1e-4 || outY > 1.0 + 1e-4) {
        return false;
    }
    const double clampedOutX = std::clamp(outX, 0.0, 1.0);
    const double clampedOutY = std::clamp(outY, 0.0, 1.0);
    if (!options.active()) {
        outSourceX = clampedOutX;
        outSourceY = clampedOutY;
        return true;
    }
    const Canvas canvas = canvasFor(sourceWidth, sourceHeight, options);
    const double outW = double(canvas.right - canvas.left);
    const double outH = double(canvas.bottom - canvas.top);
    const double x = clampedOutX * outW - 0.5;
    const double y = clampedOutY * outH - 0.5;
    Point perspectivePt{};
    if (!tryTransformedPoint(x, y, canvas, options, perspectivePt)) {
        return false;
    }
    const Point src = sourcePoint(perspectivePt, canvas, options, sourceWidth, sourceHeight);
    const double uSrc = (src.x + 0.5) / double(sourceWidth);
    const double vSrc = (src.y + 0.5) / double(sourceHeight);
    if (uSrc < -1e-3 || uSrc > 1.0 + 1e-3 || vSrc < -1e-3 || vSrc > 1.0 + 1e-3) {
        return false;
    }
    outSourceX = std::clamp(uSrc, 0.0, 1.0);
    outSourceY = std::clamp(vSrc, 0.0, 1.0);
    return true;
}

bool geometrySourceNormToOutputNorm(int sourceWidth, int sourceHeight,
    const GeometryOptions& options, double srcX, double srcY,
    double& outOutputX, double& outOutputY) {
    if (sourceWidth <= 0 || sourceHeight <= 0 || !options.valid() ||
        !std::isfinite(srcX) || !std::isfinite(srcY) ||
        srcX < -1e-4 || srcX > 1.0 + 1e-4 || srcY < -1e-4 || srcY > 1.0 + 1.0e-4) {
        return false;
    }
    const double clampedSrcX = std::clamp(srcX, 0.0, 1.0);
    const double clampedSrcY = std::clamp(srcY, 0.0, 1.0);
    if (!options.active()) {
        outOutputX = clampedSrcX;
        outOutputY = clampedSrcY;
        return true;
    }
    const Canvas canvas = canvasFor(sourceWidth, sourceHeight, options);
    const double sx = clampedSrcX * double(sourceWidth) - 0.5;
    const double sy = clampedSrcY * double(sourceHeight) - 0.5;
    const int turns = ((options.quarter_turns % 4) + 4) % 4;
    double px = sx;
    double py = sy;
    switch (turns) {
        case 1:
            px = double(sourceHeight - 1) - sy;
            py = sx;
            break;
        case 2:
            px = double(sourceWidth - 1) - sx;
            py = double(sourceHeight - 1) - sy;
            break;
        case 3:
            px = sy;
            py = double(sourceWidth - 1) - sx;
            break;
        default:
            break;
    }
    if (options.flip_horizontal) px = double(canvas.rotated_width - 1) - px;
    if (options.flip_vertical) py = double(canvas.rotated_height - 1) - py;

    const double ax = px - double(canvas.rotated_width - 1) * 0.5;
    const double ay = py - double(canvas.rotated_height - 1) * 0.5;
    const double ch = 0.5 * double(options.perspective_horizontal) / double(canvas.rotated_width);
    const double cv = 0.5 * double(options.perspective_vertical) / double(canvas.rotated_height);
    const double denom = 1.0 - ch * ax - cv * ay;
    if (denom <= 1e-6) {
        return false;
    }
    const double rx = ax / denom;
    const double ry = ay / denom;
    const double dx = canvas.cosine * rx - canvas.sine * ry;
    const double dy = canvas.sine * rx + canvas.cosine * ry;
    const double cx = dx + double(canvas.width - 1) * 0.5;
    const double cy = dy + double(canvas.height - 1) * 0.5;
    const double x = cx - double(canvas.left);
    const double y = cy - double(canvas.top);
    const double outW = double(canvas.right - canvas.left);
    const double outH = double(canvas.bottom - canvas.top);
    const double uOut = (x + 0.5) / outW;
    const double vOut = (y + 0.5) / outH;
    if (uOut < -1e-4 || uOut > 1.0 + 1e-4 || vOut < -1e-4 || vOut > 1.0 + 1e-4) {
        return false;
    }
    outOutputX = std::clamp(uOut, 0.0, 1.0);
    outOutputY = std::clamp(vOut, 0.0, 1.0);
    return true;
}

OutputRoiPlan computeOutputRoiPlan(int fullNativeWidth, int fullNativeHeight,
    double normX0, double normY0, double normX1, double normY1, uint32_t maxOutputLongEdge) {
    OutputRoiPlan plan;
    if (fullNativeWidth <= 0 || fullNativeHeight <= 0 ||
        !std::isfinite(normX0) || !std::isfinite(normY0) ||
        !std::isfinite(normX1) || !std::isfinite(normY1) ||
        normX0 < 0.0 || normY0 < 0.0 || normX1 > 1.0 || normY1 > 1.0 ||
        normX0 >= normX1 || normY0 >= normY1) {
        return plan;
    }
    plan.fullNativeWidth = fullNativeWidth;
    plan.fullNativeHeight = fullNativeHeight;
    plan.ox0 = std::clamp(int(std::floor(normX0 * fullNativeWidth)), 0, fullNativeWidth - 1);
    plan.oy0 = std::clamp(int(std::floor(normY0 * fullNativeHeight)), 0, fullNativeHeight - 1);
    plan.ox1 = std::clamp(int(std::ceil(normX1 * fullNativeWidth)), plan.ox0 + 1, fullNativeWidth);
    plan.oy1 = std::clamp(int(std::ceil(normY1 * fullNativeHeight)), plan.oy0 + 1, fullNativeHeight);
    const int roiW = plan.ox1 - plan.ox0;
    const int roiH = plan.oy1 - plan.oy0;
    const int roiLong = std::max(roiW, roiH);
    if (maxOutputLongEdge == 0 || uint32_t(roiLong) <= maxOutputLongEdge) {
        plan.outputWidth = roiW;
        plan.outputHeight = roiH;
    } else {
        const double scale = double(maxOutputLongEdge) / double(roiLong);
        plan.outputWidth = std::clamp(int(std::lround(roiW * scale)), 1, std::min(roiW, int(maxOutputLongEdge)));
        plan.outputHeight = std::clamp(int(std::lround(roiH * scale)), 1, std::min(roiH, int(maxOutputLongEdge)));
    }
    return plan;
}

RoiSubRect computeGeometrySourceBounds(int fullSourceWidth, int fullSourceHeight,
    const GeometryOptions& options, int ox0, int oy0, int ox1, int oy1, int padding) {
    if (fullSourceWidth <= 0 || fullSourceHeight <= 0 || !options.valid() || ox0 >= ox1 || oy0 >= oy1) {
        return {};
    }
    const int pad = std::max(0, padding);
    if (!options.active()) {
        return {
            std::clamp(ox0 - pad, 0, fullSourceWidth - 1),
            std::clamp(oy0 - pad, 0, fullSourceHeight - 1),
            std::clamp(ox1 + pad, 1, fullSourceWidth),
            std::clamp(oy1 + pad, 1, fullSourceHeight)
        };
    }
    const auto sampler = makeGeometrySampler(fullSourceWidth, fullSourceHeight, options);
    int minX = fullSourceWidth;
    int minY = fullSourceHeight;
    int maxX = -1;
    int maxY = -1;
    const GeometryPixelReader tracker = [&](int sx, int sy) -> RGB {
        const int cx = std::clamp(sx, 0, fullSourceWidth - 1);
        const int cy = std::clamp(sy, 0, fullSourceHeight - 1);
        minX = std::min(minX, cx);
        minY = std::min(minY, cy);
        maxX = std::max(maxX, cx);
        maxY = std::max(maxY, cy);
        return {};
    };
    const int rx1 = ox1 - 1;
    const int ry1 = oy1 - 1;
    for (int ox = ox0; ox <= rx1; ++ox) {
        sampler(ox, oy0, tracker);
        if (ry1 != oy0) sampler(ox, ry1, tracker);
    }
    for (int oy = oy0 + 1; oy < ry1; ++oy) {
        sampler(ox0, oy, tracker);
        if (rx1 != ox0) sampler(rx1, oy, tracker);
    }
    const int stepX = std::max(1, (ox1 - ox0) / 16);
    const int stepY = std::max(1, (oy1 - oy0) / 16);
    for (int oy = oy0; oy <= ry1; oy += stepY) {
        for (int ox = ox0; ox <= rx1; ox += stepX) {
            sampler(ox, oy, tracker);
        }
    }
    if (maxX < minX || maxY < minY) {
        return {0, 0, std::min(fullSourceWidth, 1), std::min(fullSourceHeight, 1)};
    }
    return {
        std::clamp(minX - pad, 0, fullSourceWidth - 1),
        std::clamp(minY - pad, 0, fullSourceHeight - 1),
        std::clamp(maxX + 1 + pad, 1, fullSourceWidth),
        std::clamp(maxY + 1 + pad, 1, fullSourceHeight)
    };
}

ImageData applyGeometryROI(const ImageData& srcSubRect, const RoiSubRect& srcRect,
    int fullSourceWidth, int fullSourceHeight, const GeometryOptions& options,
    const OutputRoiPlan& plan) {
    if (srcSubRect.width <= 0 || srcSubRect.height <= 0 || srcRect.empty() ||
        fullSourceWidth <= 0 || fullSourceHeight <= 0 || !options.valid() || !plan.valid()) {
        return {};
    }
    auto sampleSubRectBilinear = [&](double lx, double ly) -> RGB {
        const double cx = std::clamp(lx, 0.0, double(srcSubRect.width - 1));
        const double cy = std::clamp(ly, 0.0, double(srcSubRect.height - 1));
        const int x0 = int(std::floor(cx));
        const int y0 = int(std::floor(cy));
        const int x1 = std::min(srcSubRect.width - 1, x0 + 1);
        const int y1 = std::min(srcSubRect.height - 1, y0 + 1);
        const float tx = float(cx - x0);
        const float ty = float(cy - y0);
        const RGB& p00 = srcSubRect.at(x0, y0);
        const RGB& p10 = srcSubRect.at(x1, y0);
        const RGB& p01 = srcSubRect.at(x0, y1);
        const RGB& p11 = srcSubRect.at(x1, y1);
        auto lerp = [](float a, float b, float t) { return a + (b - a) * t; };
        const RGB top{lerp(p00.r, p10.r, tx), lerp(p00.g, p10.g, tx), lerp(p00.b, p10.b, tx)};
        const RGB bot{lerp(p01.r, p11.r, tx), lerp(p01.g, p11.g, tx), lerp(p01.b, p11.b, tx)};
        return {lerp(top.r, bot.r, ty), lerp(top.g, bot.g, ty), lerp(top.b, bot.b, ty)};
    };

    const bool exactSource = srcSubRect.width == srcRect.width() && srcSubRect.height == srcRect.height();
    const bool oneToOne = plan.outputWidth == plan.nativeWidth() && plan.outputHeight == plan.nativeHeight();
    ImageData output(plan.outputWidth, plan.outputHeight);

    if (!options.active()) {
        if (oneToOne && exactSource) {
            for (int ty = 0; ty < plan.outputHeight; ++ty) {
                const int sy = std::clamp(plan.oy0 + ty - srcRect.y0, 0, srcSubRect.height - 1);
                for (int tx = 0; tx < plan.outputWidth; ++tx) {
                    const int sx = std::clamp(plan.ox0 + tx - srcRect.x0, 0, srcSubRect.width - 1);
                    output.at(tx, ty) = srcSubRect.at(sx, sy);
                }
            }
            return output;
        }
        const double sxScale = double(srcSubRect.width) / double(srcRect.width());
        const double syScale = double(srcSubRect.height) / double(srcRect.height());
        for (int ty = 0; ty < plan.outputHeight; ++ty) {
            const double oy = oneToOne ? double(plan.oy0 + ty)
                : plan.oy0 + (double(ty) + 0.5) * plan.nativeHeight() / double(plan.outputHeight) - 0.5;
            const double ly = (oy + 0.5 - srcRect.y0) * syScale - 0.5;
            for (int tx = 0; tx < plan.outputWidth; ++tx) {
                const double ox = oneToOne ? double(plan.ox0 + tx)
                    : plan.ox0 + (double(tx) + 0.5) * plan.nativeWidth() / double(plan.outputWidth) - 0.5;
                const double lx = (ox + 0.5 - srcRect.x0) * sxScale - 0.5;
                output.at(tx, ty) = sampleSubRectBilinear(lx, ly);
            }
        }
        return output;
    }

    const auto sampler = makeGeometrySampler(fullSourceWidth, fullSourceHeight, options);
    const GeometryPixelReader reader = [&](int sx, int sy) -> RGB {
        if (exactSource) {
            return srcSubRect.at(
                std::clamp(sx - srcRect.x0, 0, srcSubRect.width - 1),
                std::clamp(sy - srcRect.y0, 0, srcSubRect.height - 1));
        }
        const double lx = (double(sx) + 0.5 - srcRect.x0) * srcSubRect.width / double(srcRect.width()) - 0.5;
        const double ly = (double(sy) + 0.5 - srcRect.y0) * srcSubRect.height / double(srcRect.height()) - 0.5;
        return sampleSubRectBilinear(lx, ly);
    };

    if (oneToOne) {
        for (int ty = 0; ty < plan.outputHeight; ++ty) {
            const int oy = plan.oy0 + ty;
            for (int tx = 0; tx < plan.outputWidth; ++tx) {
                output.at(tx, ty) = sampler(plan.ox0 + tx, oy, reader);
            }
        }
        return output;
    }

    for (int ty = 0; ty < plan.outputHeight; ++ty) {
        const double oy = std::clamp(
            plan.oy0 + (double(ty) + 0.5) * plan.nativeHeight() / double(plan.outputHeight) - 0.5,
            double(plan.oy0), double(plan.oy1 - 1));
        const int y0 = int(std::floor(oy));
        const int y1 = std::min(plan.oy1 - 1, y0 + 1);
        const float wy = float(oy - y0);
        for (int tx = 0; tx < plan.outputWidth; ++tx) {
            const double ox = std::clamp(
                plan.ox0 + (double(tx) + 0.5) * plan.nativeWidth() / double(plan.outputWidth) - 0.5,
                double(plan.ox0), double(plan.ox1 - 1));
            const int x0 = int(std::floor(ox));
            const int x1 = std::min(plan.ox1 - 1, x0 + 1);
            const float wx = float(ox - x0);
            const RGB c00 = sampler(x0, y0, reader);
            const RGB c10 = sampler(x1, y0, reader);
            const RGB c01 = sampler(x0, y1, reader);
            const RGB c11 = sampler(x1, y1, reader);
            auto lerp = [](float a, float b, float t) { return a + (b - a) * t; };
            const RGB top{lerp(c00.r, c10.r, wx), lerp(c00.g, c10.g, wx), lerp(c00.b, c10.b, wx)};
            const RGB bot{lerp(c01.r, c11.r, wx), lerp(c01.g, c11.g, wx), lerp(c01.b, c11.b, wx)};
            output.at(tx, ty) = {lerp(top.r, bot.r, wy), lerp(top.g, bot.g, wy), lerp(top.b, bot.b, wy)};
        }
    }
    return output;
}

GeometryPixelSampler makeGeometrySampler(int width, int height, const GeometryOptions& options) {
    if (width <= 0 || height <= 0 || !options.valid())
        throw std::invalid_argument("Invalid geometry sampler");
    const auto canvas = canvasFor(width, height, options);
    const bool resample = options.straighten_degrees != 0 ||
        options.perspective_horizontal != 0 || options.perspective_vertical != 0;
    return [=](int x, int y, const GeometryPixelReader& read) {
        if (x < 0 || y < 0 || x >= canvas.right - canvas.left || y >= canvas.bottom - canvas.top)
            throw std::invalid_argument("Geometry sample is outside the output canvas");
        if (!resample) {
            const auto point = sourcePoint({double(canvas.left + x), double(canvas.top + y)}, canvas, options, width, height);
            return read(int(point.x), int(point.y));
        }
        return sampleBilinear(width, height, read,
            sourcePoint(transformedPoint(x, y, canvas, options), canvas, options, width, height));
    };
}

std::pair<int, int> geometryViewportSourceSize(int width, int height,
    const GeometryOptions& options, int target_width, int target_height) {
    const auto native = geometryOutputSize(width, height, options);
    if (native.first == 0 || target_width <= 0 || target_height <= 0) return {0, 0};
    if (target_width >= native.first || target_height >= native.second) return {width, height};
    const int edge = std::max(width, height), short_edge = std::min(width, height);
    /* 裁剪取整并非单调；按缩放顺序检查两个轴的整数边界，不能直接二分。 */
    for (int candidate = 1; candidate <= edge; ++candidate) {
        if (candidate % 64 == 1) checkProcessingCancellation();
        const int first = static_cast<int>(int64_t(short_edge) * (candidate - 1) / edge) + 1;
        const int last = static_cast<int>((int64_t(short_edge) * candidate + edge - 1) / edge);
        for (int minor = first; minor <= last; ++minor) {
            const int w = width >= height ? candidate : minor;
            const int h = width >= height ? minor : candidate;
            const auto size = geometryOutputSize(w, h, options);
            if (size.first >= target_width && size.second >= target_height) return {w, h};
        }
    }
    return {width, height};
}

ErrorCode applyGeometry(ImageData& image, const GeometryOptions& options) {
    if (!options.valid() || image.width <= 0 || image.height <= 0 ||
        image.pixels.size() != static_cast<size_t>(image.width) * image.height)
        return ErrorCode::InvalidFormat;
    if (!options.active()) return ErrorCode::Success;
    try {
        const Canvas canvas = canvasFor(image.width, image.height, options);
        ImageData result;
        result.width = canvas.right - canvas.left;
        result.height = canvas.bottom - canvas.top;
        result.pixels.resize(static_cast<size_t>(result.width) * result.height);
        const bool interpolate = options.straighten_degrees != 0 ||
            options.perspective_horizontal != 0 || options.perspective_vertical != 0;
        if (!interpolate) copyInteger(image, result, canvas, options);
        else resample(image, result, canvas, options);
        image = std::move(result);
        return ErrorCode::Success;
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    }
}

} // namespace sony2fuji
