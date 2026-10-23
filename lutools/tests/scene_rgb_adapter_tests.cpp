#include "ai/scene_rgb_adapter.h"
#include "sony2fuji/color_converter.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>

using namespace sony2fuji;
using namespace sony2fuji::ai;
void require(bool value, const char* text) { if (!value) throw std::runtime_error(text); }

int main() {
    try {
        ImageData image; image.width = 31; image.height = 47;
        image.pixels.resize(31 * 47);
        for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x)
            image.at(x,y) = RGB(.02f + x * .01f, .04f + y * .006f, .12f);
        image.pixels[0] = RGB(-.1f, .1f, .2f);
        image.pixels[1] = RGB(1.4f, .2f, .3f);
        for (float gain : {.25f, 1.f, 4.f}) {
            size_t tiles = 0;
            auto zero = sceneRGBCorrection(image, gain, [&](const Tensor& input) { ++tiles; return input; }, {}, {24, 4});
            require(tiles == 6 && zero.width == 31 && zero.height == 47, "odd portrait tile canvas changed");
            require(std::all_of(zero.values.begin(), zero.values.end(), [](float v) { return v == 0; }),
                    "identity network changed scene values");
            auto restored = image;
            applySceneRGBCorrection(restored, zero, ColorSpace::sRGB, 1);
            for (size_t i = 0; i < image.pixels.size(); ++i)
                require(restored.pixels[i].r == image.pixels[i].r && restored.pixels[i].g == image.pixels[i].g &&
                        restored.pixels[i].b == image.pixels[i].b, "identity correction clipped original range");
        }
        const auto delta = sceneRGBCorrection(image, 1, [](Tensor tile) {
            for (auto& v : tile.values) v += .005f;
            return tile;
        }, {}, {24, 4});
        const size_t pixels = image.pixels.size();
        for (int c = 0; c < 3; ++c)
            require(delta.values[c*pixels] == 0 && delta.values[c*pixels+1] == 0, "unsafe pixel received partial color correction");
        require(delta.values[2] > 0, "valid RGB correction was discarded");
        auto adobe = image;
        applySceneRGBCorrection(adobe, delta, ColorSpace::AdobeRGB, 2.f);
        auto expected = ColorConverter::applyMatrix(RGB(delta.values[2],delta.values[pixels+2],delta.values[2*pixels+2]),
            ColorConverter::getConversionMatrix(ColorSpace::sRGB, ColorSpace::AdobeRGB));
        require(std::abs(adobe.pixels[2].r-image.pixels[2].r-2*expected.r) < 1e-7f &&
                std::abs(adobe.pixels[2].g-image.pixels[2].g-2*expected.g) < 1e-7f, "working-space conversion or exposure repeated");
        bool rejected = false;
        try { sceneRGBCorrection(image, 1, [](Tensor tile) { tile.values[0] = std::numeric_limits<float>::quiet_NaN(); return tile; }, {}, {24,4}); }
        catch (const ModelContractError&) { rejected = true; }
        require(rejected, "nonfinite model output accepted");
        bool cancelled = false;
        try { sceneRGBCorrection(image, 1, [](const Tensor& tile) { return tile; }, [](size_t done, size_t) { return done == 0; }, {24,4}); }
        catch (const Cancelled&) { cancelled = true; }
        require(cancelled, "tile cancellation ignored");
        std::cout << "PASS scene RGB identity, range, geometry, color space, exposure and cancellation\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
