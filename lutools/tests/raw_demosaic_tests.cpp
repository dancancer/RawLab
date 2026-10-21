#include "sony2fuji/raw_processor.h"
#include <libraw/libraw.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>

using namespace sony2fuji;

namespace {
void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
    std::cout << "PASS " << message << '\n';
}

ImageData reference(const std::string& path, int quality, bool halfSize = false,
                    int fbdd = 0, const std::array<float,4>* customWB = nullptr) {
    auto raw = std::make_unique<LibRaw>();
    auto& params = raw->imgdata.params;
    params.use_camera_matrix = 3;
    params.use_camera_wb = customWB ? 0 : 1;
    params.use_auto_wb = 0;
    if (customWB) std::copy(customWB->begin(), customWB->end(), params.user_mul);
    check(raw->open_file(path.c_str()) == LIBRAW_SUCCESS && raw->unpack() == LIBRAW_SUCCESS,
          "reference unpacks generated RAW");
    raw->adjust_to_raw_inset_crop(3);
    params.user_qual = quality;
    params.half_size = halfSize;
    params.fbdd_noiserd = fbdd;
    params.output_color = 0;
    params.output_bps = 16;
    params.no_auto_bright = 1;
    params.no_auto_scale = 0;
    params.adjust_maximum_thr = 0;
    params.highlight = 2;
    params.gamm[0] = params.gamm[1] = 1;
    params.bright = 1;
    params.exp_correc = 0;
    check(raw->dcraw_process() == LIBRAW_SUCCESS, "reference processes explicit demosaic choice");
    const auto& data = raw->imgdata;
    const int width = data.sizes.iwidth, height = data.sizes.iheight;
    ImageData image(data.sizes.flip & 4 ? height : width, data.sizes.flip & 4 ? width : height);
    const float scale = 1.f / (65535.f * data.color.pre_mul[1]);
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x) {
        int row = y, col = x;
        if (data.sizes.flip & 4) std::swap(row, col);
        if (data.sizes.flip & 2) row = height - 1 - row;
        if (data.sizes.flip & 1) col = width - 1 - col;
        const auto& value = data.image[size_t(row)*width+col];
        float rgb[3]{};
        for (int dst = 0; dst < 3; ++dst) for (int c = 0; c < data.idata.colors; ++c)
            rgb[dst] += data.color.rgb_cam[dst][c] * value[c] * scale;
        image.at(x,y) = {rgb[0], rgb[1], rgb[2]};
    }
    return image;
}

void samePixels(const ImageData& actual, const ImageData& expected, const char* message) {
    check(actual.width == expected.width && actual.height == expected.height &&
          actual.pixels.size() == expected.pixels.size(), "demosaic dimensions match");
    double maximum = 0;
    bool finite = true;
    for (size_t i = 0; i < expected.pixels.size(); ++i) {
        const float a[] = {actual.pixels[i].r, actual.pixels[i].g, actual.pixels[i].b};
        const float b[] = {expected.pixels[i].r, expected.pixels[i].g, expected.pixels[i].b};
        for (int c = 0; c < 3; ++c) {
            finite = finite && std::isfinite(a[c]) && std::isfinite(b[c]);
            maximum = std::max(maximum, std::abs(double(a[c])-b[c]));
        }
    }
    std::cout << "Maximum pixel error: " << maximum << '\n';
    check(finite && maximum <= 2e-6, message);
}

ImageData process(RAWProcessor& processor, const RAWProcessOptions& options) {
    ImageData image;
    check(processor.process(options, image) == ErrorCode::Success, "production processes RAW");
    return image;
}
}

int main(int argc, char** argv) {
    try {
        const std::string path = std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng";
        RAWProcessor processor;
        check(processor.loadFile(path) == ErrorCode::Success, "load synthetic Bayer fixture");
        RAWProcessOptions options;
        options.applyBaselineExposure = false;
        samePixels(process(processor, options), reference(path, -1), "default Bayer output preserves released LibRaw selection");
        options.bayerDemosaic = BayerDemosaicMethod::VNG;
        const auto expected = reference(path, 1);
        samePixels(process(processor, options), expected, "v2 Bayer output matches explicit LibRaw VNG");
        options.bayerDemosaic = BayerDemosaicMethod::DHT;
        samePixels(process(processor, options), reference(path, 11), "DHT option selects LibRaw DHT rather than VNG");

        auto invalid = options;
        invalid.bayerDemosaic = static_cast<BayerDemosaicMethod>(99);
        auto stale = expected;
        check(processor.process(invalid, stale) == ErrorCode::InvalidFormat && stale.pixels.empty(),
              "invalid demosaic choice fails without stale output");

        options.bayerDemosaic = BayerDemosaicMethod::VNG;
        samePixels(process(processor, options), expected, "switching DHT back to VNG restores original pixels");
        const std::array<float,4> wb{1.7f, 1.f, 1.25f, 1.f};
        options.useCustomWhiteBalance = true;
        std::copy(wb.begin(), wb.end(), options.customWhiteBalance);
        options.bayerDemosaic = BayerDemosaicMethod::DHT;
        samePixels(process(processor, options), reference(path, 11, false, 0, &wb),
                   "white-balance reload preserves DHT and applies gains before demosaic");
        options.useCustomWhiteBalance = false;
        options.bayerDemosaic = BayerDemosaicMethod::VNG;
        samePixels(process(processor, options), expected, "camera white balance reset restores VNG pixels");

        options.halfSize = true;
        const auto half = process(processor, options);
        check(half.width < expected.width && half.height < expected.height, "FBDD-off half-size remains a proxy");
        samePixels(half, reference(path, 1, true), "VNG preserves half-size behavior");
        options.bayerDemosaic = BayerDemosaicMethod::DHT;
        samePixels(process(processor, options), half, "DHT does not introduce interpolation into half-size proxy");
        options.rawNoiseReduction = 1;
        samePixels(process(processor, options), reference(path, 11, false, 1),
                   "enabled FBDD forces full-size DHT processing despite half-size request");

        options = RAWProcessOptions{};
        options.applyBaselineExposure = false;
        options.bayerDemosaic = BayerDemosaicMethod::DHT;
        const std::string linear = std::string(TEST_FIXTURE_DIR) + "/linear-uncompressed.dng";
        check(processor.loadFile(linear) == ErrorCode::Success && !processor.supportsNoiseReduction(),
              "reused processor loads non-Bayer LinearRaw");
        const auto linearExpected = reference(linear, -1);
        samePixels(process(processor, options), linearExpected, "DHT selection leaves LinearRaw unchanged");
        options.bayerDemosaic = BayerDemosaicMethod::VNG;
        samePixels(process(processor, options), linearExpected, "VNG selection leaves LinearRaw unchanged");

        if (argc == 2) {
            auto metadata = std::make_unique<LibRaw>();
            check(metadata->open_file(argv[1]) == LIBRAW_SUCCESS && metadata->imgdata.idata.filters == 9,
                  "optional fixture is actually X-Trans");
            check(processor.loadFile(path) == ErrorCode::Success, "reload Bayer before X-Trans reuse");
            process(processor, options);
            check(processor.loadFile(argv[1]) == ErrorCode::Success && !processor.supportsNoiseReduction(),
                  "reused processor switches from Bayer to X-Trans");
            const auto xtrans = reference(argv[1], -1);
            samePixels(process(processor, options), xtrans, "VNG selection cannot bypass X-Trans interpolation");
            options.bayerDemosaic = BayerDemosaicMethod::DHT;
            samePixels(process(processor, options), xtrans, "DHT selection preserves the X-Trans path");
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
