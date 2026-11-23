#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "sony2fuji/raw_processor.h"
#include "core/hdr_jpeg.h"
#include "core/hdr_rendering.h"
#include "core/hdr_stream.h"
#include "core/quantize_dither.h"
#include "platform/hdr_image.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <vector>

namespace {

std::vector<uint8_t> readBytes(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    assert(file.good());
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(file)), {});
}

uint32_t readBE32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

uint16_t readBE16(const uint8_t* p) {
    return static_cast<uint16_t>((uint16_t(p[0]) << 8) | uint16_t(p[1]));
}

std::vector<uint8_t> extractSingleSrgbIccProfile(const std::vector<uint8_t>& jpeg) {
    assert(jpeg.size() > 4 && jpeg[0] == 0xFF && jpeg[1] == 0xD8);
    std::map<uint8_t, std::vector<uint8_t>> chunks;
    uint8_t totalChunks = 0;
    size_t pos = 2;
    while (pos + 1 < jpeg.size()) {
        if (jpeg[pos] != 0xFF) {
            ++pos;
            continue;
        }
        while (pos < jpeg.size() && jpeg[pos] == 0xFF) ++pos;
        if (pos >= jpeg.size()) break;
        const uint8_t marker = jpeg[pos++];
        if (marker == 0xD9 || marker == 0xDA) break; // EOI or SOS
        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) continue;
        assert(pos + 2 <= jpeg.size());
        const uint16_t segLen = readBE16(&jpeg[pos]);
        assert(segLen >= 2 && pos + segLen <= jpeg.size());
        if (marker == 0xE2 && segLen >= 16 &&
            std::memcmp(&jpeg[pos + 2], "ICC_PROFILE\0", 12) == 0) {
            const uint8_t seq = jpeg[pos + 14];
            const uint8_t count = jpeg[pos + 15];
            assert(seq >= 1 && count >= 1 && seq <= count);
            if (totalChunks != 0) assert(totalChunks == count);
            totalChunks = count;
            assert(chunks.count(seq) == 0);
            chunks.emplace(seq, std::vector<uint8_t>(jpeg.begin() + pos + 16, jpeg.begin() + pos + segLen));
        }
        pos += segLen;
    }
    assert(totalChunks >= 1 && chunks.size() == totalChunks);
    std::vector<uint8_t> icc;
    for (const auto& entry : chunks) {
        icc.insert(icc.end(), entry.second.begin(), entry.second.end());
    }
    assert(icc.size() >= 132);
    assert(readBE32(icc.data()) <= icc.size());
    assert(std::memcmp(icc.data() + 12, "mntr", 4) == 0);
    assert(std::memcmp(icc.data() + 16, "RGB ", 4) == 0);
    assert(std::memcmp(icc.data() + 20, "XYZ ", 4) == 0);
    assert(std::memcmp(icc.data() + 36, "acsp", 4) == 0);
    const uint32_t tagCount = readBE32(icc.data() + 128);
    assert(tagCount >= 6 && 132 + size_t(tagCount) * 12 <= icc.size());
    bool hasR = false, hasG = false, hasB = false, hasRTrc = false, hasGTrc = false, hasBTrc = false;
    for (uint32_t i = 0; i < tagCount; ++i) {
        const uint8_t* entry = icc.data() + 132 + size_t(i) * 12;
        if (std::memcmp(entry, "rXYZ", 4) == 0) hasR = true;
        if (std::memcmp(entry, "gXYZ", 4) == 0) hasG = true;
        if (std::memcmp(entry, "bXYZ", 4) == 0) hasB = true;
        if (std::memcmp(entry, "rTRC", 4) == 0) hasRTrc = true;
        if (std::memcmp(entry, "gTRC", 4) == 0) hasGTrc = true;
        if (std::memcmp(entry, "bTRC", 4) == 0) hasBTrc = true;
    }
    assert(hasR && hasG && hasB && hasRTrc && hasGTrc && hasBTrc);
    return icc;
}

std::vector<uint8_t> decodeJpegRgb(const std::filesystem::path& path, uint32_t& width, uint32_t& height) {
    sony2fuji_buffer out{};
    const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &out);
    assert(status == SONY2FUJI_STATUS_OK);
    width = out.width;
    height = out.height;
    std::vector<uint8_t> pixels(static_cast<const uint8_t*>(out.data),
                                static_cast<const uint8_t*>(out.data) + out.size_bytes);
    sony2fuji_release_buffer(&out);
    return pixels;
}

double edgeContrastMetric(const uint8_t* rgb, uint32_t width, uint32_t height, uint32_t channels) {
    double sum = 0.0;
    size_t count = 0;
    for (uint32_t y = 2; y + 2 < height; ++y) {
        for (uint32_t x = 2; x + 2 < width; ++x) {
            const size_t idx = (size_t(y) * width + x) * channels;
            const size_t right = (size_t(y) * width + (x + 1)) * channels;
            const size_t down = (size_t(y + 1) * width + x) * channels;
            const double l = 0.2126 * rgb[idx] + 0.7152 * rgb[idx + 1] + 0.0722 * rgb[idx + 2];
            const double lr = 0.2126 * rgb[right] + 0.7152 * rgb[right + 1] + 0.0722 * rgb[right + 2];
            const double ld = 0.2126 * rgb[down] + 0.7152 * rgb[down + 1] + 0.0722 * rgb[down + 2];
            sum += std::abs(l - lr) + std::abs(l - ld);
            ++count;
        }
    }
    return count > 0 ? sum / double(count) : 0.0;
}

double hdrEdgeContrastMetric(const sony2fuji::ImageData& image) {
    double sum = 0.0;
    size_t count = 0;
    for (int y = 2; y + 2 < image.height; ++y) {
        for (int x = 2; x + 2 < image.width; ++x) {
            const auto& p = image.at(x, y);
            const auto& pr = image.at(x + 1, y);
            const auto& pd = image.at(x, y + 1);
            const double l = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b;
            const double lr = 0.2126 * pr.r + 0.7152 * pr.g + 0.0722 * pr.b;
            const double ld = 0.2126 * pd.r + 0.7152 * pd.g + 0.0722 * pd.b;
            sum += std::abs(l - lr) + std::abs(l - ld);
            ++count;
        }
    }
    return count > 0 ? sum / double(count) : 0.0;
}

std::string makeRecipeJson(const std::string& sharpening, uint32_t longEdge, const std::string& outputFormat = "jpeg") {
    std::string sizeJson = longEdge > 0
        ? ("{\"mode\": \"limit_long_edge\", \"long_edge\": " + std::to_string(longEdge) + "}")
        : "{\"mode\": \"native\"}";
    std::string sharpenJson = sharpening == "off" ? "" : (", \"output_sharpening\": \"" + sharpening + "\"");
    return std::string("{")
        + "\"schema_version\": 17,"
        + "\"input\": {\"path\": \"buffer\", \"type\": \"raster\"},"
        + "\"processing\": {\"family\": \"rawlab\", \"version\": 3, \"quality\": \"standard\"},"
        + "\"edits\": {"
        + "  \"exposure\": {\"mode\": \"sensor\", \"ev\": 0.0, \"brightness\": 1.0},"
        + "  \"white_balance\": {\"mode\": \"none\"},"
        + "  \"look\": {\"path\": null, \"strength\": 0.0},"
        + "  \"geometry\": {\"crop\": {\"x\": 0, \"y\": 0, \"width\": 1, \"height\": 1}, \"quarter_turns\": 0, \"flip_horizontal\": false, \"flip_vertical\": false, \"straighten_degrees\": 0, \"perspective\": {\"horizontal\": 0, \"vertical\": 0}},"
        + "  \"tone\": {\"contrast\": 1.0, \"saturation\": 1.0, \"highlights\": 0.0, \"shadows\": 0.0, \"s_curve\": 0.0, \"curve\": {\"mode\": \"legacy\", \"points\": []}},"
        + "  \"detail\": {\"sharpening\": 0.0},"
        + "  \"hsl\": {\"hue\": [0,0,0,0,0,0,0,0], \"saturation\": [0,0,0,0,0,0,0,0], \"lightness\": [0,0,0,0,0,0,0,0]},"
        + "  \"effects\": {\"vignette_amount\": 0.0, \"vignette_midpoint\": 50.0, \"vignette_roundness\": 0.0, \"vignette_feather\": 50.0, \"vignette_highlights\": 0.0, \"grain_amount\": 0.0, \"grain_size\": 25.0, \"grain_roughness\": 50.0},"
        + "  \"denoise\": {\"raw_level\": 0, \"chroma_mode\": 0, \"wavelet\": {\"enabled\": false, \"luma\": 0.0, \"chroma\": 0.0, \"coarse\": 0.0}},"
        + "  \"lens_correction\": {\"distortion\": false, \"tca\": false, \"auto_crop\": false, \"profile_id\": null}"
        + "},"
        + "\"output\": {\"path\": \"out\", \"format\": \"" + outputFormat + "\", \"jpeg_quality\": 95, \"size\": " + sizeJson + sharpenJson + "}"
        + "}";
}

void testJpegApp2IccProfile(const std::filesystem::path& dir) {
    sony2fuji::ImageData image(64, 64);
    for (int y = 0; y < 64; ++y) {
        for (int x = 0; x < 64; ++x) {
            image.at(x, y) = {float(x) / 63.0f, float(y) / 63.0f, 0.5f};
        }
    }
    const auto directPath = dir / "direct.jpg";
    assert(sony2fuji::ImageEncoder::saveJPEG(image, directPath.u8string(), 92) == sony2fuji::ErrorCode::Success);
    const auto directBytes = readBytes(directPath);
    const auto directIcc = extractSingleSrgbIccProfile(directBytes);
    assert(directIcc.size() >= 132);

    // Also verify sony2fuji_process JPEG export embeds valid APP2 ICC_PROFILE
    std::vector<uint8_t> input(64 * 64 * 3, 128);
    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    const auto apiPath = dir / "api.jpg";
    const std::string apiPathStr = apiPath.u8string();
    sony2fuji_request req{};
    req.version = SONY2FUJI_REQUEST_VERSION;
    req.struct_size = sizeof(req);
    req.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    req.input_pixels = input.data();
    req.input_width = 64;
    req.input_height = 64;
    req.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    req.input_color_space = SONY2FUJI_COLOR_SRGB;
    req.temperature = 6500.0f;
    req.brightness = req.contrast = req.saturation = 1.0f;
    req.wb_mode = SONY2FUJI_WB_CAMERA;
    req.intent = SONY2FUJI_INTENT_FINAL;
    req.size_mode = SONY2FUJI_SIZE_NATIVE;
    req.output_target = SONY2FUJI_TARGET_FILE;
    req.output_format = SONY2FUJI_OUTPUT_JPEG;
    req.output_path = apiPathStr.c_str();
    req.jpeg_quality = 95;
    assert(sony2fuji_process(session, &req, nullptr) == SONY2FUJI_STATUS_OK);
    sony2fuji_session_destroy(session);
    const auto apiIcc = extractSingleSrgbIccProfile(readBytes(apiPath));
    assert(apiIcc == directIcc);

    // Verify invalid path leaves no .tmp leak and preserves existing target
    const auto missingParent = dir / "does_not_exist" / "fail.jpg";
    assert(sony2fuji::ImageEncoder::saveJPEG(image, missingParent.u8string(), 90) == sony2fuji::ErrorCode::IOError);

    // Verify HDR SDR JPEG export embeds APP2 ICC_PROFILE too
    sony2fuji::HDRImagePair pair;
    pair.hdr = sony2fuji::ImageData(32, 32);
    pair.sdr = sony2fuji::ImageData(32, 32);
    for (size_t i = 0; i < pair.sdr.pixels.size(); ++i) {
        pair.sdr.pixels[i] = {0.2f, 0.4f, 0.6f};
        pair.hdr.pixels[i] = {0.4f, 0.8f, 1.2f};
    }
    const auto hdrSdrPath = dir / "hdr_sdr.jpg";
    sony2fuji::HDRSdrExportConfig sdrCfg{};
    sdrCfg.outputFormat = sony2fuji::kHdrSdrOutputJpeg;
    sdrCfg.quality = 92;
    sony2fuji::hdr::exportSDR(pair, sdrCfg, hdrSdrPath.u8string().c_str());
    const auto hdrSdrIcc = extractSingleSrgbIccProfile(readBytes(hdrSdrPath));
    const auto hdrSdrPath2 = dir / "hdr_sdr_repeat.jpg";
    sony2fuji::hdr::exportSDR(pair, sdrCfg, hdrSdrPath2.u8string().c_str());
    const auto hdrSdrIcc2 = extractSingleSrgbIccProfile(readBytes(hdrSdrPath2));
    assert(hdrSdrIcc == hdrSdrIcc2);
#if !defined(__APPLE__)
    static constexpr uint8_t kExpectedUtcDate[12] = {
        0x07, 0xEA, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    };
    assert(std::memcmp(directIcc.data() + 24, kExpectedUtcDate, sizeof(kExpectedUtcDate)) == 0);
    assert(hdrSdrIcc == directIcc);
#endif

    std::cout << "PASS testJpegApp2IccProfile\n";
}

void testDeterministic8BitDithering(const std::filesystem::path& dir) {
    // 1. Exact 0.0f and 1.0f boundaries must produce zero noise across all (x, y)
    for (uint32_t y = 0; y < 32; ++y) {
        for (uint32_t x = 0; x < 64; ++x) {
            assert(sony2fuji::quantizeFloatToUint8Dithered(0.0f, x, y) == 0);
            assert(sony2fuji::quantizeFloatToUint8Dithered(-0.25f, x, y) == 0);
            assert(sony2fuji::quantizeFloatToUint8Dithered(1.0f, x, y) == 255);
            assert(sony2fuji::quantizeFloatToUint8Dithered(1.5f, x, y) == 255);
        }
    }

    // 2. Smooth 16-bit sky gradient in buffer output: anti-banding dithered transitions + exact endpoints + repeatability
    const int width = 512, height = 32;
    std::vector<uint8_t> rgba16(size_t(width) * height * 8);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            uint16_t v = 0;
            if (x == 0) v = 0;
            else if (x == width - 1) v = 65535;
            else {
                // Smooth ramp across ~130..145 in sRGB uint8
                const double t = double(x - 1) / double(width - 3);
                const double srgb = 0.50 + 0.06 * t;
                v = static_cast<uint16_t>(std::lround(srgb * 65535.0));
            }
            const size_t base = (size_t(y) * width + x) * 8;
            for (int c = 0; c < 3; ++c) {
                rgba16[base + c * 2 + 0] = static_cast<uint8_t>(v & 0xFFu);
                rgba16[base + c * 2 + 1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
            }
            rgba16[base + 6] = 0xFF;
            rgba16[base + 7] = 0xFF;
        }
    }

    auto runBuffer = [&]() {
        sony2fuji_session* session = nullptr;
        assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
        sony2fuji_request req{};
        req.version = SONY2FUJI_REQUEST_VERSION;
        req.struct_size = sizeof(req);
        req.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
        req.input_pixels = rgba16.data();
        req.input_width = width;
        req.input_height = height;
        req.input_pixel_format = SONY2FUJI_PIXEL_RGBA16;
        req.input_color_space = SONY2FUJI_COLOR_SRGB;
        req.temperature = 6500.0f;
        req.brightness = req.contrast = req.saturation = 1.0f;
        req.wb_mode = SONY2FUJI_WB_CAMERA;
        req.intent = SONY2FUJI_INTENT_FINAL;
        req.size_mode = SONY2FUJI_SIZE_NATIVE;
        req.output_target = SONY2FUJI_TARGET_BUFFER;
        req.output_format = SONY2FUJI_OUTPUT_RGB8;
        sony2fuji_buffer out{};
        assert(sony2fuji_process(session, &req, &out) == SONY2FUJI_STATUS_OK);
        std::vector<uint8_t> bytes(static_cast<const uint8_t*>(out.data),
                                   static_cast<const uint8_t*>(out.data) + out.size_bytes);
        sony2fuji_release_buffer(&out);
        sony2fuji_session_destroy(session);
        return bytes;
    };

    const auto buf1 = runBuffer();
    const auto buf2 = runBuffer();
    assert(buf1 == buf2);

    // Check endpoints have zero noise across all rows and monochrome R==G==B
    int verticalDiffs = 0;
    for (int y = 0; y < height; ++y) {
        const size_t left = (size_t(y) * width + 0) * 3;
        const size_t right = (size_t(y) * width + (width - 1)) * 3;
        assert(buf1[left] == 0 && buf1[left + 1] == 0 && buf1[left + 2] == 0);
        assert(buf1[right] == 255 && buf1[right + 1] == 255 && buf1[right + 2] == 255);
        for (int x = 1; x + 1 < width; ++x) {
            const size_t idx = (size_t(y) * width + x) * 3;
            assert(buf1[idx] == buf1[idx + 1] && buf1[idx] == buf1[idx + 2]); // monochrome dither
            if (y > 0) {
                const size_t prev = (size_t(y - 1) * width + x) * 3;
                if (buf1[idx] != buf1[prev]) ++verticalDiffs;
            }
        }
    }
    // Without dithering, identical rows have 0 vertical variation; with (x, y) dithering, rows vary across plateaus.
    assert(verticalDiffs > 100);

    // 3. saveJPEG must also use coordinate-hashed dithering on boundary-free smooth gradient + pure black/white borders
    sony2fuji::ImageData jpegGrad(128, 32);
    for (int y = 0; y < 32; ++y) {
        for (int x = 0; x < 128; ++x) {
            float v = (x == 0) ? 0.0f : (x == 127 ? 1.0f : (127.5f / 255.0f));
            jpegGrad.at(x, y) = {v, v, v};
        }
    }
    const auto jpgA = dir / "dither_a.jpg";
    const auto jpgB = dir / "dither_b.jpg";
    assert(sony2fuji::ImageEncoder::saveJPEG(jpegGrad, jpgA.u8string(), 100) == sony2fuji::ErrorCode::Success);
    assert(sony2fuji::ImageEncoder::saveJPEG(jpegGrad, jpgB.u8string(), 100) == sony2fuji::ErrorCode::Success);
    assert(readBytes(jpgA) == readBytes(jpgB));
    uint32_t dw = 0, dh = 0;
    const auto decoded = decodeJpegRgb(jpgA, dw, dh);
    assert(dw == 128 && dh == 32);
    int ditherValuesSeen = 0;
    for (int y = 0; y < 32; ++y) {
        const uint8_t mid = decoded[(size_t(y) * 128 + 64) * 4];
        if (y > 0 && mid != decoded[(size_t(y - 1) * 128 + 64) * 4]) ++ditherValuesSeen;
    }
    assert(ditherValuesSeen > 0);

    std::cout << "PASS testDeterministic8BitDithering\n";
}

void testPostResizeOutputSharpening() {
    const int srcW = 128, srcH = 128;
    std::vector<uint8_t> input(size_t(srcW) * srcH * 3);
    for (int y = 0; y < srcH; ++y) {
        for (int x = 0; x < srcW; ++x) {
            const bool checker = ((x / 4) + (y / 4)) % 2 == 0;
            const uint8_t v = checker ? 170 : 90;
            const size_t idx = (size_t(y) * srcW + x) * 3;
            input[idx + 0] = v;
            input[idx + 1] = v;
            input[idx + 2] = v;
        }
    }

    auto renderWith = [&](const std::string& level, uint32_t longEdge, sony2fuji_gpu_mode gpuMode) {
        sony2fuji_session* session = nullptr;
        assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
        sony2fuji_gpu_config gpu{};
        gpu.version = SONY2FUJI_GPU_CONFIG_VERSION;
        gpu.struct_size = sizeof(gpu);
        gpu.mode = gpuMode;
        assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);

        const std::string recipe = makeRecipeJson(level, longEdge);
        assert(sony2fuji_apply_params(session, recipe.c_str()) == SONY2FUJI_STATUS_OK);

        sony2fuji_request req{};
        req.version = SONY2FUJI_REQUEST_VERSION;
        req.struct_size = sizeof(req);
        req.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
        req.input_pixels = input.data();
        req.input_width = srcW;
        req.input_height = srcH;
        req.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
        req.input_color_space = SONY2FUJI_COLOR_SRGB;
        req.temperature = 6500.0f;
        req.brightness = req.contrast = req.saturation = 1.0f;
        req.wb_mode = SONY2FUJI_WB_CAMERA;
        req.intent = SONY2FUJI_INTENT_FINAL;
        req.size_mode = longEdge > 0 ? SONY2FUJI_SIZE_LIMIT_LONG_EDGE : SONY2FUJI_SIZE_NATIVE;
        req.long_edge = longEdge;
        req.output_target = SONY2FUJI_TARGET_BUFFER;
        req.output_format = SONY2FUJI_OUTPUT_RGB8;
        sony2fuji_buffer out{};
        const auto status = sony2fuji_process(session, &req, &out);
        if (status == SONY2FUJI_STATUS_UNSUPPORTED && gpuMode == SONY2FUJI_GPU_FORCE) {
            sony2fuji_session_destroy(session);
            return std::vector<uint8_t>{};
        }
        assert(status == SONY2FUJI_STATUS_OK);
        assert(out.width == (longEdge > 0 ? longEdge : uint32_t(srcW)));
        std::vector<uint8_t> bytes(static_cast<const uint8_t*>(out.data),
                                   static_cast<const uint8_t*>(out.data) + out.size_bytes);
        sony2fuji_release_buffer(&out);
        sony2fuji_session_destroy(session);
        return bytes;
    };

    // 1. Off must be bit-identical to baseline (without apply_params)
    sony2fuji_session* baseSession = nullptr;
    assert(sony2fuji_session_create(&baseSession) == SONY2FUJI_STATUS_OK);
    sony2fuji_request baseReq{};
    baseReq.version = SONY2FUJI_REQUEST_VERSION;
    baseReq.struct_size = sizeof(baseReq);
    baseReq.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    baseReq.input_pixels = input.data();
    baseReq.input_width = srcW;
    baseReq.input_height = srcH;
    baseReq.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    baseReq.input_color_space = SONY2FUJI_COLOR_SRGB;
    baseReq.temperature = 6500.0f;
    baseReq.brightness = baseReq.contrast = baseReq.saturation = 1.0f;
    baseReq.wb_mode = SONY2FUJI_WB_CAMERA;
    baseReq.intent = SONY2FUJI_INTENT_FINAL;
    baseReq.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE;
    baseReq.long_edge = 64;
    baseReq.output_target = SONY2FUJI_TARGET_BUFFER;
    baseReq.output_format = SONY2FUJI_OUTPUT_RGB8;
    sony2fuji_buffer baseOut{};
    assert(sony2fuji_process(baseSession, &baseReq, &baseOut) == SONY2FUJI_STATUS_OK);
    std::vector<uint8_t> baseline(static_cast<const uint8_t*>(baseOut.data),
                                  static_cast<const uint8_t*>(baseOut.data) + baseOut.size_bytes);
    sony2fuji_release_buffer(&baseOut);
    sony2fuji_session_destroy(baseSession);

    const auto offBytes = renderWith("off", 64, SONY2FUJI_GPU_OFF);
    const auto lowBytes = renderWith("low", 64, SONY2FUJI_GPU_OFF);
    const auto stdBytes = renderWith("standard", 64, SONY2FUJI_GPU_OFF);
    const auto highBytes = renderWith("high", 64, SONY2FUJI_GPU_OFF);
    assert(offBytes == baseline);

    const double cOff = edgeContrastMetric(offBytes.data(), 64, 64, 3);
    const double cLow = edgeContrastMetric(lowBytes.data(), 64, 64, 3);
    const double cStd = edgeContrastMetric(stdBytes.data(), 64, 64, 3);
    const double cHigh = edgeContrastMetric(highBytes.data(), 64, 64, 3);
    assert(cOff < cLow && cLow < cStd && cStd < cHigh);

    // 2. GPU Auto (and Force if Metal/GPU available) also receives post-resize output sharpening
    const auto gpuOff = renderWith("off", 64, SONY2FUJI_GPU_AUTO);
    const auto gpuHigh = renderWith("high", 64, SONY2FUJI_GPU_AUTO);
    assert(edgeContrastMetric(gpuOff.data(), 64, 64, 3) < edgeContrastMetric(gpuHigh.data(), 64, 64, 3));
    const auto gpuForceHigh = renderWith("high", 64, SONY2FUJI_GPU_FORCE);
    if (!gpuForceHigh.empty()) {
        const auto gpuForceOff = renderWith("off", 64, SONY2FUJI_GPU_FORCE);
        assert(edgeContrastMetric(gpuForceOff.data(), 64, 64, 3) < edgeContrastMetric(gpuForceHigh.data(), 64, 64, 3));
    }

    // 3. HDR v9 output sharpening (both renderHDRPairOwned and streamed RenderedRows)
    sony2fuji::HDRImagePair src;
    src.hdr = sony2fuji::ImageData(srcW, srcH);
    src.sdr = sony2fuji::ImageData(srcW, srcH);
    src.nativeWidth = srcW;
    src.nativeHeight = srcH;
    src.sourceHeadroom = 2.0f;
    src.sourceQuality = sony2fuji::HDRQuality::Final;
    src.renderQuality = sony2fuji::HDRQuality::Final;
    for (int y = 0; y < srcH; ++y) {
        for (int x = 0; x < srcW; ++x) {
            const bool checker = ((x / 4) + (y / 4)) % 2 == 0;
            const float s = checker ? 0.55f : 0.15f;
            src.sdr.at(x, y) = {s, s, s};
            src.hdr.at(x, y) = {s * 2.0f, s * 2.0f, s * 2.0f};
        }
    }
    auto makeHdrOpts = [&](sony2fuji::OutputSharpening level) {
        sony2fuji::HDRRenderOptions opts;
        opts.processingVersion = sony2fuji::kHdrProcessingV2GradingCurveVersion;
        opts.intent = sony2fuji::HDRQuality::Final;
        opts.longEdge = 64;
        opts.outputSharpening = level;
        return opts;
    };
    const auto hdrOff = sony2fuji::renderHDRPair(src, makeHdrOpts(sony2fuji::OutputSharpening::Off));
    const auto hdrLow = sony2fuji::renderHDRPair(src, makeHdrOpts(sony2fuji::OutputSharpening::Low));
    const auto hdrStd = sony2fuji::renderHDRPair(src, makeHdrOpts(sony2fuji::OutputSharpening::Standard));
    const auto hdrHigh = sony2fuji::renderHDRPair(src, makeHdrOpts(sony2fuji::OutputSharpening::High));
    const double hOff = hdrEdgeContrastMetric(hdrOff.sdr);
    const double hLow = hdrEdgeContrastMetric(hdrLow.sdr);
    const double hStd = hdrEdgeContrastMetric(hdrStd.sdr);
    const double hHigh = hdrEdgeContrastMetric(hdrHigh.sdr);
    assert(hOff < hLow && hLow < hStd && hStd < hHigh);
    assert(hdrEdgeContrastMetric(hdrOff.hdr) < hdrEdgeContrastMetric(hdrHigh.hdr));

    // Verify HDR C API v9 request routes output_sharpening cleanly
    sony2fuji_session* hdrSession = nullptr;
    assert(sony2fuji_session_create(&hdrSession) == SONY2FUJI_STATUS_OK);
    auto fillV9 = [&](uint32_t sharpLevel) {
        sony2fuji_hdr_request_v9 v9{};
        auto& v8 = v9.base;
        auto& v7 = v8.base;
        auto& v6 = v7.base;
        auto& v5 = v6.base;
        auto& v4 = v5.base;
        auto& v3 = v4.base;
        auto& v2 = v3.base;
        auto& v1 = v2.base;
        v1.version = 1;
        v1.struct_size = sizeof(v9);
        v1.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_V2_GRADING_CURVE_VERSION;
        v1.intent = SONY2FUJI_INTENT_FINAL;
        v1.temperature = 6500.0f;
        v1.long_edge = 64;
        v1.crop_width = 1.0f;
        v1.crop_height = 1.0f;
        v2.curve.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
        v2.curve.struct_size = sizeof(v2.curve);
        v3.hsl.version = SONY2FUJI_HSL_CONFIG_VERSION;
        v3.hsl.struct_size = sizeof(v3.hsl);
        v3.grading.version = SONY2FUJI_COLOR_GRADING_CONFIG_VERSION;
        v3.grading.struct_size = sizeof(v3.grading);
        v5.effects.version = SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION;
        v5.effects.struct_size = sizeof(v5.effects);
        v5.effects.vignette_midpoint = 50.0f;
        v5.effects.vignette_feather = 50.0f;
        v5.effects.grain_size = 25.0f;
        v5.effects.grain_roughness = 50.0f;
        for (auto& ch : v8.channels) {
            ch.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
            ch.struct_size = sizeof(ch);
        }
        v9.output_sharpening = sharpLevel;
        v9.parametric_curve.version = SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION;
        v9.parametric_curve.struct_size = sizeof(v9.parametric_curve);
        v9.parametric_curve.split_shadow = 0.25f;
        v9.parametric_curve.split_midtone = 0.50f;
        v9.parametric_curve.split_highlight = 0.75f;
        v9.grading_v2.version = SONY2FUJI_COLOR_GRADING_V2_CONFIG_VERSION;
        v9.grading_v2.struct_size = sizeof(v9.grading_v2);
        v9.grading_v2.blending = 50.0f;
        return v9;
    };
    const auto reqOff = fillV9(SONY2FUJI_OUTPUT_SHARPENING_OFF);
    const auto reqHigh = fillV9(SONY2FUJI_OUTPUT_SHARPENING_HIGH);
    sony2fuji_hdr_image_pair_v1 cSrc{};
    cSrc.version = 1;
    cSrc.struct_size = sizeof(cSrc);
    cSrc.native_width = srcW;
    cSrc.native_height = srcH;
    cSrc.output_native_width = srcW;
    cSrc.output_native_height = srcH;
    cSrc.orientation_applied = 1;
    cSrc.source_headroom = 2.0f;
    cSrc.source_headroom_kind = SONY2FUJI_HDR_HEADROOM_DECLARED;
    cSrc.decode_revision = 1;
    cSrc.source_intent = SONY2FUJI_INTENT_FINAL;
    cSrc.render_intent = SONY2FUJI_INTENT_FINAL;
    cSrc.hdr.version = cSrc.sdr.version = 1;
    cSrc.hdr.struct_size = cSrc.sdr.struct_size = sizeof(sony2fuji_hdr_buffer_v1);
    cSrc.hdr.width = cSrc.sdr.width = srcW;
    cSrc.hdr.height = cSrc.sdr.height = srcH;
    cSrc.hdr.stride_bytes = cSrc.sdr.stride_bytes = size_t(srcW) * 3 * sizeof(float);
    cSrc.hdr.size_bytes = cSrc.sdr.size_bytes = cSrc.hdr.stride_bytes * srcH;
    cSrc.hdr.pixel_format = cSrc.sdr.pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
    cSrc.hdr.color_encoding = cSrc.sdr.color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
    cSrc.hdr.content_headroom = 2.0f;
    cSrc.sdr.content_headroom = 1.0f;
    cSrc.hdr.headroom_kind = cSrc.sdr.headroom_kind = SONY2FUJI_HDR_HEADROOM_MEASURED;
    cSrc.hdr.data = src.hdr.pixels.data();
    cSrc.sdr.data = src.sdr.pixels.data();
    sony2fuji_hdr_image_pair_v1 cOutOff{}, cOutHigh{};
    cOutOff.version = cOutHigh.version = 1;
    cOutOff.struct_size = cOutHigh.struct_size = sizeof(sony2fuji_hdr_image_pair_v1);
    sony2fuji_hdr_diagnostic_v1 diag{};
    diag.version = 1;
    diag.struct_size = sizeof(diag);
    assert(sony2fuji_hdr_render(hdrSession, &cSrc, &reqOff.base.base.base.base.base.base.base.base, &cOutOff, &diag) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_hdr_render(hdrSession, &cSrc, &reqHigh.base.base.base.base.base.base.base.base, &cOutHigh, &diag) == SONY2FUJI_STATUS_OK);
    assert(cOutOff.sdr.width == 64 && cOutHigh.sdr.width == 64);
    assert(std::memcmp(cOutOff.sdr.data, cOutHigh.sdr.data, size_t(64) * 64 * 3 * sizeof(float)) != 0);
    sony2fuji_hdr_release_pair(&cOutOff);
    sony2fuji_hdr_release_pair(&cOutHigh);
    sony2fuji_session_destroy(hdrSession);

    // Verify hdr::encodeStream applies output sharpening cleanly and embeds ICC_PROFILE
    auto makeStreamSrc = [&]() {
        sony2fuji::HDRRowSource rowSrc;
        rowSrc.width = srcW;
        rowSrc.height = srcH;
        rowSrc.read = [&](bool hdr, uint32_t row, uint32_t count, sony2fuji::RGB* out) {
            const auto& plane = hdr ? src.hdr : src.sdr;
            std::copy_n(plane.pixels.data() + size_t(row) * srcW, size_t(count) * srcW, out);
        };
        rowSrc.finish = [] {};
        return rowSrc;
    };
    const auto streamTemp = std::filesystem::temp_directory_path() / "rawlab-stream-sharpen";
    std::filesystem::create_directories(streamTemp);
    const auto streamOff = sony2fuji::hdr::encodeStream(
        makeStreamSrc(), makeHdrOpts(sony2fuji::OutputSharpening::Off), true, 95, sony2fuji::kHdrColorSrgb, streamTemp, {});
    const auto streamHigh = sony2fuji::hdr::encodeStream(
        makeStreamSrc(), makeHdrOpts(sony2fuji::OutputSharpening::High), true, 95, sony2fuji::kHdrColorSrgb, streamTemp, {});
    assert(streamOff.width == 64 && streamHigh.width == 64);
    assert(streamOff.jpeg != streamHigh.jpeg);
    (void)extractSingleSrgbIccProfile(streamOff.jpeg);
    (void)extractSingleSrgbIccProfile(streamHigh.jpeg);
    std::error_code ec;
    std::filesystem::remove_all(streamTemp, ec);

    std::cout << "PASS testPostResizeOutputSharpening\n";
}

} // namespace

int main() {
    const auto tempDir = std::filesystem::temp_directory_path() /
        ("rawlab-export-delivery-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(tempDir);
    struct Cleanup {
        std::filesystem::path dir;
        ~Cleanup() {
            std::error_code ec;
            std::filesystem::remove_all(dir, ec);
        }
    } cleanup{tempDir};

    testJpegApp2IccProfile(tempDir);
    testDeterministic8BitDithering(tempDir);
    testPostResizeOutputSharpening();
    return 0;
}
