#include "denoise_quality_metrics.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace sony2fuji;
using namespace denoise_quality;

int main() {
    ImageData source(2, 2), reference(2, 2);
    source.pixels = {{0, 0, 0}, {1, 1, 1}, {1, -1, 0}, {2, 1, -1}};
    const auto measured = measure(source, &reference, {0, 0, 2, 2});
    assert(measured.referenceError.has_value());
    const auto& error = *measured.referenceError;
    assert(std::abs(error.rgbRmse - std::sqrt(11.0 / 12)) < 1e-12);
    assert(std::abs(error.lumaRmse - std::sqrt(13.0) / 6) < 1e-12);
    assert(std::abs(error.chromaRmse - std::sqrt(1.25)) < 1e-12);
    assert(std::abs(measured.lumaMean - 5.0 / 12) < 1e-12);
    assert(std::abs(measured.lumaStddev - std::sqrt(27.0) / 12) < 1e-12);
    assert(!error.lumaContrastGain.has_value());

    const auto unpaired = measure(source, nullptr, {0, 0, 2, 2});
    assert(!unpaired.referenceError.has_value());
    assert(unpaired.lumaStddev == measured.lumaStddev);

    ImageData texture(4, 1), attenuated(4, 1);
    texture.pixels = {{0, 0, 0}, {2, 2, 2}, {0, 0, 0}, {2, 2, 2}};
    attenuated.pixels = {{1, 1, 1}, {2, 2, 2}, {1, 1, 1}, {2, 2, 2}};
    const auto retention = measure(attenuated, &texture, {0, 0, 4, 1});
    assert(std::abs(*retention.referenceError->lumaContrastGain - .5) < 1e-12);
    assert(!retention.referenceError->lumaLaplacianGain);

    ImageData fine(7, 7), blurred(7, 7), flat(7, 7);
    for (int y = 0; y < 7; ++y) for (int x = 0; x < 7; ++x) {
        const float value = (x+y)%2 ? .75f : .25f;
        fine.at(x,y) = {value, value, value};
        const float reduced = .5f * value + .25f;
        blurred.at(x,y) = {reduced, reduced, reduced};
        flat.at(x,y) = {.25f, .25f, .25f};
    }
    const auto fineRetention = measure(blurred, &fine, {0, 0, 7, 7}).referenceError;
    assert(std::abs(*fineRetention->lumaLaplacianGain - .5) < 1e-12);
    assert(std::abs(*fineRetention->referenceLaplacianRms - .5) < 1e-12);
    const auto noStructure = measure(blurred, &flat, {0, 0, 7, 7}).referenceError;
    assert(!noStructure->lumaLaplacianGain);
    assert(*noStructure->referenceLaplacianRms == 0);

    const auto region = pixelRegion(9, 7, {.25, .25, .5, .5});
    assert(region.x == 2 && region.y == 1 && region.width == 5 && region.height == 5);
    auto rejects = [](auto action) {
        bool rejected = false;
        try { action(); } catch (const std::invalid_argument&) { rejected = true; }
        assert(rejected);
    };
    rejects([&] { measure(source, nullptr, {1, 0, 2, 2}); });
    rejects([&] { measure(source, &texture, {0, 0, 2, 2}); });
    rejects([&] { pixelRegion(2, 2, {0, 0, 0, 1}); });
    rejects([&] { pixelRegion(2, 2, {0, 0, 1, std::numeric_limits<double>::infinity()}); });
    reference.pixels[0].r = std::numeric_limits<float>::quiet_NaN();
    rejects([&] { measure(source, &reference, {0, 0, 2, 2}); });
    source.pixels[0].r = std::numeric_limits<float>::quiet_NaN();
    rejects([&] { measure(source, nullptr, {0, 0, 2, 2}); });
    std::cout << "PASS: independent RGB/luma/chroma errors, unpaired boundaries, contrast gain and ROI validation\n";
}
