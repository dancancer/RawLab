#include "core/photo_geometry.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <new>

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

RGB sampleBilinear(const ImageData& image, Point point) {
    // Pixels cover half a pixel past their centers. Extend those edge pixels
    // when the inscribed canvas samples that support; never introduce black.
    const double x = std::clamp(point.x, 0.0, double(image.width - 1));
    const double y = std::clamp(point.y, 0.0, double(image.height - 1));
    // 钳位后非负，截断等同 floor。
    const int left = static_cast<int>(x), top = static_cast<int>(y);
    const int right = std::min(left + 1, image.width - 1);
    const int bottom = std::min(top + 1, image.height - 1);
    const float dx = static_cast<float>(x - left), dy = static_cast<float>(y - top);
    return interpolate(interpolate(image.at(left, top), image.at(right, top), dx),
        interpolate(image.at(left, bottom), image.at(right, bottom), dx), dy);
}

void copyRectangle(const RGB* source, RGB* target, int width, int height,
    ptrdiff_t step_x, ptrdiff_t step_y, int target_stride) {
    for (int y = 0; y < height; ++y) {
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
    std::array<Point, 256> points;
    for (int y = 0; y < result.height; ++y) {
        const double dy = canvas.top + y - (canvas.height - 1) * .5;
        auto* target = result.pixels.data() + size_t(y) * result.width;
        for (int begin = 0; begin < result.width;) {
            const int count = std::min(int(points.size()), result.width - begin);
            // 分批计算坐标，让独立除法流水执行。
            for (int i = 0; i < count; ++i) {
                const int x = begin + i;
                const double dx = canvas.left + x - (canvas.width - 1) * .5;
                // 保持乘加顺序，不累加坐标或改用倒数。
                const double rotated_x = canvas.cosine * dx + canvas.sine * dy;
                const double rotated_y = -canvas.sine * dx + canvas.cosine * dy;
                const double denominator = 1 + .25 * options.perspective_horizontal * (2 * rotated_x / canvas.rotated_width) +
                    .25 * options.perspective_vertical * (2 * rotated_y / canvas.rotated_height);
                points[i] = {(canvas.rotated_width - 1) * .5 + rotated_x / denominator,
                    (canvas.rotated_height - 1) * .5 + rotated_y / denominator};
            }
            for (int i = 0; i < count; ++i)
                target[begin + i] = sampleBilinear(image,
                    sourcePoint(points[i], canvas, options, image.width, image.height));
            begin += count;
        }
    }
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
