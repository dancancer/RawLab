#include "core/photo_geometry.h"

#include <algorithm>
#include <cmath>
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
    const double w = canvas.rotated_width, h = canvas.rotated_height;
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
    const int left = static_cast<int>(std::floor(x)), top = static_cast<int>(std::floor(y));
    const int right = std::min(left + 1, image.width - 1);
    const int bottom = std::min(top + 1, image.height - 1);
    const float dx = static_cast<float>(x - left), dy = static_cast<float>(y - top);
    return interpolate(interpolate(image.at(left, top), image.at(right, top), dx),
        interpolate(image.at(left, bottom), image.at(right, bottom), dx), dy);
}

Point straightenedPoint(int x, int y, const Canvas& canvas) {
    const double dx = x - (canvas.width - 1) * .5;
    const double dy = y - (canvas.height - 1) * .5;
    return {(canvas.rotated_width - 1) * .5 + canvas.cosine * dx + canvas.sine * dy,
        (canvas.rotated_height - 1) * .5 - canvas.sine * dx + canvas.cosine * dy};
}

} // namespace

bool GeometryOptions::valid() const {
    return std::isfinite(crop_x) && std::isfinite(crop_y) && std::isfinite(crop_width) &&
        std::isfinite(crop_height) && std::isfinite(straighten_degrees) &&
        crop_x >= 0 && crop_y >= 0 && crop_x < 1 && crop_y < 1 &&
        crop_width > 0 && crop_height > 0 && double(crop_x) + crop_width <= 1.000001 &&
        double(crop_y) + crop_height <= 1.000001 && quarter_turns >= 0 && quarter_turns <= 3 &&
        straighten_degrees >= -45 && straighten_degrees <= 45;
}

bool GeometryOptions::active() const {
    return crop_x != 0 || crop_y != 0 || crop_width != 1 || crop_height != 1 ||
        quarter_turns != 0 || flip_horizontal || flip_vertical || straighten_degrees != 0;
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
        for (int y = 0; y < result.height; ++y) {
            for (int x = 0; x < result.width; ++x) {
                const Point rotated = options.straighten_degrees == 0 ?
                    Point{double(canvas.left + x), double(canvas.top + y)} :
                    straightenedPoint(canvas.left + x, canvas.top + y, canvas);
                const Point source = sourcePoint(rotated, canvas, options, image.width, image.height);
                result.at(x, y) = options.straighten_degrees == 0 ?
                    image.at(static_cast<int>(source.x), static_cast<int>(source.y)) : sampleBilinear(image, source);
            }
        }
        image = std::move(result);
        return ErrorCode::Success;
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    }
}

} // namespace sony2fuji
