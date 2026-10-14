#include "core/photo_geometry.h"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>

using namespace sony2fuji;

namespace {

size_t checks = 0;

void check(bool condition, const std::string& message) {
    ++checks;
    if (!condition) throw std::runtime_error(message);
}

bool same(const RGB& a, const RGB& b) {
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

bool same(const ImageData& a, const ImageData& b) {
    return a.width == b.width && a.height == b.height && a.pixels.size() == b.pixels.size() &&
        std::equal(a.pixels.begin(), a.pixels.end(), b.pixels.begin(),
            [](const RGB& first, const RGB& second) { return same(first, second); });
}

ImageData gradient(int width = 83, int height = 57) {
    ImageData image(width, height);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x)
        image.at(x, y) = {-3 + .013f * x + .005f * y,
            2 + .017f * y - .003f * x, 10 + .01f * x + .02f * y};
    return image;
}

// A forward permutation is independent of the implementation's inverse map.
ImageData oriented(const ImageData& source, const GeometryOptions& options) {
    ImageData output(options.quarter_turns % 2 ? source.height : source.width,
        options.quarter_turns % 2 ? source.width : source.height);
    for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x) {
        int dx = x, dy = y;
        switch (options.quarter_turns) {
            case 1: dx = source.height - 1 - y; dy = x; break;
            case 2: dx = source.width - 1 - x; dy = source.height - 1 - y; break;
            case 3: dx = y; dy = source.width - 1 - x; break;
        }
        if (options.flip_horizontal) dx = output.width - 1 - dx;
        if (options.flip_vertical) dy = output.height - 1 - dy;
        output.at(dx, dy) = source.at(x, y);
    }
    return output;
}

struct ReferenceCanvas {
    int width, height, left, top, right, bottom;
};

ReferenceCanvas referenceCanvas(int width, int height, const GeometryOptions& options) {
    if (options.quarter_turns % 2) std::swap(width, height);
    const double k = 1 / (1 + .25 * std::abs(options.perspective_horizontal) +
        .25 * std::abs(options.perspective_vertical));
    const int reducedWidth = std::max(1, int(std::floor(width * k)));
    const int reducedHeight = std::max(1, int(std::floor(height * k)));
    const double radians = options.straighten_degrees * std::acos(-1.0) / 180;
    const double c = std::cos(radians), s = std::abs(std::sin(radians));
    // The rotated half-extents must fit inside the perspective-safe rectangle.
    const double scale = std::min((reducedWidth * .5) / (c * reducedWidth * .5 + s * reducedHeight * .5),
        (reducedHeight * .5) / (s * reducedWidth * .5 + c * reducedHeight * .5));
    ReferenceCanvas canvas{};
    canvas.width = std::max(1, int(std::floor(reducedWidth * scale)));
    canvas.height = std::max(1, int(std::floor(reducedHeight * scale)));
    canvas.left = int(std::floor(options.crop_x * double(canvas.width)));
    canvas.top = int(std::floor(options.crop_y * double(canvas.height)));
    canvas.right = std::min(canvas.width, std::max(canvas.left + 1,
        int(std::ceil(std::min(1.0, double(options.crop_x) + options.crop_width) * canvas.width))));
    canvas.bottom = std::min(canvas.height, std::max(canvas.top + 1,
        int(std::ceil(std::min(1.0, double(options.crop_y) + options.crop_height) * canvas.height))));
    return canvas;
}

struct Point { double x, y; };

Point referencePoint(int x, int y, int width, int height, const ReferenceCanvas& canvas,
    const GeometryOptions& options) {
    const double radians = options.straighten_degrees * std::acos(-1.0) / 180;
    const double dx = x - (canvas.width - 1) * .5, dy = y - (canvas.height - 1) * .5;
    const double px = std::cos(radians) * dx + std::sin(radians) * dy;
    const double py = -std::sin(radians) * dx + std::cos(radians) * dy;
    // Solve the forward projective equations p = q/(1-a*q.x-b*q.y),
    // rather than reproduce the implementation's inverse denominator.
    const double a = .5 * options.perspective_horizontal / width;
    const double b = .5 * options.perspective_vertical / height;
    const double m00 = 1 + a * px, m01 = b * px;
    const double m10 = a * py, m11 = 1 + b * py;
    const double determinant = m00 * m11 - m01 * m10;
    const double qx = (m11 * px - m01 * py) / determinant;
    const double qy = (m00 * py - m10 * px) / determinant;
    const double forwardDenominator = 1 - a * qx - b * qy;
    check(determinant > 0 && forwardDenominator > 0, "projective map must have no poles");
    check(std::abs(qx / forwardDenominator - px) < 1e-10 &&
        std::abs(qy / forwardDenominator - py) < 1e-10, "projective forward/inverse residual");
    const Point result{qx + (width - 1) * .5, qy + (height - 1) * .5};
    check(result.x >= -.5 - 1e-9 && result.x <= width - .5 + 1e-9 &&
        result.y >= -.5 - 1e-9 && result.y <= height - .5 + 1e-9,
        "safe canvas samples must remain inside source pixel support");
    return result;
}

RGB affineSample(const ImageData& image, Point point) {
    const double x = std::clamp(point.x, 0.0, double(image.width - 1));
    const double y = std::clamp(point.y, 0.0, double(image.height - 1));
    const RGB origin = image.at(0, 0), right = image.at(image.width - 1, 0), bottom = image.at(0, image.height - 1);
    const double u = image.width == 1 ? 0 : x / (image.width - 1);
    const double v = image.height == 1 ? 0 : y / (image.height - 1);
    return {float(origin.r + u * (right.r - origin.r) + v * (bottom.r - origin.r)),
        float(origin.g + u * (right.g - origin.g) + v * (bottom.g - origin.g)),
        float(origin.b + u * (right.b - origin.b) + v * (bottom.b - origin.b))};
}

void compareGradient(const ImageData& source, const GeometryOptions& options) {
    auto actual = source;
    check(options.valid() && options.active() && applyGeometry(actual, options) == ErrorCode::Success,
        "active perspective must succeed");
    const auto canvas = referenceCanvas(source.width, source.height, options);
    const auto rotated = oriented(source, options);
    check(actual.width == canvas.right - canvas.left && actual.height == canvas.bottom - canvas.top,
        "perspective dimensions must shrink before straightening and crop");
    for (int y = 0; y < actual.height; ++y) for (int x = 0; x < actual.width; ++x) {
        const auto point = referencePoint(x + canvas.left, y + canvas.top,
            rotated.width, rotated.height, canvas, options);
        const auto expected = affineSample(rotated, point), pixel = actual.at(x, y);
        check(std::abs(pixel.r - expected.r) < 2e-6f && std::abs(pixel.g - expected.g) < 2e-6f &&
            std::abs(pixel.b - expected.b) < 4e-6f, "analytic projective gradient differs");
        check(pixel.r < 0 && pixel.g > 1 && pixel.b > 1, "perspective must preserve negatives and super-whites");
    }
}

void mappingTests() {
    const auto source = gradient();
    for (const auto& perspective : {std::pair<float, float>{1, 0}, {-1, 0}, {0, 1}, {0, -1},
            {1, 1}, {1, -1}, {-1, 1}, {-1, -1}, {.6f, -.35f}}) {
        for (int turns = 0; turns < 4; ++turns) for (bool horizontal : {false, true}) {
            GeometryOptions options;
            options.quarter_turns = turns; options.flip_horizontal = horizontal;
            options.flip_vertical = !horizontal;
            options.perspective_horizontal = perspective.first; options.perspective_vertical = perspective.second;
            for (float angle : {-45.f, 0.f, 17.f, 45.f}) {
                options.straighten_degrees = angle;
                compareGradient(source, options);
            }
            options.crop_x = .125f; options.crop_y = .25f;
            options.crop_width = .625f; options.crop_height = .5f;
            options.straighten_degrees = -13;
            compareGradient(source, options);
        }
    }
    GeometryOptions centered;
    centered.perspective_horizontal = centered.perspective_vertical = .5f;
    auto image = gradient(79, 59);
    const RGB center = image.at(39, 29);
    check(applyGeometry(image, centered) == ErrorCode::Success && image.width == 63 && image.height == 47 &&
        same(image.at(31, 23), center), "perspective must keep the original rotated center fixed");
}

void identityAndCropTests() {
    const auto source = gradient(8, 6);
    GeometryOptions options;
    check(options.valid() && !options.active(), "zero perspective is valid inactive identity");
    auto image = source;
    const auto* storage = image.pixels.data();
    check(applyGeometry(image, options) == ErrorCode::Success && same(image, source) && image.pixels.data() == storage,
        "zero perspective identity must preserve exact pixels and storage");
    options.quarter_turns = 1; options.flip_horizontal = true; options.flip_vertical = true;
    options.crop_x = .5f; options.crop_width = .5f; options.crop_y = .25f; options.crop_height = .5f;
    const auto rotated = oriented(source, options);
    image = source;
    check(applyGeometry(image, options) == ErrorCode::Success && image.width == 3 && image.height == 4,
        "zero perspective retains integer geometry dimensions");
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x)
        check(same(image.at(x, y), rotated.at(x + 3, y + 2)), "zero perspective must retain exact integer geometry");

    auto textured = gradient(79, 59);
    for (int y = 0; y < textured.height; ++y) for (int x = 0; x < textured.width; ++x)
        textured.at(x, y).b = (x + y) % 2 ? 12 : -2;
    options = {};
    options.perspective_horizontal = .7f; options.perspective_vertical = -.4f; options.straighten_degrees = 13;
    auto full = textured;
    check(applyGeometry(full, options) == ErrorCode::Success, "perspective plus straightening succeeds");
    const auto fullCanvas = referenceCanvas(textured.width, textured.height, options);
    for (int y = 0; y < full.height; ++y) for (int x = 0; x < full.width; ++x) {
        const auto point = referencePoint(x, y, textured.width, textured.height, fullCanvas, options);
        const double sx = std::clamp(point.x, 0.0, double(textured.width - 1));
        const double sy = std::clamp(point.y, 0.0, double(textured.height - 1));
        const int left = int(std::floor(sx)), top = int(std::floor(sy));
        const int right = std::min(left + 1, textured.width - 1), bottom = std::min(top + 1, textured.height - 1);
        const double u = sx - left, v = sy - top;
        const double expected = (1 - u) * (1 - v) * textured.at(left, top).b +
            u * (1 - v) * textured.at(right, top).b + (1 - u) * v * textured.at(left, bottom).b +
            u * v * textured.at(right, bottom).b;
        check(std::abs(full.at(x, y).b - expected) < 4e-6,
            "combined perspective and straightening must sample the original texture once");
    }
    options.crop_x = .125f; options.crop_y = .25f; options.crop_width = .625f; options.crop_height = .5f;
    auto cropped = textured;
    check(applyGeometry(cropped, options) == ErrorCode::Success, "combined crop succeeds");
    const int left = int(std::floor(.125 * full.width)), top = int(std::floor(.25 * full.height));
    for (int y = 0; y < cropped.height; ++y) for (int x = 0; x < cropped.width; ++x)
        check(same(cropped.at(x, y), full.at(left + x, top + y)), "crop must select samples without resampling again");
}

void tinyAndValidationTests() {
    for (const auto& dimensions : {std::pair<int, int>{1, 1}, {1, 9}, {9, 1}, {2, 3}, {3, 2}}) {
        for (float horizontal : {-1.f, 1.f}) for (float vertical : {-1.f, 1.f}) for (float angle : {-45.f, 0.f, 45.f}) {
            GeometryOptions options;
            options.perspective_horizontal = horizontal; options.perspective_vertical = vertical;
            options.straighten_degrees = angle;
            ImageData image(dimensions.first, dimensions.second);
            const RGB constant{-2, 3, 10};
            std::fill(image.pixels.begin(), image.pixels.end(), constant);
            check(applyGeometry(image, options) == ErrorCode::Success && image.width >= 1 && image.height >= 1,
                "tiny perspective canvas must retain a pixel");
            for (const auto& pixel : image.pixels) check(same(pixel, constant), "edge extension must preserve constants without black borders");
        }
    }
    const auto source = gradient();
    for (float invalid : {-1.001f, 1.001f, std::numeric_limits<float>::quiet_NaN(),
            std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()}) {
        for (bool horizontal : {false, true}) {
            GeometryOptions options;
            (horizontal ? options.perspective_horizontal : options.perspective_vertical) = invalid;
            auto image = source;
            const auto* storage = image.pixels.data();
            check(!options.valid() && applyGeometry(image, options) == ErrorCode::InvalidFormat &&
                same(image, source) && image.pixels.data() == storage, "invalid perspective must reject atomically");
        }
    }
}

} // namespace

int main() {
    try {
        identityAndCropTests();
        mappingTests();
        tinyAndValidationTests();
        std::cout << "PASS " << checks << " perspective homography, bounds, dimensions, float-range and zero-path checks\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL after " << checks << " checks: " << error.what() << '\n';
        return 1;
    }
}
