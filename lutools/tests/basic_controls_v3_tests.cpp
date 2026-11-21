#include "core/photo_basic_controls_v3.h"
#include "core/photo_atmosphere.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>

using namespace sony2fuji;

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

static void identityAndHeadroom() {
    ImageData image(4, 1);
    image.pixels = {RGB(-.1f, .2f, 4), RGB(0, 0, 0), RGB(.18f, .18f, .18f), RGB(8, 4, 2)};
    const auto original = image;
    applyBasicToneV3(image, {});
    require(std::memcmp(image.pixels.data(), original.pixels.data(), image.pixels.size() * sizeof(RGB)) == 0,
        "zero controls preserve every input bit, including headroom and negative values");
    applyBasicToneV3(image, {-1, 0});
    require(image.pixels[0].r < 0, "negative channels are not clipped before the look");
    require(image.pixels[1].r == 0, "true black remains black");
    require(image.pixels[3].r > image.pixels[3].g && image.pixels[3].g > image.pixels[3].b,
        "super-white differences remain available after highlight compression");
    require(std::abs(image.pixels[3].r / image.pixels[3].g - 2) < 1e-6f,
        "highlight gain preserves scene RGB ratios");
    require(image.pixels[3].r < original.pixels[3].r, "negative highlights reduce bright scene values");
}

static void tonalOrderAndDetail() {
    ImageData ramp(2048, 1);
    for (int i = 0; i < ramp.width; ++i) {
        const float value = .1845f * std::exp2(-12.f + 18.f * i / (ramp.width - 1));
        ramp.pixels[i] = RGB(value, value, value);
    }
    for (float h : {-1.f, -.5f, 0.f, .5f, 1.f}) {
        for (float s : {-1.f, -.5f, 0.f, .5f, 1.f}) {
            auto image = ramp;
            applyBasicToneV3(image, {h, s});
            float previous = 0;
            for (const auto& pixel : image.pixels) {
                require(std::isfinite(pixel.r) && pixel.r >= previous, "gray ramp remains ordered across tone combinations");
                require(pixel.r == pixel.g && pixel.g == pixel.b, "gray remains neutral");
                previous = pixel.r;
            }
        }
    }
    ImageData texture(128, 128);
    for (size_t i = 0; i < texture.pixels.size(); ++i) {
        const float value = i % 2 ? 2.02f : 1.98f;
        texture.pixels[i] = RGB(value, value, value);
    }
    applyBasicToneV3(texture, {-1, 0});
    const float low = texture.at(62, 64).r, high = texture.at(63, 64).r;
    require((high - low) / (high + low) > .009f,
        "highlight compression retains fine relative contrast instead of flattening the bright region");
}

static void contrastResponse() {
    // 两张真实 RAW 的 Lightroom 端点观测范围；只约束响应形状，不声称像素等价。
    for (const auto& anchor : {std::pair<float, float>{.075f, .165f}, {.15f, .25f}, {.3f, .37f},
                               {.5f, .5f}, {.7f, .625f}, {.85f, .76f}, {.925f, .85f}}) {
        require(std::abs(basicContrastV3(anchor.first, -1) - anchor.second) < .04f,
            "minimum contrast retains the measured tonal separation");
    }
    for (float amount : {-1.f, -.5f, 0.f, .5f, 1.f}) {
        float previous = -1;
        for (int i = 0; i <= 10000; ++i) {
            const float x = i / 10000.f, y = basicContrastV3(x, amount);
            require(std::isfinite(y) && y >= previous && y >= 0 && y <= 1,
                "soft contrast is monotone and bounded");
            previous = y;
        }
        require(basicContrastV3(0, amount) == 0 && basicContrastV3(1, amount) == 1 &&
            basicContrastV3(.5f, amount) == .5f, "contrast keeps endpoints and midpoint");
    }
    require(basicContrastV3(-.2f, 1) == -.2f && basicContrastV3(1.2f, -1) == 1.2f,
        "extended working channels are not clipped by contrast");
}

static void endpointsAndVibrance() {
    const RGB extended(-.1f, .4f, 1.2f);
    const auto identity = basicBlackWhiteV3(extended, {});
    require(std::memcmp(&extended, &identity, sizeof(RGB)) == 0, "zero endpoints preserve extended channels");
    for (float black : {-1.f, -.5f, 0.f, .5f, 1.f}) {
        for (float white : {-1.f, -.5f, 0.f, .5f, 1.f}) {
            float previous = -10;
            for (int i = 0; i <= 1000; ++i) {
                const float x = i / 1000.f;
                const auto p = basicBlackWhiteV3(RGB(x, x, x), {black, white, 0});
                require(std::isfinite(p.r) && p.r >= previous && p.r == p.g && p.g == p.b,
                    "combined black and white endpoints preserve gray order");
                previous = p.r;
            }
        }
    }
    require(std::abs(basicBlackWhiteV3(RGB(.3f,.3f,.3f), {-1,0,0}).r - .1f) < .035f,
        "negative black point reaches lower midtones seen in both RAW references");
    require(std::abs(basicBlackWhiteV3(RGB(.3f,.3f,.3f), {1,0,0}).r - .405f) < .025f,
        "positive black point lifts lower midtones without a large constant floor");
    require(basicBlackWhiteV3(RGB(0,0,0), {1,0,0}).r < .02f,
        "black lift does not turn zero into the old 20 percent floor");
    const RGB colorful(.2f,.5f,.85f);
    const auto reduced = basicVibranceV3(colorful, -1);
    require(reduced.b - reduced.r > .05f && reduced.b - reduced.r < colorful.b - colorful.r,
        "minimum vibrance reduces color while retaining saturated differences");
    const RGB muted(.42f,.48f,.55f);
    const auto raised = basicVibranceV3(muted, 1);
    require(raised.b - raised.r > 1.5f * (muted.b - muted.r), "vibrance meaningfully expands muted colors");
    for (float amount : {-1.f, -.5f, .5f, 1.f}) {
        const RGB gray(.4f,.4f,.4f);
        const auto out = basicVibranceV3(gray, amount);
        require(std::memcmp(&gray, &out, sizeof(RGB)) == 0, "vibrance does not color gray");
    }
}

static void atmosphereSafety() {
    ImageData original(1024, 32);
    for (int y = 0; y < original.height; ++y) for (int x = 0; x < original.width; ++x) {
        const float value = x / 1023.f;
        original.at(x, y) = RGB(value, value, value);
    }
    DehazeAnalysis cache;
    for (float amount : {-1.f, -.01f, 0.f, .01f, 1.f}) for (int control = 0; control < 2; ++control) {
        auto image = original;
        if (control == 0) applyClarity(image, amount, 0, 0, ProcessingVersion::BasicV3);
        else applyDehaze(image, amount, &cache, 0, 0, ProcessingVersion::BasicV3);
        float previous = -1;
        for (int x = 0; x < image.width; ++x) {
            const auto p = image.at(x, 16);
            require(std::isfinite(p.r) && p.r >= 0 && p.r <= 1 && p.r == p.g && p.g == p.b,
                "v3 atmosphere remains finite, bounded and neutral on a gray ramp");
            require(p.r >= previous - 1e-6f, "v3 atmosphere cannot reverse a smooth gray ramp");
            previous = p.r;
        }
        if (amount == 0) require(std::memcmp(image.pixels.data(), original.pixels.data(),
            image.pixels.size() * sizeof(RGB)) == 0, "v3 atmosphere zero is byte identity");
    }
    require(cache.builds == 1, "v3 dehaze strengths reuse source analysis");
    auto switched = original, fresh = original;
    applyDehaze(switched, .5f, &cache, 0, 0, ProcessingVersion::C5V2);
    applyDehaze(fresh, .5f);
    require(cache.builds == 2 && std::memcmp(switched.pixels.data(), fresh.pixels.data(),
        fresh.pixels.size() * sizeof(RGB)) == 0, "version switches rebuild dehaze analysis and preserve v2 pixels");
}

int main() {
    try {
        identityAndHeadroom();
        tonalOrderAndDetail();
        contrastResponse();
        endpointsAndVibrance();
        atmosphereSafety();
        std::cout << "Basic controls v3 identity, scene headroom, tonal order, detail and contrast passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
