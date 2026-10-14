#include "core/photo_geometry.h"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

using namespace sony2fuji;

namespace {

int checks = 0;

void check(bool passed, const std::string& message) {
    ++checks;
    if (!passed) throw std::runtime_error(message);
}

bool same(const RGB& first, const RGB& second) {
    return first.r == second.r && first.g == second.g && first.b == second.b;
}

bool same(const ImageData& first, const ImageData& second) {
    return first.width == second.width && first.height == second.height &&
        first.pixels.size() == second.pixels.size() &&
        std::equal(first.pixels.begin(), first.pixels.end(), second.pixels.begin(),
            [](const RGB& a, const RGB& b) { return same(a, b); });
}

bool near(const ImageData& first, const ImageData& second) {
    if (first.width != second.width || first.height != second.height ||
        first.pixels.size() != second.pixels.size()) return false;
    for (size_t i = 0; i < first.pixels.size(); ++i) {
        const auto a = first.pixels[i], b = second.pixels[i];
        if (std::abs(a.r - b.r) > 4e-5f || std::abs(a.g - b.g) > 4e-5f ||
            std::abs(a.b - b.b) > 4e-5f) return false;
    }
    return true;
}

ImageData grid(int width = 7, int height = 5) {
    ImageData image(width, height);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x)
        image.at(x, y) = RGB(float(y * width + x + 1), float(x + 1), float(y + 1));
    return image;
}

ImageData clockwise(const ImageData& source) {
    ImageData output(source.height, source.width);
    for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x)
        output.at(source.height - 1 - y, x) = source.at(x, y);
    return output;
}

ImageData flip(const ImageData& source, bool horizontal, bool vertical) {
    ImageData output(source.width, source.height);
    for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x)
        output.at(horizontal ? source.width - 1 - x : x,
            vertical ? source.height - 1 - y : y) = source.at(x, y);
    return output;
}

void integerTests() {
    GeometryOptions options;
    check(options.valid() && !options.active(), "Default geometry must be valid identity");
    const auto source = grid();
    auto image = source;
    const auto* storage = image.pixels.data();
    check(applyGeometry(image, options) == ErrorCode::Success && same(image, source) &&
        image.pixels.data() == storage, "Identity must preserve pixels and storage");
    auto rotated = source;
    for (int turns = 0; turns < 4; ++turns) {
        for (bool horizontal : {false, true}) for (bool vertical : {false, true}) {
            options.quarter_turns = turns;
            options.flip_horizontal = horizontal; options.flip_vertical = vertical;
            image = source;
            check(applyGeometry(image, options) == ErrorCode::Success &&
                same(image, flip(rotated, horizontal, vertical)), "Quarter-turn/flip order or pixels differ");
        }
        rotated = clockwise(rotated);
    }
    image = grid(1, 1); options.quarter_turns = 1;
    check(applyGeometry(image, options) == ErrorCode::Success && same(image, grid(1, 1)),
        "One-pixel integer geometry must preserve the pixel");
}

void cropTests() {
    const auto source = grid(8, 6);
    GeometryOptions options;
    options.crop_x = .25f; options.crop_y = .5f;
    options.crop_width = .5f; options.crop_height = .25f;
    auto image = source;
    check(applyGeometry(image, options) == ErrorCode::Success && image.width == 4 && image.height == 2,
        "Asymmetric crop dimensions must use floor start/ceil end");
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x)
        check(same(image.at(x, y), source.at(x + 2, y + 3)), "Integer crop must copy exact pixels");
    options = GeometryOptions{};
    options.crop_x = .9f; options.crop_y = .9f;
    options.crop_width = .1f; options.crop_height = .1f;
    image = source;
    check(applyGeometry(image, options) == ErrorCode::Success && image.width == 1 && image.height == 1 &&
        same(image.at(0, 0), source.at(7, 5)), "Last-pixel crop must include the requested edge");
    options = GeometryOptions{};
    options.crop_x = .125f; options.crop_width = .000001f;
    options.crop_y = .5f; options.crop_height = .000001f;
    image = source;
    check(applyGeometry(image, options) == ErrorCode::Success && image.width == 1 && image.height == 1 &&
        same(image.at(0, 0), source.at(1, 3)), "Subpixel crop must retain the covering pixel");
    options.crop_x = .5f; options.crop_y = .5f;
    options.crop_width = options.crop_height = std::numeric_limits<float>::denorm_min();
    image = source;
    check(applyGeometry(image, options) == ErrorCode::Success && image.width == 1 && image.height == 1 &&
        same(image.at(0, 0), source.at(4, 3)), "Positive crop too small for double addition must retain one pixel");
    options = GeometryOptions{};
    options.crop_x = .2f; options.crop_width = .8f;
    options.crop_y = .2f; options.crop_height = .8f;
    image = source;
    check(options.valid() && applyGeometry(image, options) == ErrorCode::Success &&
        image.width == 7 && image.height == 5 && same(image.at(6, 4), source.at(7, 5)),
        "Float UI boundary sums must retain the right and bottom edges");
    options.crop_width = .8000005f; options.crop_height = .8000005f;
    image = source;
    check(options.valid() && applyGeometry(image, options) == ErrorCode::Success &&
        image.width == 7 && image.height == 5 && same(image.at(6, 4), source.at(7, 5)),
        "Accepted edge tolerance must clamp into the image canvas");
    options = GeometryOptions{};
    options.quarter_turns = 1; options.flip_horizontal = true;
    options.crop_x = .5f; options.crop_width = .5f;
    options.crop_y = .25f; options.crop_height = .25f;
    const auto oriented = flip(clockwise(source), true, false);
    image = source;
    check(applyGeometry(image, options) == ErrorCode::Success && image.width == 3 && image.height == 2,
        "Crop must refer to the rotated/flipped canvas");
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x)
        check(same(image.at(x, y), oriented.at(x + 3, y + 2)), "Post-orientation crop coordinates differ");
}

void angleTests() {
    const auto source = grid(17, 11);
    for (float angle : {-45.f, -30.f, -1.f, 1.f, 30.f, 45.f}) {
        GeometryOptions options; options.straighten_degrees = angle;
        auto image = source;
        check(applyGeometry(image, options) == ErrorCode::Success && image.width <= source.width &&
            image.height <= source.height && image.width > 0 && image.height > 0,
            "Straighten must produce a smaller valid canvas");
        const double radians = double(angle) * 3.14159265358979323846 / 180;
        const double cosine = std::cos(radians), sine = std::sin(radians);
        // G/B store affine x/y coordinates; bilinear interpolation must retain
        // the inverse-rotated coordinate exactly within float rounding.
        for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x) {
            const double dx = x - (image.width - 1) * .5;
            const double dy = y - (image.height - 1) * .5;
            const double sx = 8 + cosine * dx + sine * dy;
            const double sy = 5 - sine * dx + cosine * dy;
            const RGB pixel = image.at(x, y);
            check(sx >= -.5 && sx <= 16.5 && sy >= -.5 && sy <= 10.5,
                "Straightened pixel support must remain within the source edges");
            check(std::abs(pixel.g - (std::clamp(sx, 0.0, 16.0) + 1)) < 2e-5 &&
                std::abs(pixel.b - (std::clamp(sy, 0.0, 10.0) + 1)) < 2e-5,
                "Straighten must sample clockwise inverse coordinates bilinearly");
            check(pixel.r >= 1 && pixel.r <= 187 && std::isfinite(pixel.r),
                "Straighten must not introduce black or out-of-range samples");
        }
        options.crop_x = .25f; options.crop_width = .5f;
        options.crop_y = .25f; options.crop_height = .5f;
        auto cropped = source;
        check(applyGeometry(cropped, options) == ErrorCode::Success, "Straighten plus crop must succeed");
        const int left = int(std::floor(.25 * image.width)), top = int(std::floor(.25 * image.height));
        for (int y = 0; y < cropped.height; ++y) for (int x = 0; x < cropped.width; ++x)
            check(same(cropped.at(x, y), image.at(left + x, top + y)),
                "Crop after straighten must select the same samples without a second interpolation");
    }
    for (int turns = 0; turns < 4; ++turns) for (bool horizontal : {false, true}) for (bool vertical : {false, true}) {
        GeometryOptions options;
        options.quarter_turns = turns; options.flip_horizontal = horizontal; options.flip_vertical = vertical;
        options.straighten_degrees = 19;
        auto combined = source, oriented = source;
        for (int i = 0; i < turns; ++i) oriented = clockwise(oriented);
        oriented = flip(oriented, horizontal, vertical);
        check(applyGeometry(combined, options) == ErrorCode::Success, "Combined geometry must succeed");
        options.quarter_turns = 0; options.flip_horizontal = options.flip_vertical = false;
        // Reversing the interpolation direction changes float rounding, but
        // must not change the mapped coordinates or resample the image twice.
        check(applyGeometry(oriented, options) == ErrorCode::Success && near(combined, oriented),
            "Composed inverse must match lossless orientation followed by a single straighten");
    }
    ImageData flat(31, 21);
    std::fill(flat.pixels.begin(), flat.pixels.end(), RGB(2, -.25f, .1845f));
    GeometryOptions options; options.straighten_degrees = -37;
    check(applyGeometry(flat, options) == ErrorCode::Success, "Flat straighten must succeed");
    for (const auto& pixel : flat.pixels)
        check(same(pixel, RGB(2, -.25f, .1845f)), "Geometry must not clip negative or super-white values");
    auto tiny = grid(1, 1);
    check(applyGeometry(tiny, options) == ErrorCode::Success && same(tiny, grid(1, 1)),
        "One-pixel straighten must preserve its edge support");
}

void invalidTests() {
    const auto source = grid();
    auto rejected = [&](const GeometryOptions& options) {
        auto image = source;
        check(!options.valid() && applyGeometry(image, options) == ErrorCode::InvalidFormat && same(image, source),
            "Invalid geometry must reject atomically");
    };
    for (auto field : {&GeometryOptions::crop_x, &GeometryOptions::crop_y,
        &GeometryOptions::crop_width, &GeometryOptions::crop_height, &GeometryOptions::straighten_degrees}) {
        for (float bad : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
            -std::numeric_limits<float>::infinity()}) {
            GeometryOptions options; options.*field = bad; rejected(options);
        }
    }
    for (float bad : {-.01f, 1.f, 2.f}) {
        GeometryOptions options; options.crop_x = bad; rejected(options);
        options = GeometryOptions{}; options.crop_y = bad; rejected(options);
    }
    for (float bad : {-.01f, 0.f, 1.01f}) {
        GeometryOptions options; options.crop_width = bad; rejected(options);
        options = GeometryOptions{}; options.crop_height = bad; rejected(options);
    }
    for (int turns : {-1, 4}) { GeometryOptions options; options.quarter_turns = turns; rejected(options); }
    for (float angle : {-45.01f, 45.01f}) { GeometryOptions options; options.straighten_degrees = angle; rejected(options); }
    GeometryOptions options; options.crop_x = .75f; options.crop_width = .5f; rejected(options);
    options = GeometryOptions{}; options.crop_y = .75f; options.crop_height = .5f; rejected(options);
    options = GeometryOptions{}; options.crop_x = .2f; options.crop_width = .8000011f; rejected(options);
    options = GeometryOptions{}; options.crop_y = .2f; options.crop_height = .8000011f; rejected(options);
    ImageData empty;
    check(applyGeometry(empty, GeometryOptions{}) == ErrorCode::InvalidFormat && empty.pixels.empty(),
        "Empty image must reject without mutation");
    auto damaged = source; damaged.pixels.pop_back();
    const auto previous = damaged;
    check(applyGeometry(damaged, GeometryOptions{}) == ErrorCode::InvalidFormat && same(damaged, previous),
        "Mismatched pixel count must reject without mutation");
    damaged = source; damaged.width = -1;
    check(applyGeometry(damaged, GeometryOptions{}) == ErrorCode::InvalidFormat && damaged.width == -1,
        "Negative image dimensions must reject without mutation");
}

} // namespace

int main() {
    try {
        integerTests(); cropTests(); angleTests(); invalidTests();
        std::cout << "PASS: " << checks << " geometry checks (identity, orientation, crop, straighten, validation)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL after " << checks << " geometry checks: " << error.what() << '\n';
        return 1;
    }
}
