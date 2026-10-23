#include "core/photo_tone_endpoints.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace sony2fuji;

static void check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

static bool near(double a, double b, double tolerance = 1e-7) {
    return std::abs(a - b) <= tolerance;
}

static double smooth(double value) {
    if (value <= 0) return 0;
    if (value >= 1) return 1;
    return value * value * (3 - 2 * value);
}

// Independent double formula also checks the unclipped mathematical contract.
static double unclipped(double y, double black, double white, double amount = .20) {
    return y + amount * (black * (1 - smooth(y / .35)) + white * smooth((y - .65) / .35));
}

static void validationAndIdentity() {
    ToneEndpointOptions options;
    check(options.valid() && !options.active(), "default must be valid and inactive");
    for (float value : {-1.f, -.25f, 0.f, .25f, 1.f}) {
        options = {value, value};
        check(options.valid(), "legal endpoints must be accepted");
        check(options.active() == (value != 0), "activity must match nonzero endpoints");
    }
    for (float value : {-1.01f, 1.01f, std::numeric_limits<float>::quiet_NaN(),
                        std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()}) {
        check(!ToneEndpointOptions{value, 0}.valid(), "invalid black endpoint accepted");
        check(!ToneEndpointOptions{0, value}.valid(), "invalid white endpoint accepted");
    }
    options = {};
    const std::array<RGB, 5> pixels{{{-.25f, .5f, 1.5f}, {-0.f, 0.f, -0.f},
        {0, 0, 0}, {1, 1, 1}, {.125f, .5625f, .9375f}}};
    for (const auto& pixel : pixels) {
        const auto result = applyToneEndpoints(pixel, options);
        check(std::memcmp(&pixel, &result, sizeof(RGB)) == 0, "zero must preserve exact input bytes");
    }
    ImageData image(5, 1);
    image.pixels.assign(pixels.begin(), pixels.end());
    const auto before = image.pixels;
    applyToneEndpoints(image, options);
    check(std::memcmp(before.data(), image.pixels.data(), before.size() * sizeof(RGB)) == 0,
          "image identity must preserve exact bytes");
}

static void directionsAndVectors() {
    check(near(applyToneEndpoints(RGB(0, 0, 0), {1, 0}).r, .2), "black lift must reach .2");
    check(near(applyToneEndpoints(RGB(1, 1, 1), {0, -1}).r, .8), "white reduction must reach .8");
    check(near(applyToneEndpoints(RGB(.175f, .175f, .175f), {1, 0}).r, .275), "dark midpoint vector");
    check(near(applyToneEndpoints(RGB(.825f, .825f, .825f), {0, -1}).r, .725), "light midpoint vector");
    check(near(applyToneEndpoints(RGB(.5f, .5f, .5f), {1, -1}).r, .5), "midtones remain stationary");
    check(applyToneEndpoints(RGB(.15f, .15f, .15f), {-1, 0}).r < .15f, "negative black must darken");
    check(applyToneEndpoints(RGB(.85f, .85f, .85f), {0, 1}).r > .85f, "positive white must brighten");
    check(unclipped(.15, 1, 0, .25) > unclipped(.20, 1, 0, .25), "old dark counterexample must be present");
    check(unclipped(.80, 0, -1, .25) > unclipped(.85, 0, -1, .25), "old light counterexample must be present");
    check(near(applyToneEndpoints(RGB(.15f, .15f, .15f), {1, 0}).r, .2712827988338192), "corrected dark vector 1");
    check(near(applyToneEndpoints(RGB(.20f, .20f, .20f), {1, 0}).r, .27871720116618076), "corrected dark vector 2");
    // Equal encoded luma receives the same neutral-axis offset even for colored pixels.
    const RGB colored(.1f, .2f, .3f);
    const double y = double(colored.g) + .2126 * (double(colored.r) - colored.g)
        + .0722 * (double(colored.b) - colored.g);
    const auto result = applyToneEndpoints(colored, {1, 0});
    const double delta = unclipped(y, 1, 0) - y;
    check(near(result.r, colored.r + delta) && near(result.g, colored.g + delta)
        && near(result.b, colored.b + delta), "colored pixel must use encoded-luma neutral-axis offset");
}

static void monotonicGrid() {
    constexpr std::array<float, 9> values{-1, -.75f, -.5f, -.25f, 0, .25f, .5f, .75f, 1};
    constexpr std::array<double, 6> boundaries{0, .175, .35, .65, .825, 1};
    for (float black : values) for (float white : values) {
        const ToneEndpointOptions options{black, white};
        double previous = -2;
        float previousClipped = -2;
        for (int index = 0; index <= 10000; ++index) {
            const double y = double(index) / 10000;
            const double raw = unclipped(y, black, white);
            const auto rgb = applyToneEndpoints(RGB(float(y), float(y), float(y)), options);
            check(raw >= previous, "unclipped grayscale mapping reversed");
            check(rgb.r >= previousClipped, "production grayscale mapping reversed");
            check(rgb.r == rgb.g && rgb.g == rgb.b, "gray must stay gray");
            check(std::isfinite(rgb.r) && rgb.r >= 0 && rgb.r <= 1, "SDR output must be finite and bounded");
            const double expected = std::max(0., std::min(1., raw));
            check(near(rgb.r, expected, 2e-7), "production output differs from independent reference");
            previous = raw;
            previousClipped = rgb.r;
        }
        for (double y : boundaries) {
            const auto rgb = applyToneEndpoints(RGB(float(y), float(y), float(y)), options);
            check(near(rgb.r, std::max(0., std::min(1., unclipped(y, black, white))), 2e-7),
                  "transition boundary differs from reference");
        }
    }
}

static void imageAndBounds() {
    ImageData image(3, 2);
    image.pixels = {{0, 0, 0}, {1, 1, 1}, {.1f, .2f, .3f},
                    {1.3f, -.2f, .5f}, {.8f, .4f, .2f}, {.4f, .5f, .6f}};
    const auto before = image;
    const ToneEndpointOptions options{.75f, -.5f};
    applyToneEndpoints(image, options);
    check(image.width == before.width && image.height == before.height, "image dimensions changed");
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        const auto expected = applyToneEndpoints(before.pixels[i], options);
        const auto actual = image.pixels[i];
        check(actual.r == expected.r && actual.g == expected.g && actual.b == expected.b,
              "image and pixel entry points disagree");
        for (float value : {actual.r, actual.g, actual.b})
            check(std::isfinite(value) && value >= 0 && value <= 1, "active output outside SDR");
    }
    ImageData empty;
    applyToneEndpoints(empty, options);
    check(empty.pixels.empty(), "empty image changed");
}

int main() {
    try {
        validationAndIdentity();
        directionsAndVectors();
        monotonicGrid();
        imageAndBounds();
        std::cout << "PASS: tone endpoints identity, validation, directions, 81 x 10001 monotonic grid, boundaries and image parity\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
