#include "core/photo_geometry.h"

#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace sony2fuji::geometry_oracle {
ErrorCode applyGeometry(ImageData& image, const GeometryOptions& options);
}

using namespace sony2fuji;

namespace {

uint32_t state = 0x67a91e35;
size_t comparisons = 0;

uint32_t randomBits() {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

float unit() {
    return float(randomBits() >> 8) / 16777216.f;
}

ImageData input(int width, int height) {
    ImageData image(width, height);
    for (auto& pixel : image.pixels) {
        /* 覆盖负值、超白及不同指数，避免渐变掩盖插值舍入差异。 */
        auto value = [] { return std::ldexp(unit() - .5f, int(randomBits() % 32) - 12); };
        pixel = RGB(value(), value(), value());
    }
    image.pixels.front().r = -0.f;
    image.pixels.back().b = std::numeric_limits<float>::denorm_min();
    return image;
}

void compare(const ImageData& source, const GeometryOptions& options) {
    if (!options.valid()) throw std::runtime_error("Invalid test options");
    auto actual = source, expected = source;
    const auto status = applyGeometry(actual, options);
    const auto reference = geometry_oracle::applyGeometry(expected, options);
    ++comparisons;
    if (status != ErrorCode::Success || status != reference || actual.width != expected.width ||
        actual.height != expected.height || actual.pixels.size() != expected.pixels.size() ||
        std::memcmp(actual.pixels.data(), expected.pixels.data(), actual.pixels.size() * sizeof(RGB))) {
        std::cerr << "Mismatch #" << comparisons << " source=" << source.width << 'x' << source.height
                  << " turns=" << options.quarter_turns << " flips=" << options.flip_horizontal
                  << options.flip_vertical << " angle=" << options.straighten_degrees
                  << " perspective=" << options.perspective_horizontal << ',' << options.perspective_vertical
                  << " crop=" << options.crop_x << ',' << options.crop_y << ','
                  << options.crop_width << ',' << options.crop_height << '\n';
        throw std::runtime_error("Geometry differs bit-for-bit from a883b91 oracle");
    }
}

void crop(GeometryOptions& options, int index) {
    switch (index) {
        case 1:
            options.crop_x = .125f; options.crop_y = .25f;
            options.crop_width = .5f; options.crop_height = .625f;
            break;
        case 2:
            options.crop_x = .9f; options.crop_y = .9f;
            options.crop_width = .1f; options.crop_height = .1f;
            break;
        case 3:
            options.crop_x = .2f; options.crop_y = .2f;
            options.crop_width = .8000005f; options.crop_height = .8000005f;
            break;
        case 4:
            options.crop_x = options.crop_y = std::nextafter(1.f, 0.f);
            options.crop_width = options.crop_height = std::numeric_limits<float>::denorm_min();
            break;
        case 5:
            options.crop_width = options.crop_height = std::numeric_limits<float>::denorm_min();
            break;
        default: break;
    }
}

void matrix(const ImageData& source) {
    for (int turn = 0; turn < 4; ++turn) for (int flips = 0; flips < 4; ++flips)
        for (int region = 0; region < 6; ++region) for (int transform = 0; transform < 10; ++transform) {
            GeometryOptions options;
            options.quarter_turns = turn;
            options.flip_horizontal = flips & 1;
            options.flip_vertical = flips & 2;
            crop(options, region);
            switch (transform) {
                case 1: options.straighten_degrees = 3; break;
                case 2: options.straighten_degrees = -45; break;
                case 3: options.straighten_degrees = 45; break;
                case 4: options.perspective_horizontal = .2f; break;
                case 5: options.perspective_vertical = -.3f; break;
                case 6:
                    options.perspective_horizontal = -1; options.perspective_vertical = 1; break;
                case 7:
                    options.perspective_horizontal = .2f; options.straighten_degrees = 3; break;
                case 8:
                    options.perspective_horizontal = 1; options.perspective_vertical = -1;
                    options.straighten_degrees = -45; break;
                case 9:
                    options.straighten_degrees = std::numeric_limits<float>::denorm_min();
                    options.perspective_vertical = -0.f; break;
                default: break;
            }
            compare(source, options);
        }
}

void randomized() {
    for (int iteration = 0; iteration < 1200; ++iteration) {
        const auto source = input(1 + randomBits() % 131, 1 + randomBits() % 97);
        GeometryOptions options;
        options.quarter_turns = randomBits() % 4;
        options.flip_horizontal = randomBits() & 1;
        options.flip_vertical = randomBits() & 1;
        options.crop_x = unit(); options.crop_y = unit();
        options.crop_width = (1 - options.crop_x) * (.001f + .999f * unit());
        options.crop_height = (1 - options.crop_y) * (.001f + .999f * unit());
        if (iteration % 4) options.straighten_degrees = 90 * unit() - 45;
        if (iteration % 3) options.perspective_horizontal = 2 * unit() - 1;
        if (iteration % 5) options.perspective_vertical = 2 * unit() - 1;
        compare(source, options);
    }
}

void exceptionalPixels() {
    auto source = input(17, 13);
    const uint32_t bits[] = {0, 0x80000000, 1, 0x80000001, 0x7f7fffff, 0xff7fffff,
        0x7f800000, 0xff800000, 0x7fc12345, 0xffc54321};
    for (size_t i = 0; i < source.pixels.size(); ++i) {
        float values[3];
        for (size_t channel = 0; channel < 3; ++channel)
            std::memcpy(&values[channel], &bits[(i + channel) % 10], sizeof(float));
        source.pixels[i] = RGB(values[0], values[1], values[2]);
    }
    matrix(source);
}

} // namespace

int main() {
    try {
        for (const auto size : {std::pair<int, int>{1, 1}, {1, 17}, {19, 1}, {2, 3},
            {7, 5}, {32, 33}, {65, 49}}) matrix(input(size.first, size.second));
        randomized();
        exceptionalPixels();
        /* 大画布的坐标舍入及分块尾部也必须覆盖。 */
        const auto large = input(1601, 1067);
        for (int turns = 0; turns < 4; ++turns) for (int flips = 0; flips < 4; ++flips) {
            GeometryOptions options;
            options.quarter_turns = turns;
            options.flip_horizontal = flips & 1; options.flip_vertical = flips & 2;
            compare(large, options);
            options.crop_x = .123f; options.crop_y = .731f;
            options.crop_width = .043f; options.crop_height = .037f;
            options.straighten_degrees = 3; options.perspective_horizontal = .2f;
            compare(large, options);
        }
        std::cout << "PASS " << comparisons << " bit-exact geometry comparisons (seed 0x67a91e35)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
