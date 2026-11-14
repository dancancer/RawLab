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
        std::cout << "PASS: D3D11 bounded tiling (WARP software adapter)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
