#include "test_harness.h"
#include "core/hdr_resample.h"
#include "core/hdr_rendering.h"
#include "core/hdr_stream.h"
#include "core/hdr_storage.h"
#include "core/hdr_jpeg.h"
#include "core/hdr_types.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <vector>

using namespace sony2fuji;
namespace fs = std::filesystem;

namespace {
using rawlab::test::check;
using rawlab::test::require;

ImageData makeCheckerboard(int width, int height, float low, float high) {
    ImageData img(width, height);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const float v = ((x + y) % 2) ? high : low;
            img.at(x, y) = {v, v * 0.5f, v * 0.25f};
        }
    }
    return img;
}

void testCheckerboardAntiAliasingAllPaths(const fs::path& root) {
    // 2:1 and non-integer ~2:1 checkerboard downscale across all 3 HDR downscale paths:
    // 1. hdr::resample
    // 2. renderHDRPair
    // 3. hdr::renderStreamFiles / hdr::encodeStream
    for (const auto dims : {std::pair{320, 160}, std::pair{321, 161}}) {
        const int srcW = dims.first, srcH = dims.second;
        const ImageData src = makeCheckerboard(srcW, srcH, 0.0f, 1.0f);
        const auto targetSize = hdrResizeSize(srcW, srcH, 160);
        require(targetSize.first == 160 && targetSize.second == 80, "Unexpected target dimensions");

        const ImageData resampled = hdr::resample(src, 160, 80);
        require(resampled.width == 160 && resampled.height == 80, "hdr::resample dimensions mismatch");

        float minR = 1e9f, maxR = -1e9f;
        for (const auto& p : resampled.pixels) {
            minR = std::min(minR, p.r);
            maxR = std::max(maxR, p.r);
        }
        const float tol = (srcW == 320) ? 0.01f : 0.12f;
        check(minR >= 0.5f - tol && maxR <= 0.5f + tol,
              "hdr::resample prefilters 1-px checkerboard without aliasing (" + std::to_string(srcW) + ")");

        HDRImagePair pair;
        pair.hdr = src;
        pair.sdr = src;
        pair.nativeWidth = srcW;
        pair.nativeHeight = srcH;
        pair.sourceHeadroom = 1.0f;
        HDRRenderOptions options;
        options.longEdge = 160;
        const auto rendered = renderHDRPair(pair, options);
        check(std::memcmp(rendered.hdr.pixels.data(), resampled.pixels.data(),
                          resampled.pixels.size() * sizeof(RGB)) == 0,
              "renderHDRPair resize is bit-identical to hdr::resample");

        HDRRowSource rowSource;
        rowSource.width = srcW;
        rowSource.height = srcH;
        rowSource.read = [&](bool hdr, uint32_t row, uint32_t count, RGB* out) {
            const auto& plane = hdr ? pair.hdr : pair.sdr;
            std::copy_n(plane.pixels.data() + size_t(row) * srcW, size_t(count) * srcW, out);
        };
        rowSource.finish = [] {};

        const auto files = hdr::renderStreamFiles(rowSource, options, true, root);
        hdr::storage::File streamedHdr(files.hdr);
        std::vector<RGB> streamedPixels(resampled.pixels.size());
        streamedHdr.read(0, streamedPixels.data(), streamedPixels.size() * sizeof(RGB));
        check(std::memcmp(streamedPixels.data(), rendered.hdr.pixels.data(),
                          streamedPixels.size() * sizeof(RGB)) == 0,
              "renderStreamFiles downscale is bit-identical to renderHDRPair");
    }
}

void testHDRRangePreservationAnd1DEdgeCases() {
    // High-frequency stripe with HDR > 1.0 and negative out-of-gamut values:
    // verifies no [0, 1] clamping and proper prefiltering on non-integer ratio + 1D shapes.
    const ImageData stripes = makeCheckerboard(200, 100, -0.5f, 4.0f);
    const ImageData down = hdr::resample(stripes, 67, 33);
    double sumR = 0.0;
    float minR = 1e9f, maxR = -1e9f;
    for (const auto& p : down.pixels) {
        sumR += p.r;
        minR = std::min(minR, p.r);
        maxR = std::max(maxR, p.r);
    }
    const double meanR = sumR / double(down.pixels.size());
    check(std::abs(meanR - 1.75) < 0.05 && minR > 1.0f && maxR < 2.5f,
          "Non-integer HDR downscale averages [-0.5, 4.0] without [0, 1] clamping or aliasing");

    // Pure negative source preserved without clamping
    ImageData allNeg(16, 16);
    std::fill(allNeg.pixels.begin(), allNeg.pixels.end(), RGB(-0.75f, -0.25f, 5.5f));
    const ImageData allNegDown = hdr::resample(allNeg, 5, 5);
    check(std::abs(allNegDown.at(2, 2).r + 0.75f) < 1e-5f &&
          std::abs(allNegDown.at(2, 2).b - 5.5f) < 1e-5f,
          "Out-of-gamut negative and super-white HDR values are preserved");

    // 1D downscales & longEdge = 1
    const ImageData row1d = makeCheckerboard(320, 1, 0.0f, 2.0f);
    const ImageData rowDown5 = hdr::resample(row1d, 64, 1);
    check(rowDown5.width == 64 && rowDown5.height == 1 &&
          std::abs(rowDown5.at(32, 0).r - 0.8f) < 1e-5f &&
          std::abs(rowDown5.at(33, 0).r - 1.2f) < 1e-5f,
          "1D horizontal 5:1 downscale (320x1 -> 64x1) computes exact 5-pixel box averages");
    const ImageData rowDown4 = hdr::resample(row1d, 80, 1);
    check(rowDown4.width == 80 && rowDown4.height == 1 &&
          std::abs(rowDown4.at(40, 0).r - 1.0f) < 1e-5f,
          "1D horizontal 4:1 downscale (320x1 -> 80x1) averages 1-px stripes cleanly");

    const ImageData col1d = makeCheckerboard(1, 320, 0.0f, 2.0f);
    const ImageData colDown5 = hdr::resample(col1d, 1, 64);
    check(colDown5.width == 1 && colDown5.height == 64 &&
          std::abs(colDown5.at(0, 32).r - 0.8f) < 1e-5f &&
          std::abs(colDown5.at(0, 33).r - 1.2f) < 1e-5f,
          "1D vertical 5:1 downscale (1x320 -> 1x64) computes exact 5-pixel box averages");
    const ImageData colDown4 = hdr::resample(col1d, 1, 80);
    check(colDown4.width == 1 && colDown4.height == 80 &&
          std::abs(colDown4.at(0, 40).r - 1.0f) < 1e-5f,
          "1D vertical 4:1 downscale (1x320 -> 1x80) averages 1-px stripes cleanly");

    const ImageData oneByOne = hdr::resample(stripes, 1, 1);
    check(oneByOne.width == 1 && oneByOne.height == 1 &&
          std::abs(oneByOne.at(0, 0).r - 1.75f) < 1e-5f,
          "Downscale to 1x1 averages the entire canvas");

    // Zero / invalid dimension guards
    check(hdr::resample(stripes, 0, 10).pixels.empty() &&
          hdr::resample(ImageData(), 10, 10).pixels.empty(),
          "Zero/empty dimensions return empty ImageData safely");
}

void testExactOneToOneUpscaleAndMixedAxes() {
    // 1:1 bit-exactness including -0.0f sign bit, negative, and > 1.0 values
    ImageData src(4, 4);
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            src.at(x, y) = {
                (x == 0 && y == 0) ? -0.0f : float(x - 1) * 1.5f,
                float(y) * 2.25f,
                -0.125f
            };
        }
    }
    const ImageData same = hdr::resample(src, 4, 4);
    check(std::memcmp(same.pixels.data(), src.pixels.data(), src.pixels.size() * sizeof(RGB)) == 0,
          "1:1 hdr::resample preserves exact pixel bits including -0.0f");

    // Upscale (4x4 -> 13x13) matches sampleHDRResize bit-for-bit
    const ImageData up = hdr::resample(src, 13, 13);
    const auto reader = [&](int x, int y) { return src.at(x, y); };
    bool upParity = (up.width == 13 && up.height == 13);
    for (int y = 0; upParity && y < 13; ++y) {
        for (int x = 0; upParity && x < 13; ++x) {
            const RGB expected = sampleHDRResize(x, y, 4, 4, 13, 13, reader);
            if (std::memcmp(&up.at(x, y), &expected, sizeof(RGB)) != 0) upParity = false;
        }
    }
    check(upParity, "Upscale (4x4 -> 13x13) matches sampleHDRResize bit-for-bit");
    check(std::abs(up.at(12, 12).r - src.at(3, 3).r) < 1e-6f &&
          std::abs(up.at(6, 6).g - (1.5f * 2.25f)) < 1e-5f,
          "Upscale edge-aligned corners and midpoint match");

    // Mixed axes: downscale X + upscale Y (100x4 -> 25x12) and upscale X + downscale Y (4x100 -> 12x25)
    ImageData mixedA(100, 4);
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 100; ++x) {
            mixedA.at(x, y) = {float(x % 2) * 2.0f, float(y), -0.5f};
        }
    }
    const ImageData mixedAOut = hdr::resample(mixedA, 25, 12);
    const auto mixedAReader = [&](int x, int y) { return mixedA.at(x, y); };
    bool mixedAParity = true;
    for (int y = 0; mixedAParity && y < 12; ++y) {
        for (int x = 0; mixedAParity && x < 25; ++x) {
            const RGB expected = sampleHDRResize(x, y, 100, 4, 25, 12, mixedAReader);
            if (std::memcmp(&mixedAOut.at(x, y), &expected, sizeof(RGB)) != 0) mixedAParity = false;
        }
    }
    check(mixedAParity && std::abs(mixedAOut.at(12, 0).r - 1.0f) < 1e-5f &&
          std::abs(mixedAOut.at(12, 11).g - 3.0f) < 1e-5f,
          "Mixed-axis downscale-X/upscale-Y matches sampleHDRResize and averages X");

    ImageData mixedB(4, 100);
    for (int y = 0; y < 100; ++y) {
        for (int x = 0; x < 4; ++x) {
            mixedB.at(x, y) = {float(x), float(y % 2) * 2.0f, 3.0f};
        }
    }
    const ImageData mixedBOut = hdr::resample(mixedB, 12, 25);
    check(std::abs(mixedBOut.at(11, 12).r - 3.0f) < 1e-5f &&
          std::abs(mixedBOut.at(0, 12).g - 1.0f) < 1e-5f,
          "Mixed-axis upscale-X/downscale-Y averages Y and interpolates X");
}

void testMultiTileStreamingParity(const fs::path& root) {
    // 1024x1024 -> 64 tiles of 128x128 (> 32 cachedTiles), exercising LRU eviction
    // and TileReader last-hit cache across unrotated, rotated, cropped, and detail paths.
    constexpr int W = 1024, H = 1024;
    HDRImagePair pair;
    pair.hdr = ImageData(W, H);
    pair.sdr = ImageData(W, H);
    pair.nativeWidth = W;
    pair.nativeHeight = H;
    pair.sourceHeadroom = 4.0f;
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            const float v = float((x * 17 + y * 31) % 991) / 991.0f;
            pair.hdr.at(x, y) = {v * 4.0f - 0.05f, v * 2.0f, v * 1.2f};
            pair.sdr.at(x, y) = {v * 0.9f, v * 0.7f, v * 0.5f};
        }
    }
    HDRRowSource source;
    source.width = W;
    source.height = H;
    source.read = [&](bool hdr, uint32_t row, uint32_t count, RGB* out) {
        const auto& plane = hdr ? pair.hdr : pair.sdr;
        std::copy_n(plane.pixels.data() + size_t(row) * W, size_t(count) * W, out);
    };
    source.finish = [] {};

    for (int mode = 0; mode < 4; ++mode) {
        HDRRenderOptions opts;
        opts.longEdge = 256;
        opts.exposureEV = 0.25f;
        if (mode == 1) {
            opts.geometry.quarter_turns = 1;
        } else if (mode == 2) {
            opts.geometry.quarter_turns = 3;
            opts.geometry.flip_horizontal = true;
            opts.geometry.crop_x = 0.1f;
            opts.geometry.crop_y = 0.15f;
            opts.geometry.crop_width = 0.75f;
            opts.geometry.crop_height = 0.7f;
        } else if (mode == 3) {
            opts.geometry.quarter_turns = 2;
            opts.geometry.straighten_degrees = -8.5f;
            opts.processingVersion = kHdrProcessingDetailVersion;
            opts.detail.clarity = 0.6f;
        }

        const auto expected = renderHDRPair(pair, opts);
        const auto expectedJpeg = hdr::encodeJPEG(expected, 92, kHdrColorDisplayP3);
        const auto streamedJpeg = hdr::encodeStream(source, opts, true, 92, kHdrColorDisplayP3, root);
        check(expectedJpeg == streamedJpeg.jpeg && fs::is_empty(root),
              "Multi-tile 1024x1024 stream JPEG matches renderHDRPair (mode " + std::to_string(mode) + ")");

        const auto files = hdr::renderStreamFiles(source, opts, true, root);
        hdr::storage::File fHdr(files.hdr);
        std::vector<RGB> actual(expected.hdr.pixels.size());
        fHdr.read(0, actual.data(), actual.size() * sizeof(RGB));
        check(std::memcmp(actual.data(), expected.hdr.pixels.data(), actual.size() * sizeof(RGB)) == 0,
              "Multi-tile 1024x1024 stream HDR float pixels are bit-identical to renderHDRPair (mode " + std::to_string(mode) + ")");
    }
}
} // namespace

int main() {
    const auto root = fs::temp_directory_path() /
        ("rawlab-hdr-resample-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        fs::create_directory(root);
        testCheckerboardAntiAliasingAllPaths(root);
        testHDRRangePreservationAnd1DEdgeCases();
        testExactOneToOneUpscaleAndMixedAxes();
        testMultiTileStreamingParity(root);
        fs::remove_all(root);
        std::cout << "HDR resample tests complete, failures: " << rawlab::test::failureCount() << '\n';
        return rawlab::test::exitCode();
    } catch (const std::exception& error) {
        fs::remove_all(root);
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
