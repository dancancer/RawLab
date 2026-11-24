#include "test_harness.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "../third_party/nlohmann/json.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {

using rawlab::test::require;

template <class T>
T hdrInit() {
    T v{};
    v.version = 1;
    v.struct_size = sizeof(T);
    return v;
}

struct SessionGuard {
    sony2fuji_session* ptr = nullptr;
    SessionGuard() {
        require(sony2fuji_session_create(&ptr) == SONY2FUJI_STATUS_OK && ptr != nullptr,
            "sony2fuji_session_create failed", __FILE__, __LINE__);
    }
    ~SessionGuard() {
        if (ptr) sony2fuji_session_destroy(ptr);
    }
};

struct BufferGuard {
    sony2fuji_buffer value{};
    ~BufferGuard() { sony2fuji_release_buffer(&value); }
};

struct HdrPairGuard {
    sony2fuji_hdr_image_pair_v1 value = hdrInit<sony2fuji_hdr_image_pair_v1>();
    ~HdrPairGuard() { sony2fuji_hdr_release_pair(&value); }
};

struct TempFileGuard {
    std::filesystem::path path;
    ~TempFileGuard() {
        if (!path.empty()) {
            std::error_code ec;
            std::filesystem::remove(path, ec);
        }
    }
};

uint16_t readChan16(const sony2fuji_buffer& buf, uint32_t x, uint32_t y, uint32_t ch) {
    const auto* p = static_cast<const uint8_t*>(buf.data) +
        static_cast<size_t>(y) * buf.stride_bytes + static_cast<size_t>(x) * 8u + ch * 2u;
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

std::vector<uint8_t> makeGradientRgba8(uint32_t width, uint32_t height) {
    std::vector<uint8_t> px(static_cast<size_t>(width) * height * 4u, 255);
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const size_t idx = (static_cast<size_t>(y) * width + x) * 4u;
            px[idx + 0] = static_cast<uint8_t>(30 + (x * 180) / std::max(1u, width - 1));
            px[idx + 1] = static_cast<uint8_t>(40 + (y * 160) / std::max(1u, height - 1));
            px[idx + 2] = static_cast<uint8_t>(70 + ((x + y) * 110) / std::max(1u, width + height - 2));
            px[idx + 3] = 255;
        }
    }
    return px;
}

sony2fuji_request makeDisplayRequest(const std::vector<uint8_t>& px, uint32_t width, uint32_t height) {
    sony2fuji_request req{};
    req.version = SONY2FUJI_REQUEST_VERSION;
    req.struct_size = sizeof(req);
    req.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    req.input_pixels = px.data();
    req.input_width = width;
    req.input_height = height;
    req.input_pixel_format = SONY2FUJI_PIXEL_RGBA8;
    req.input_color_space = SONY2FUJI_COLOR_SRGB;
    req.wb_mode = SONY2FUJI_WB_CAMERA;
    req.wb_mul[0] = req.wb_mul[1] = req.wb_mul[2] = req.wb_mul[3] = 1.0f;
    req.brightness = 1.0f;
    req.contrast = 1.0f;
    req.saturation = 1.0f;
    req.temperature = 6500.0f;
    req.intent = SONY2FUJI_INTENT_FINAL;
    req.size_mode = SONY2FUJI_SIZE_NATIVE;
    req.output_target = SONY2FUJI_TARGET_BUFFER;
    req.output_format = SONY2FUJI_OUTPUT_RGBA8;
    return req;
}

void testSessionRenderRgba16DisplayBuffer() {
    constexpr uint32_t kW = 16;
    constexpr uint32_t kH = 12;
    const auto inputPx = makeGradientRgba8(kW, kH);

    SessionGuard session;
    sony2fuji_gpu_config gpu{};
    gpu.version = SONY2FUJI_GPU_CONFIG_VERSION;
    gpu.struct_size = sizeof(gpu);
    gpu.mode = SONY2FUJI_GPU_OFF;
    require(sony2fuji_session_set_gpu_config(session.ptr, &gpu) == SONY2FUJI_STATUS_OK,
        "set_gpu_config failed", __FILE__, __LINE__);

    const char* kNeutralRecipe = R"({
        "schema_version": 5,
        "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
        "input": {"path": "memory.png", "type": "raster"},
        "edits": {
            "exposure": {"mode": "sensor", "ev": 0.0, "brightness": 1.0},
            "white_balance": {"mode": "none"},
            "look": {"path": null, "strength": 1.0}
        },
        "output": {"path": "out.png", "format": "png", "size": {"mode": "native"}}
    })";
    require(sony2fuji_apply_params(session.ptr, kNeutralRecipe) == SONY2FUJI_STATUS_OK,
        "apply_params neutral failed", __FILE__, __LINE__);

    sony2fuji_request req = makeDisplayRequest(inputPx, kW, kH);
    BufferGuard neutralOut;
    require(sony2fuji_session_render_rgba16(session.ptr, &req, &neutralOut.value) == SONY2FUJI_STATUS_OK,
        "render_rgba16 neutral buffer failed", __FILE__, __LINE__);
    require(neutralOut.value.data != nullptr, "RGBA16 data is null", __FILE__, __LINE__);
    require(neutralOut.value.width == kW && neutralOut.value.height == kH,
        "RGBA16 dimensions mismatch", __FILE__, __LINE__);
    require(neutralOut.value.stride_bytes == kW * 8u,
        "RGBA16 stride mismatch", __FILE__, __LINE__);
    require(neutralOut.value.size_bytes == static_cast<size_t>(kH) * neutralOut.value.stride_bytes,
        "RGBA16 size_bytes mismatch", __FILE__, __LINE__);
    require(neutralOut.value.pixel_format == SONY2FUJI_PIXEL_RGBA16,
        "RGBA16 pixel_format mismatch", __FILE__, __LINE__);

    uint32_t geoW = 0, geoH = 0;
    require(sony2fuji_session_get_geometry_size(session.ptr, &geoW, &geoH) == SONY2FUJI_STATUS_OK,
        "geometry size unavailable after render_rgba16", __FILE__, __LINE__);
    require(geoW == kW && geoH == kH, "geometry size mismatch", __FILE__, __LINE__);

    for (uint32_t y = 0; y < kH; ++y) {
        for (uint32_t x = 0; x < kW; ++x) {
            require(readChan16(neutralOut.value, x, y, 3) == 65535u,
                "RGBA16 alpha must be opaque 65535", __FILE__, __LINE__);
        }
    }

    sony2fuji_bsh_diagnosis diag{};
    diag.version = SONY2FUJI_BSH_DIAGNOSIS_VERSION;
    diag.struct_size = sizeof(diag);
    require(sony2fuji_diagnose_image(&neutralOut.value, nullptr, &diag) == SONY2FUJI_STATUS_OK,
        "diagnose_image on render_rgba16 output failed", __FILE__, __LINE__);
    require(diag.bit_depth == 16 && diag.channels == 4,
        "diagnose_image bit_depth/channels mismatch", __FILE__, __LINE__);

    // Apply +1.0 EV and verify RGBA16 output actually brightens.
    req.exposure_ev = 1.0f;
    BufferGuard brightOut;
    require(sony2fuji_session_render_rgba16(session.ptr, &req, &brightOut.value) == SONY2FUJI_STATUS_OK,
        "render_rgba16 +1 EV failed", __FILE__, __LINE__);
    require(readChan16(brightOut.value, 0, 0, 0) > readChan16(neutralOut.value, 0, 0, 0),
        "Exposure +1 EV must increase RGBA16 pixel values", __FILE__, __LINE__);
}

std::string buildRawRecipeJson(const std::string& inputPath, const std::string& outputPath) {
    const nlohmann::json recipe = {
        {"schema_version", 5},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"input", {{"path", inputPath}, {"type", "raw"}}},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.25}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}},
            {"look", {{"path", nullptr}, {"strength", 1.0}}},
        }},
        {"output", {
            {"path", outputPath},
            {"format", "png"},
            {"size", {{"mode", "limit_long_edge"}, {"long_edge", 32}}},
        }},
    };
    return recipe.dump();
}

void testSessionRenderRgba16FileAndBufferParity() {
    const std::string winInputSample = R"(D:\a\RawLab\RawLab\lutools\tests\fixtures\bayer-demosaic.dng)";
    const std::string winOutputSample = R"(C:\Temp\rawlab\AppData\Local\Temp\rawlab_rgba16_api_test.png)";
    const auto parsedWin = nlohmann::json::parse(buildRawRecipeJson(winInputSample, winOutputSample));
    require(parsedWin.at("input").at("path").get<std::string>() == winInputSample,
        "Windows backslash input path must round-trip through JSON", __FILE__, __LINE__);
    require(parsedWin.at("output").at("path").get<std::string>() == winOutputSample,
        "Windows backslash output path must round-trip through JSON", __FILE__, __LINE__);

    const std::filesystem::path dngPath = std::filesystem::path(TEST_FIXTURE_DIR) / "bayer-demosaic.dng";
    require(std::filesystem::is_regular_file(dngPath), "Missing bayer-demosaic.dng fixture", __FILE__, __LINE__);
    const std::string dngUtf8 = dngPath.u8string();

    TempFileGuard tempPng;
    tempPng.path = std::filesystem::temp_directory_path() / "rawlab_rgba16_api_test.png";
    std::error_code ec;
    std::filesystem::remove(tempPng.path, ec);
    const std::string pngUtf8 = tempPng.path.u8string();

    SessionGuard session;
    const std::string recipeJson = buildRawRecipeJson(dngUtf8, pngUtf8);
    require(sony2fuji_apply_params(session.ptr, recipeJson.c_str()) == SONY2FUJI_STATUS_OK,
        "apply_params RAW failed", __FILE__, __LINE__);

    sony2fuji_request fileReq{};
    fileReq.version = SONY2FUJI_REQUEST_VERSION;
    fileReq.struct_size = sizeof(fileReq);
    fileReq.input_type = SONY2FUJI_INPUT_RAW;
    fileReq.input_path = dngUtf8.c_str();
    fileReq.wb_mode = SONY2FUJI_WB_CAMERA;
    fileReq.exposure_ev = 0.25f;
    fileReq.brightness = 1.0f;
    fileReq.contrast = 1.0f;
    fileReq.saturation = 1.0f;
    fileReq.temperature = 6500.0f;
    fileReq.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE;
    fileReq.long_edge = 32;
    fileReq.intent = SONY2FUJI_INTENT_FINAL;
    fileReq.output_target = SONY2FUJI_TARGET_FILE;
    fileReq.output_path = pngUtf8.c_str();
    fileReq.output_format = SONY2FUJI_OUTPUT_PNG;

    BufferGuard fileRgba16;
    require(sony2fuji_session_render_rgba16(session.ptr, &fileReq, &fileRgba16.value) == SONY2FUJI_STATUS_OK,
        "render_rgba16 TARGET_FILE failed", __FILE__, __LINE__);
    require(std::filesystem::is_regular_file(tempPng.path),
        "TARGET_FILE did not write PNG file", __FILE__, __LINE__);

    std::ifstream pngFile(tempPng.path, std::ios::binary);
    char sig[8]{};
    pngFile.read(sig, sizeof(sig));
    require(pngFile.gcount() == 8 && std::memcmp(sig, "\x89PNG\r\n\x1a\n", 8) == 0,
        "Written output is not a valid PNG", __FILE__, __LINE__);

    // Same render targeting BUFFER must yield byte-identical RGBA16.
    sony2fuji_request bufReq = fileReq;
    bufReq.output_target = SONY2FUJI_TARGET_BUFFER;
    bufReq.output_format = SONY2FUJI_OUTPUT_RGBA8;
    bufReq.output_path = nullptr;

    BufferGuard bufRgba16;
    require(sony2fuji_session_render_rgba16(session.ptr, &bufReq, &bufRgba16.value) == SONY2FUJI_STATUS_OK,
        "render_rgba16 TARGET_BUFFER RAW failed", __FILE__, __LINE__);
    require(bufRgba16.value.width == fileRgba16.value.width &&
            bufRgba16.value.height == fileRgba16.value.height &&
            bufRgba16.value.size_bytes == fileRgba16.value.size_bytes,
        "TARGET_FILE vs TARGET_BUFFER dimensions mismatch", __FILE__, __LINE__);
    require(std::memcmp(bufRgba16.value.data, fileRgba16.value.data, bufRgba16.value.size_bytes) == 0,
        "TARGET_FILE vs TARGET_BUFFER RGBA16 bytes differ", __FILE__, __LINE__);
}

void testSessionRenderRgba16ValidationAndErrors() {
    SessionGuard session;
    const auto px = makeGradientRgba8(8, 8);
    auto req = makeDisplayRequest(px, 8, 8);
    BufferGuard out;

    require(sony2fuji_session_render_rgba16(nullptr, &req, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "null session rejected", __FILE__, __LINE__);
    require(sony2fuji_session_render_rgba16(session.ptr, nullptr, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "null request rejected", __FILE__, __LINE__);
    require(sony2fuji_session_render_rgba16(session.ptr, &req, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "null out_rgba16 rejected", __FILE__, __LINE__);

    auto badVer = req;
    badVer.version = 999;
    require(sony2fuji_session_render_rgba16(session.ptr, &badVer, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "bad request version rejected", __FILE__, __LINE__);

    auto badSize = req;
    badSize.struct_size = sizeof(sony2fuji_request) - 4;
    require(sony2fuji_session_render_rgba16(session.ptr, &badSize, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "truncated request struct_size rejected", __FILE__, __LINE__);

    // Aliasing request and out_rgba16 must fail without corrupting request.
    struct AliasedStorage {
        union {
            sony2fuji_request req;
            sony2fuji_buffer buf;
        };
    } aliased{};
    aliased.req = req;
    require(sony2fuji_session_render_rgba16(session.ptr, &aliased.req, &aliased.buf) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "aliasing request and out_rgba16 rejected", __FILE__, __LINE__);
    require(aliased.req.version == SONY2FUJI_REQUEST_VERSION,
        "aliasing check must not zero request before rejecting", __FILE__, __LINE__);

    // Unsupported buffer output format.
    auto badFmt = req;
    badFmt.intent = SONY2FUJI_INTENT_PREVIEW;
    badFmt.preview_long_edge = 8;
    badFmt.output_format = SONY2FUJI_OUTPUT_DNG;
    require(sony2fuji_session_render_rgba16(session.ptr, &badFmt, &out.value) == SONY2FUJI_STATUS_UNSUPPORTED,
        "TARGET_BUFFER with OUTPUT_DNG rejected", __FILE__, __LINE__);
    require(out.value.data == nullptr, "failed render_rgba16 left non-null data", __FILE__, __LINE__);

    // Missing RAW file returns IO error and keeps out empty.
    sony2fuji_request missingRaw{};
    missingRaw.version = SONY2FUJI_REQUEST_VERSION;
    missingRaw.struct_size = sizeof(missingRaw);
    missingRaw.input_type = SONY2FUJI_INPUT_RAW;
    missingRaw.input_path = "/nonexistent/rawlab/missing_rgba16.dng";
    missingRaw.wb_mode = SONY2FUJI_WB_CAMERA;
    missingRaw.brightness = 1.0f;
    missingRaw.contrast = 1.0f;
    missingRaw.saturation = 1.0f;
    missingRaw.temperature = 6500.0f;
    missingRaw.intent = SONY2FUJI_INTENT_FINAL;
    missingRaw.size_mode = SONY2FUJI_SIZE_NATIVE;
    missingRaw.output_target = SONY2FUJI_TARGET_BUFFER;
    missingRaw.output_format = SONY2FUJI_OUTPUT_RGBA8;
    require(sony2fuji_session_render_rgba16(session.ptr, &missingRaw, &out.value) == SONY2FUJI_STATUS_IO_ERROR,
        "missing RAW path returns IO_ERROR", __FILE__, __LINE__);
    require(out.value.data == nullptr, "missing RAW left non-null data", __FILE__, __LINE__);
}

void testHdrEncodeRgba16StridedAndNonfinite() {
    constexpr uint32_t kW = 4;
    constexpr uint32_t kH = 2;
    constexpr uint64_t kStride = static_cast<uint64_t>(kW) * 12u + 16u; // 64 bytes/row with 16-byte poison pad

    std::vector<uint8_t> storage(static_cast<size_t>(kH) * kStride, 0xFF);
    const float qnan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();

    auto writePixel = [&](uint32_t x, uint32_t y, float r, float g, float b) {
        const float rgb[3] = {r, g, b};
        std::memcpy(storage.data() + static_cast<size_t>(y) * kStride + static_cast<size_t>(x) * 12u, rgb, 12u);
    };
    writePixel(0, 0, 0.0f, 0.5f, 1.0f);
    writePixel(1, 0, -0.25f, 1.5f, qnan);
    writePixel(2, 0, inf, -inf, 0.18f);
    writePixel(3, 0, 0.0031308f, 0.214f, 0.999f);
    writePixel(0, 1, 0.25f, 0.5f, 0.75f);
    writePixel(1, 1, 0.0f, 0.0f, 0.0f);
    writePixel(2, 1, 1.0f, 1.0f, 1.0f);
    writePixel(3, 1, 0.1f, 0.2f, 0.3f);

    auto src = hdrInit<sony2fuji_hdr_buffer_v1>();
    src.data = storage.data();
    src.size_bytes = storage.size();
    src.width = kW;
    src.height = kH;
    src.stride_bytes = kStride;
    src.pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
    src.color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;

    BufferGuard out;
    require(sony2fuji_hdr_encode_rgba16(&src, &out.value) == SONY2FUJI_STATUS_OK,
        "hdr_encode_rgba16 strided failed", __FILE__, __LINE__);
    require(out.value.data != nullptr, "hdr_encode_rgba16 output data null", __FILE__, __LINE__);
    require(out.value.width == kW && out.value.height == kH,
        "hdr_encode_rgba16 dimensions mismatch", __FILE__, __LINE__);
    require(out.value.stride_bytes == kW * 8u,
        "hdr_encode_rgba16 output stride mismatch", __FILE__, __LINE__);
    require(out.value.size_bytes == static_cast<size_t>(kH) * out.value.stride_bytes,
        "hdr_encode_rgba16 output size mismatch", __FILE__, __LINE__);
    require(out.value.pixel_format == SONY2FUJI_PIXEL_RGBA16,
        "hdr_encode_rgba16 output format mismatch", __FILE__, __LINE__);

    // Row 0 checks: linear -> sRGB transfer
    require(readChan16(out.value, 0, 0, 0) == 0u, "0.0f -> 0", __FILE__, __LINE__);
    require(readChan16(out.value, 0, 0, 1) > 48000u && readChan16(out.value, 0, 0, 1) < 48400u,
        "0.5f linear -> ~48192 sRGB", __FILE__, __LINE__);
    require(readChan16(out.value, 0, 0, 2) == 65535u, "1.0f -> 65535", __FILE__, __LINE__);
    require(readChan16(out.value, 0, 0, 3) == 65535u, "alpha -> 65535", __FILE__, __LINE__);

    require(readChan16(out.value, 1, 0, 0) == 0u, "-0.25f -> 0", __FILE__, __LINE__);
    require(readChan16(out.value, 1, 0, 1) == 65535u, "1.5f -> 65535", __FILE__, __LINE__);
    require(readChan16(out.value, 1, 0, 2) == 0u, "qnan -> 0", __FILE__, __LINE__);

    require(readChan16(out.value, 2, 0, 0) == 65535u, "+inf -> 65535", __FILE__, __LINE__);
    require(readChan16(out.value, 2, 0, 1) == 0u, "-inf -> 0", __FILE__, __LINE__);

    // Row 1 checks: stride offset respected (not confused by 16-byte poison padding on row 0)
    require(readChan16(out.value, 0, 1, 1) == readChan16(out.value, 0, 0, 1),
        "strided row 1 pixel(0,1).g must match row 0 pixel(0,0).g", __FILE__, __LINE__);
    require(readChan16(out.value, 1, 1, 0) == 0u &&
            readChan16(out.value, 1, 1, 1) == 0u &&
            readChan16(out.value, 1, 1, 2) == 0u,
        "row 1 black pixel must stay 0", __FILE__, __LINE__);
    require(readChan16(out.value, 2, 1, 0) == 65535u &&
            readChan16(out.value, 2, 1, 1) == 65535u &&
            readChan16(out.value, 2, 1, 2) == 65535u,
        "row 1 white pixel must stay 65535", __FILE__, __LINE__);

    sony2fuji_bsh_diagnosis diag{};
    diag.version = SONY2FUJI_BSH_DIAGNOSIS_VERSION;
    diag.struct_size = sizeof(diag);
    require(sony2fuji_diagnose_image(&out.value, nullptr, &diag) == SONY2FUJI_STATUS_OK,
        "diagnose_image on hdr_encode_rgba16 output failed", __FILE__, __LINE__);
}

void testHdrEncodeRgba16WithHdrRender() {
    constexpr uint32_t kW = 16;
    constexpr uint32_t kH = 16;
    std::vector<float> hdrPixels(static_cast<size_t>(kW) * kH * 3u, 0.5f);
    std::vector<float> sdrPixels(static_cast<size_t>(kW) * kH * 3u, 0.18f);

    HdrPairGuard src;
    for (auto* b : {&src.value.hdr, &src.value.sdr}) {
        *b = hdrInit<sony2fuji_hdr_buffer_v1>();
        b->width = kW;
        b->height = kH;
        b->stride_bytes = kW * 12u;
        b->size_bytes = static_cast<uint64_t>(kW) * kH * 12u;
        b->pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
        b->color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
    }
    src.value.hdr.data = hdrPixels.data();
    src.value.sdr.data = sdrPixels.data();
    src.value.native_width = kW;
    src.value.native_height = kH;
    src.value.orientation_applied = 1;
    src.value.source_intent = src.value.render_intent = SONY2FUJI_INTENT_FINAL;
    src.value.source_headroom = 4.0f;
    src.value.source_headroom_kind = SONY2FUJI_HDR_HEADROOM_DECLARED;

    SessionGuard session;
    auto req = hdrInit<sony2fuji_hdr_request_v1>();
    req.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_VERSION;
    req.intent = SONY2FUJI_INTENT_FINAL;
    req.temperature = 6500.0f;
    req.crop_width = req.crop_height = 1.0f;

    HdrPairGuard edited;
    auto diag = hdrInit<sony2fuji_hdr_diagnostic_v1>();
    require(sony2fuji_hdr_render(session.ptr, &src.value, &req, &edited.value, &diag) == SONY2FUJI_STATUS_OK,
        "hdr_render failed", __FILE__, __LINE__);

    BufferGuard rgba16;
    require(sony2fuji_hdr_encode_rgba16(&edited.value.sdr, &rgba16.value) == SONY2FUJI_STATUS_OK,
        "hdr_encode_rgba16 on rendered SDR failed", __FILE__, __LINE__);
    require(rgba16.value.width == kW && rgba16.value.height == kH,
        "rendered SDR RGBA16 dimensions mismatch", __FILE__, __LINE__);

    sony2fuji_bsh_diagnosis bshDiag{};
    bshDiag.version = SONY2FUJI_BSH_DIAGNOSIS_VERSION;
    bshDiag.struct_size = sizeof(bshDiag);
    require(sony2fuji_diagnose_image(&rgba16.value, nullptr, &bshDiag) == SONY2FUJI_STATUS_OK,
        "diagnose_image on HDR-encoded SDR RGBA16 failed", __FILE__, __LINE__);
    // 0.18 linear -> ~0.461 sRGB midtone
    require(bshDiag.mean_luma_0_1 > 0.40f && bshDiag.mean_luma_0_1 < 0.55f,
        "expected ~0.46 sRGB mid-gray luma from 0.18 linear", __FILE__, __LINE__);
}

void testHdrEncodeRgba16ValidationAndErrors() {
    std::vector<float> px(4 * 2 * 3, 0.25f);
    auto valid = hdrInit<sony2fuji_hdr_buffer_v1>();
    valid.data = px.data();
    valid.width = 4;
    valid.height = 2;
    valid.stride_bytes = 4 * 12u;
    valid.size_bytes = px.size() * sizeof(float);
    valid.pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
    valid.color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;

    BufferGuard out;
    require(sony2fuji_hdr_encode_rgba16(nullptr, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "null source rejected", __FILE__, __LINE__);
    require(sony2fuji_hdr_encode_rgba16(&valid, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "null out_rgba16 rejected", __FILE__, __LINE__);

    auto badVer = valid;
    badVer.version = 2;
    require(sony2fuji_hdr_encode_rgba16(&badVer, &out.value) == SONY2FUJI_STATUS_UNSUPPORTED,
        "unsupported version rejected", __FILE__, __LINE__);

    auto badSize = valid;
    badSize.struct_size -= 4;
    require(sony2fuji_hdr_encode_rgba16(&badSize, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "truncated struct_size rejected", __FILE__, __LINE__);

    auto badData = valid;
    badData.data = nullptr;
    require(sony2fuji_hdr_encode_rgba16(&badData, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "null data rejected", __FILE__, __LINE__);

    auto zeroDim = valid;
    zeroDim.width = 0;
    require(sony2fuji_hdr_encode_rgba16(&zeroDim, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "zero width rejected", __FILE__, __LINE__);

    auto badFmt = valid;
    badFmt.pixel_format = SONY2FUJI_HDR_RGB8_SRGB;
    require(sony2fuji_hdr_encode_rgba16(&badFmt, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "non-RGB32F pixel_format rejected", __FILE__, __LINE__);

    auto badEnc = valid;
    badEnc.color_encoding = SONY2FUJI_HDR_DISPLAY_SRGB;
    require(sony2fuji_hdr_encode_rgba16(&badEnc, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "non-linear color_encoding rejected", __FILE__, __LINE__);

    auto badStride = valid;
    badStride.stride_bytes = 4 * 12u - 4u;
    require(sony2fuji_hdr_encode_rgba16(&badStride, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "short stride rejected", __FILE__, __LINE__);

    auto badBytes = valid;
    badBytes.size_bytes -= 4u;
    require(sony2fuji_hdr_encode_rgba16(&badBytes, &out.value) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "truncated size_bytes rejected", __FILE__, __LINE__);

    struct AliasedHdr {
        union {
            sony2fuji_hdr_buffer_v1 src;
            sony2fuji_buffer out;
        };
    } aliased{};
    aliased.src = valid;
    require(sony2fuji_hdr_encode_rgba16(&aliased.src, &aliased.out) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "aliasing source and out_rgba16 rejected", __FILE__, __LINE__);
    require(aliased.src.version == 1, "aliasing check must not clobber source", __FILE__, __LINE__);

    // Also test source->data aliasing out_rgba16.
    std::vector<uint8_t> dataAlias(std::max<size_t>(sizeof(sony2fuji_buffer), valid.size_bytes), 0);
    auto* aliasOut = reinterpret_cast<sony2fuji_buffer*>(dataAlias.data());
    auto dataAliasSrc = valid;
    dataAliasSrc.data = dataAlias.data();
    dataAliasSrc.size_bytes = dataAlias.size();
    require(sony2fuji_hdr_encode_rgba16(&dataAliasSrc, aliasOut) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "aliasing source->data and out_rgba16 rejected", __FILE__, __LINE__);
}

} // namespace

TEST_MAIN(
    testSessionRenderRgba16DisplayBuffer();
    testSessionRenderRgba16FileAndBufferParity();
    testSessionRenderRgba16ValidationAndErrors();
    testHdrEncodeRgba16StridedAndNonfinite();
    testHdrEncodeRgba16WithHdrRender();
    testHdrEncodeRgba16ValidationAndErrors();
    std::cout << "rgba16_api_tests passed (" << ::rawlab::test::checkCount() << " checks)\n";
)
