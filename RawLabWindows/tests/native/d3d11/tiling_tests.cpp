#include "gpu/d3d11_photo.h"
#include "core/photo_rendering.h"
#include "d3d11_test_hooks.h"
#undef RGB
#include <algorithm>
#include <cmath>
#include <iostream>

using namespace sony2fuji;
namespace {
void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
RGB mix(RGB a, RGB b, float t) {
    return {a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t};
}
RGB tone(RGB p) { return {neutralDisplay(p.r), neutralDisplay(p.g), neutralDisplay(p.b)}; }
RGB sample(const ImageData& input, int x, int y, int width, int height, bool final) {
    const float sx = width == 1 ? 0 : float(x) * (float(input.width - 1) / float(width - 1));
    const float sy = height == 1 ? 0 : float(y) * (float(input.height - 1) / float(height - 1));
    const int x0 = int(sx), y0 = int(sy), x1 = std::min(x0 + 1, input.width - 1), y1 = std::min(y0 + 1, input.height - 1);
    auto read = [&](int px, int py) { return final ? tone(input.at(px, py)) : input.at(px, py); };
    auto result = mix(mix(read(x0, y0), read(x1, y0), sx - x0), mix(read(x0, y1), read(x1, y1), sx - x0), sy - y0);
    return final ? result : tone(result);
}
void check(const ImageData& input, int width, int height, bool final, bool preserve = false) {
    sony2fuji_request request{};
    request.brightness = request.contrast = request.saturation = 1;
    request.intent = final ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW;
    D3D11PhotoRenderer renderer;
    ImageData output;
    d3d11_test::largestPhotoBuffer = 0;
    require(renderer.render(input, ColorSpace::sRGB, request, {}, {1, 1, 1}, width, height, 0,
        output, {}, 0, preserve), "C6: tiled photo render failed");
    require(d3d11_test::largestPhotoBuffer > 0 && d3d11_test::largestPhotoBuffer <= 16 * 1024 * 1024,
        "C6: renderer allocated a full-frame buffer above the tile budget");
    float maximum = 0;
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        const auto expected = sample(input, x, y, width, height, final || preserve);
        const auto actual = output.at(x, y);
        require(std::isfinite(actual.r) && std::isfinite(actual.g) && std::isfinite(actual.b), "nonfinite tiled pixel");
        maximum = std::max({maximum, std::abs(expected.r - actual.r), std::abs(expected.g - actual.g), std::abs(expected.b - actual.b)});
    }
    std::cout << "tiled " << width << 'x' << height << " final=" << final << " preserve=" << preserve
              << " maxDiff=" << maximum << " largestBuffer=" << d3d11_test::largestPhotoBuffer << '\n';
    require(maximum <= 2e-4f, "C6: tiled/CPU pixels differ at a band boundary or resize");
}
ImageData detail(const ImageData& input, float strength, bool sharpen) {
    ImageData output(input.width, input.height);
    for (int y = 0; y < input.height; ++y) for (int x = 0; x < input.width; ++x) {
        RGB sum{};
        for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
            const auto p = input.at(std::clamp(x + dx, 0, input.width - 1), std::clamp(y + dy, 0, input.height - 1));
            sum.r += p.r; sum.g += p.g; sum.b += p.b;
        }
        const auto p = input.at(x, y);
        const auto channel = [&](float value, float total) {
            return sharpen ? std::clamp(value + strength * (value - total / 9), 0.f, 1.f)
                : value + (total / 9 - value) * strength * .4f;
        };
        output.at(x, y) = {channel(p.r, sum.r), channel(p.g, sum.g), channel(p.b, sum.b)};
    }
    return output;
}
void nativeFilters() {
    ImageData input(65, 49), expected(65, 49);
    for (size_t i = 0; i < input.pixels.size(); ++i) {
        input.pixels[i] = {.03f + .3f * float(i % 13) / 12, .11f, .31f};
        expected.pixels[i] = tone(input.pixels[i]);
    }
    sony2fuji_request request{};
    request.brightness = request.contrast = request.saturation = 1;
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.noise_reduction = .35f; request.sharpening = .6f;
    PhotoEffectsOptions effects;
    effects.vignetteAmount = -30; effects.grainAmount = 15;
    expected = detail(detail(expected, .35f, false), .6f, true);
    applyPhotoEffects(expected, effects);
    D3D11PhotoRenderer renderer;
    ImageData output;
    require(renderer.render(input, ColorSpace::sRGB, request, {}, {1, 1, 1}, 65, 49, 0, output, effects),
        "C6: source-resolution shared filter chain failed");
    float maximum = 0;
    for (size_t i = 0; i < output.pixels.size(); ++i) {
        const auto a = output.pixels[i], b = expected.pixels[i];
        require(std::isfinite(a.r) && std::isfinite(a.g) && std::isfinite(a.b), "nonfinite filtered pixel");
        maximum = std::max({maximum, std::abs(a.r-b.r), std::abs(a.g-b.g), std::abs(a.b-b.b)});
    }
    std::cout << "native shared filters maxDiff=" << maximum << '\n';
    require(maximum <= 2e-4f, "C6: shared noise/sharpen/effects chain differs from CPU");
}
}
int main() {
    try {
        ImageData input(4096, 385);
        for (int y = 0; y < input.height; ++y) for (int x = 0; x < input.width; ++x)
            input.at(x, y) = {.001f + .7f * float((x * 17 + y * 13) % 257) / 256,
                .1f + .2f * float(y) / 384, .01f + .4f * float(x) / 4095};
        check(input, 4096, 385, true);
        check(input, 193, 137, false);
        check(input, 193, 137, true);
        check(input, 193, 137, false, true);
        check(input, 1, 19, false);
        check(input, 113, 1, true);
        nativeFilters();
        std::cout << "PASS: D3D11 bounded tiling (WARP software adapter)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
