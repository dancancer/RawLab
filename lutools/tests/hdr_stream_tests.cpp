#include "core/hdr_stream.h"
#include "core/hdr_jpeg.h"
#include "core/processing_cancellation.h"
#include "platform/hdr_image.h"
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#include <sys/file.h>
#endif
#include <iostream>
#include <stdexcept>
#include <chrono>

using namespace sony2fuji;
namespace fs = std::filesystem;

namespace {
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
HDRImagePair fixture() {
    HDRImagePair pair;
    pair.hdr = ImageData(529, 317); pair.sdr = ImageData(529, 317);
    pair.nativeWidth = 529; pair.nativeHeight = 317;
    for (int y = 0; y < 317; ++y) for (int x = 0; x < 529; ++x) {
        const float v = float((x * 7 + y * 3) % 997) / 997;
        pair.hdr.at(x, y) = {v * 5 - .03f, v * 3, v * 1.7f};
        pair.sdr.at(x, y) = {v * .8f, v * .7f, v * .5f};
    }
    return pair;
}
}

int main() {
    auto root = fs::temp_directory_path() / ("rawlab-stream-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        fs::create_directory(root);
        auto pair = fixture();
        int reads = 0, finishes = 0, failAfter = -1;
        bool cancel = false;
        HDRRowSource source;
        source.width = pair.hdr.width; source.height = pair.hdr.height;
        source.read = [&](bool hdr, uint32_t row, uint32_t count, RGB* result) {
            if (++reads == failAfter) throw std::runtime_error("injected decoder read failure");
            const auto& image = hdr ? pair.hdr : pair.sdr;
            check(row + count <= uint32_t(image.height), "Source reader asked outside native canvas");
            std::copy_n(image.pixels.data() + size_t(row) * image.width, size_t(count) * image.width, result);
        };
        source.finish = [&] { ++finishes; };
        HDRRenderOptions options;
        options.exposureEV = .25f; options.temperature = 7200; options.tint = 5;
        options.contrast = 12; options.highlights = -17; options.shadows = 7;
        int passed = 0;
        for (int transform = 0; transform < 3; ++transform) for (bool hdr : {true, false}) {
            options.geometry = {};
            if (transform) {
                options.geometry.quarter_turns = 1; options.geometry.flip_horizontal = true;
                options.geometry.crop_x = .13f; options.geometry.crop_width = .69f;
                options.geometry.crop_y = .07f; options.geometry.crop_height = .81f;
            }
            if (transform == 2) {
                options.geometry.straighten_degrees = -13.5f;
                options.geometry.perspective_horizontal = .31f; options.geometry.perspective_vertical = -.22f;
            }
            for (uint32_t edge : {0u, 151u}) {
                options.longEdge = edge;
                const auto expected = renderHDRPair(pair, options);
                const auto jpeg = hdr ? hdr::encodeJPEG(expected, 95, SONY2FUJI_HDR_COLOR_DISPLAY_P3)
                                      : hdr::encodeSDRJPEG(expected.sdr, 95);
                const auto result = hdr::encodeStream(source, options, hdr, 95, SONY2FUJI_HDR_COLOR_DISPLAY_P3, root);
                check(jpeg == result.jpeg, "Stream JPEG differs from full-frame reference");
                check(result.width == uint32_t(expected.hdr.width) && result.height == uint32_t(expected.hdr.height), "Output size differs");
                check(result.outputNativeWidth == expected.outputNativeWidth && result.outputNativeHeight == expected.outputNativeHeight,
                    "Native geometry size differs after resize");
                if (hdr) check(result.editedHeadroom == expected.editedHeadroom, "Edited headroom differs");
                check(fs::is_empty(root), "Successful stream left temporary files");
                ++passed;
            }
        }
        check(finishes == passed, "Decoder was not released once per completed decode");
        reads = 0; failAfter = 2;
        bool rejected = false;
        try { (void)hdr::encodeStream(source, options, true, 95, SONY2FUJI_HDR_COLOR_DISPLAY_P3, root); }
        catch (const std::runtime_error&) { rejected = true; }
        check(rejected && fs::is_empty(root), "Decoder failure left partial files");
        failAfter = -1;
        const auto reader = source.read;
        source.read = [&](bool hdr, uint32_t row, uint32_t count, RGB* result) {
            reader(hdr, row, count, result); cancel = true;
        };
        ProcessingCancellationScope cancellation({[](void* context) { return *static_cast<bool*>(context) ? 1 : 0; }, &cancel});
        rejected = false;
        try { (void)hdr::encodeStream(source, options, true, 95, SONY2FUJI_HDR_COLOR_DISPLAY_P3, root); }
        catch (const ProcessingCancelled&) { rejected = true; }
        check(rejected && fs::is_empty(root), "Cancellation did not clean decode work");
        source.read = reader; cancel = false;
        source.finish = [&] { cancel = true; };
        rejected = false;
        try { (void)hdr::encodeStream(source, options, true, 95, SONY2FUJI_HDR_COLOR_DISPLAY_P3, root); }
        catch (const ProcessingCancelled&) { rejected = true; }
        check(rejected && fs::is_empty(root), "Post-decode cancellation continued to encode");
        source.finish = [] {}; cancel = false;
        const auto recovered = hdr::encodeStream(source, options, true, 95, SONY2FUJI_HDR_COLOR_DISPLAY_P3, root);
        check(!recovered.jpeg.empty() && fs::is_empty(root), "Stream did not recover after failures");
        options.geometry = {}; options.longEdge = 0;
        const float original = pair.hdr.pixels[0].r;
        pair.hdr.pixels[0].r = std::numeric_limits<float>::infinity();
        rejected = false;
        try { (void)hdr::encodeStream(source, options, true, 95, SONY2FUJI_HDR_COLOR_DISPLAY_P3, root); }
        catch (const std::invalid_argument&) { rejected = true; }
        check(rejected && fs::is_empty(root), "Nonfinite source was exported or leaked files");
        pair.hdr.pixels[0].r = original;
        const auto abandoned = root / "RawLab-HDR-abandoned", active = root / "RawLab-HDR-active";
        const auto unrelated = root / "RawLab-HDR-unmarked";
        for (const auto& path : {abandoned, active, unrelated}) {
            fs::create_directory(path); std::ofstream(path / "keep") << "fixture";
        }
        std::ofstream(abandoned / ".rawlab-stream.lock");
#ifdef _WIN32
        const auto activeLock = CreateFileW((active / ".rawlab-stream.lock").c_str(), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_DELETE, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        check(activeLock != INVALID_HANDLE_VALUE, "Cannot lock live scratch fixture");
#else
        const int activeLock = open((active / ".rawlab-stream.lock").c_str(), O_CREAT | O_RDWR, 0600);
        check(activeLock >= 0 && flock(activeLock, LOCK_EX | LOCK_NB) == 0, "Cannot lock live scratch fixture");
#endif
        (void)hdr::encodeStream(source, options, false, 95, SONY2FUJI_HDR_COLOR_DISPLAY_P3, root);
        check(!fs::exists(abandoned) && fs::exists(active / "keep") && fs::exists(unrelated / "keep"),
            "Recovery retained an abandoned spool or removed active/unmarked files");
#ifdef _WIN32
        CloseHandle(activeLock);
#else
        close(activeLock);
#endif
        (void)hdr::encodeStream(source, options, false, 95, SONY2FUJI_HDR_COLOR_DISPLAY_P3, root);
        check(!fs::exists(active) && fs::exists(unrelated / "keep"), "Released scratch was not recovered safely");
        fs::remove_all(unrelated);
        fs::remove(root);
        std::cout << "PASS " << passed << " byte-identical stream JPEGs; decoder failure, cancellation, cleanup and recovery\n";
    } catch (const std::exception& error) {
        fs::remove_all(root); std::cerr << error.what() << '\n'; return 1;
    }
}
