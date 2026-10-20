#include "core/photo_geometry.h"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

using namespace sony2fuji;

namespace {

size_t cases = 0;
void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

std::vector<GeometryOptions> matrix() {
    std::vector<GeometryOptions> result;
    for (int turn = 0; turn < 4; ++turn) for (int flips = 0; flips < 4; ++flips)
        for (int crop = 0; crop < 6; ++crop) for (int transform = 0; transform < 9; ++transform) {
            GeometryOptions options;
            options.quarter_turns = turn;
            options.flip_horizontal = flips & 1; options.flip_vertical = flips & 2;
            if (crop == 1) {
                options.crop_x = .125f; options.crop_y = .25f;
                options.crop_width = .5f; options.crop_height = .625f;
            } else if (crop == 2) {
                options.crop_x = options.crop_y = .9f;
                options.crop_width = options.crop_height = .1f;
            } else if (crop == 3) {
                options.crop_x = options.crop_y = .2f;
                options.crop_width = options.crop_height = .8000005f;
            } else if (crop >= 4) {
                options.crop_x = options.crop_y = crop == 4 ? std::nextafter(1.f, 0.f) : 0.f;
                options.crop_width = options.crop_height = std::numeric_limits<float>::denorm_min();
            }
            if (transform == 1 || transform == 6) options.straighten_degrees = 3;
            if (transform == 2 || transform == 7) options.straighten_degrees = -45;
            if (transform == 3) options.straighten_degrees = 45;
            if (transform == 4 || transform == 6) options.perspective_horizontal = .2f;
            if (transform == 5) options.perspective_vertical = -.3f;
            if (transform == 7) {
                options.perspective_horizontal = 1; options.perspective_vertical = -1;
            }
            if (transform == 8) options.straighten_degrees = std::numeric_limits<float>::denorm_min();
            result.push_back(options);
        }
    return result;
}

void compare(int width, int height, const GeometryOptions& options) {
    ImageData image(width, height);
    const auto native = geometryOutputSize(width, height, options);
    check(applyGeometry(image, options) == ErrorCode::Success, "apply geometry");
    check(native == std::make_pair(image.width, image.height), "size differs from actual geometry");
    for (const auto target : {std::pair<int, int>{1, 1}, {std::max(1, native.first / 3),
            std::max(1, native.second / 3)}, native, {native.first + 1, native.second + 1}}) {
        const auto source = geometryViewportSourceSize(width, height, options, target.first, target.second);
        check(source.first > 0 && source.second > 0 && source.first <= width && source.second <= height,
            "viewport source enlarged or empty");
        if (target.first >= native.first || target.second >= native.second) {
            check(source == std::make_pair(width, height), "100 percent source must remain exact");
        } else {
            const auto actual = geometryOutputSize(source.first, source.second, options);
            check(actual.first >= target.first && actual.second >= target.second, "final resize would enlarge");
            /* 独立检查缩放区间的交集，也覆盖同一长边内短边先跳变的情况。 */
            for (int w = 1; w <= source.first; ++w) for (int h = 1; h <= source.second; ++h) {
                if (w == source.first && h == source.second) continue;
                const double lower = std::max(double(w - 1) / width, double(h - 1) / height);
                const double upper = std::min(double(w) / width, double(h) / height);
                if (lower >= upper) continue;
                const auto size = geometryOutputSize(w, h, options);
                check(size.first < target.first || size.second < target.second, "source is not smallest");
            }
        }
        ++cases;
    }
}

} // namespace

int main() {
    try {
        for (const auto size : {std::pair<int, int>{1, 1}, {1, 17}, {17, 1}, {3, 5}, {7, 5},
                {17, 11}, {31, 19}, {95, 67}})
            for (const auto& options : matrix()) compare(size.first, size.second, options);
        GeometryOptions flipped; flipped.flip_horizontal = true;
        check(geometryViewportSourceSize(100, 99, flipped, 50, 49) == std::make_pair(50, 49),
            "a scale between long-edge steps must not retain an unnecessary short-edge pixel");
        GeometryOptions invalid; invalid.crop_width = 0;
        check(geometryOutputSize(3, 5, invalid) == std::make_pair(0, 0), "invalid geometry size");
        check(geometryOutputSize(0, 5, {}) == std::make_pair(0, 0), "empty source size");
        check(geometryViewportSourceSize(3, 5, {}, 0, 1) == std::make_pair(0, 0), "invalid viewport target");
        std::cout << "PASS " << cases << " geometry size and minimal viewport source checks\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
