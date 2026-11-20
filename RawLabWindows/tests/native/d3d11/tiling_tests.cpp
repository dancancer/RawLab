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
RGB sample(const ImageData& input, int x, int y, int width, int height, bool final, bool display = false) {
    const float sx = width == 1 ? 0 : float(x) * (float(input.width - 1) / float(width - 1));
    const float sy = height == 1 ? 0 : float(y) * (float(input.height - 1) / float(height - 1));
    const int x0 = int(sx), y0 = int(sy), x1 = std::min(x0 + 1, input.width - 1), y1 = std::min(y0 + 1, input.height - 1);
    auto read = [&](int px, int py) { return final && !display ? tone(input.at(px, py)) : input.at(px, py); };
    auto result = mix(mix(read(x0, y0), read(x1, y0), sx - x0), mix(read(x0, y1), read(x1, y1), sx - x0), sy - y0);
    return final || display ? result : tone(result);
}
void check(const ImageData& input, int width, int height, bool final, bool preserve = false) {
    RenderParams params{};
    params.intent = final ? RenderIntent::Final : RenderIntent::Preview;
    params.preserveSourceResolution = preserve;
    D3D11PhotoRenderer renderer;
    ImageData output;
    d3d11_test::largestPhotoBuffer = 0;
    require(renderer.render(input, ColorSpace::sRGB, params, width, height, 0,
        output), "C6: tiled photo render failed");
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
void nativeFilters(bool resize) {
    ImageData input(65, 49), expected(65, 49);
    for (size_t i = 0; i < input.pixels.size(); ++i) {
        input.pixels[i] = {.03f + .3f * float(i % 13) / 12, .11f, .31f};
        expected.pixels[i] = tone(input.pixels[i]);
    }
    RenderParams params{};
    params.intent = RenderIntent::Preview;
    params.noiseReduction = .35f; params.sharpening = .6f;
    PhotoEffectsOptions effects;
    effects.vignetteAmount = -30; effects.grainAmount = 15;
    params.effects = effects;
    expected = detail(detail(expected, .35f, false), .6f, true);
    applyPhotoEffects(expected, effects);
    D3D11PhotoRenderer renderer;
    ImageData output;
    const int width = resize ? 33 : 65, height = resize ? 25 : 49;
    require(renderer.render(input, ColorSpace::sRGB, params, width, height, 0, output),
        "C6: source-resolution shared filter chain failed");
    float maximum = 0;
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        const auto a = output.at(x, y), b = sample(expected, x, y, width, height, false, true);
        require(std::isfinite(a.r) && std::isfinite(a.g) && std::isfinite(a.b), "nonfinite filtered pixel");
        maximum = std::max({maximum, std::abs(a.r-b.r), std::abs(a.g-b.g), std::abs(a.b-b.b)});
    }
    std::cout << "native shared filters maxDiff=" << maximum << '\n';
    require(maximum <= 2e-4f, "C6: shared noise/sharpen/effects chain differs from CPU");
}
void cacheTransitions() {
    ImageData input(65, 49), output;
    for (int y = 0; y < 49; ++y) for (int x = 0; x < 65; ++x)
        input.at(x, y) = {.01f + .3f * float(y) / 48, .1f + .2f * float(x) / 64, .3f};
    RenderParams params{};
    params.intent = RenderIntent::Preview;
    D3D11PhotoRenderer renderer;
    auto run = [&](int width, int height, uint64_t revision) {
        require(renderer.render(input, ColorSpace::sRGB, params, width, height, revision, output),
            "C6: revision-cache transition failed");
    };
    auto verify = [&](float gain) {
        require(output.width == input.width && output.height == input.height && output.pixels.size() == input.pixels.size(),
            "C6: cache transition published incorrect dimensions");
        for (size_t i = 0; i < input.pixels.size(); ++i) {
            const auto p = input.pixels[i], a = output.pixels[i];
            const auto b = tone({p.r * gain, p.g * gain, p.b * gain});
            require(std::max({std::abs(a.r-b.r), std::abs(a.g-b.g), std::abs(a.b-b.b)}) < 2e-4f,
                "C6: revision cache retained a tiled prefix or a stale source");
        }
    };
    run(65, 49, 41); verify(1);
    params.exposureEV = 1;
    run(65, 49, 41); verify(2);
    params.exposureEV = 0;
    run(1024, 1367, 41); // 超过分带阈值，最后两行只上传原图末尾的少数行。
    run(65, 49, 41); verify(1);
    for (auto& p : input.pixels) p = {.13f, .27f, .41f};
    run(65, 49, 42); verify(1);
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
        nativeFilters(false);
        nativeFilters(true);
        cacheTransitions();
        std::cout << "PASS: D3D11 bounded tiling (WARP software adapter)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
