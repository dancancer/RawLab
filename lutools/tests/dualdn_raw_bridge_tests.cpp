#include "sony2fuji/raw_processor.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace sony2fuji;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
bool identical(const ImageData& a, const ImageData& b) {
    if (a.width != b.width || a.height != b.height || a.pixels.size() != b.pixels.size()) return false;
    for (size_t i = 0; i < a.pixels.size(); ++i)
        if (a.pixels[i].r != b.pixels[i].r || a.pixels[i].g != b.pixels[i].g || a.pixels[i].b != b.pixels[i].b) return false;
    return true;
}

int main(int argc, char** argv) {
    try {
        require(argc == 2, "requires Bayer fixture");
        RAWProcessor processor;
        require(processor.loadFile(argv[1]) == ErrorCode::Success, "load Bayer fixture");
        RAWProcessOptions options;
        options.bayerDemosaic = BayerDemosaicMethod::VNG;
        options.applyBaselineExposure = false;
        RAWBayerSource source;
        require(processor.readBayerSource(options, source) == ErrorCode::Success, "read original Bayer");
        RAWBayerOverride replacement;
        replacement.width = source.width; replacement.height = source.height;
        for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x) {
            const float black = source.black[source.pattern[(y % 2) * 2 + x % 2]];
            replacement.normalizedMosaic.push_back((source.pixels[size_t(y) * source.width + x] - black) / (source.white - black));
        }
        ImageData original, identity, after;
        require(processor.process(options, original) == ErrorCode::Success, "native baseline");
        options.bayerOverride = &replacement;
        require(processor.process(options, identity) == ErrorCode::Success && identical(original, identity),
                "identity Bayer override must preserve native pixels");
        replacement.cameraCorrection.resize(source.pixels.size(), RGB(0, 0, 0));
        require(processor.process(options, identity) == ErrorCode::Success && identical(original, identity),
                "zero RGB correction must preserve native pixels");
        replacement.cameraCorrection.assign(source.pixels.size(), RGB(.05f, -.02f, .03f));
        ImageData corrected, exposed;
        require(processor.process(options, corrected) == ErrorCode::Success, "camera correction");
        options.exposure = 2;
        require(processor.process(options, exposed) == ErrorCode::Success, "exposed camera correction");
        bool changed = false;
        for (size_t i = 0; i < corrected.pixels.size(); ++i) {
            const auto& a = corrected.pixels[i]; const auto& b = exposed.pixels[i];
            require(std::max({std::abs(b.r - 4*a.r), std::abs(b.g - 4*a.g), std::abs(b.b - 4*a.b)}) < 1e-6f,
                    "camera correction received exposure more than once");
            changed |= a.r != original.pixels[i].r || a.g != original.pixels[i].g || a.b != original.pixels[i].b;
        }
        require(changed, "RGB correction was not applied");
        options.exposure = 0; options.bayerOverride = nullptr;
        require(processor.process(options, after) == ErrorCode::Success && identical(original, after), "override changed source state");
        RAWBayerSource reread;
        require(processor.readBayerSource(options, reread) == ErrorCode::Success && reread.pixels == source.pixels,
                "unpacked RAW changed after override");
        options.useCameraWhiteBalance = false; options.useCustomWhiteBalance = true;
        options.customWhiteBalance[0] = 1.5f; options.customWhiteBalance[2] = 1.2f;
        require(processor.process(options, original) == ErrorCode::Success, "custom WB baseline");
        replacement.cameraCorrection.clear(); options.bayerOverride = &replacement;
        require(processor.process(options, identity) == ErrorCode::Success && identical(original, identity), "custom WB identity override");
        options.halfSize = true;
        require(processor.process(options, after) == ErrorCode::InvalidFormat, "AI half-size silently accepted");
        options.halfSize = false; replacement.normalizedMosaic[0] = std::numeric_limits<float>::quiet_NaN();
        require(processor.process(options, after) == ErrorCode::InvalidFormat && after.pixels.empty(), "nonfinite AI mosaic accepted");
        std::cout << "PASS native Bayer override identity, source reuse, WB, correction and exposure\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
