#include "sony2fuji/ffi/sony2fuji_c.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

using SessionPtr = std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>;

SessionPtr createSession(sony2fuji_gpu_mode gpuMode = SONY2FUJI_GPU_OFF) {
    sony2fuji_session* raw = nullptr;
    require(sony2fuji_session_create(&raw) == SONY2FUJI_STATUS_OK && raw != nullptr,
            "sony2fuji_session_create failed");
    sony2fuji_gpu_config gpu{};
    gpu.version = SONY2FUJI_GPU_CONFIG_VERSION;
    gpu.struct_size = sizeof(gpu);
    gpu.mode = gpuMode;
    require(sony2fuji_session_set_gpu_config(raw, &gpu) == SONY2FUJI_STATUS_OK,
            "sony2fuji_session_set_gpu_config failed");
    return SessionPtr(raw, sony2fuji_session_destroy);
}

struct TempDir {
    fs::path path;
    TempDir()
        : path(fs::temp_directory_path() /
               ("rawlab-recipe-wb-test-" +
                std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()))) {
        require(fs::create_directories(path), "create temp dir");
    }
    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

void writeBytes(const fs::path& file, const std::vector<uint8_t>& bytes) {
    std::ofstream out(file, std::ios::binary | std::ios::trunc);
    require(static_cast<bool>(out), "open temp file for write");
    out.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    require(static_cast<bool>(out), "write temp file");
}

void putValue(std::vector<uint8_t>& bytes, size_t offset, uint32_t value, size_t width, bool littleEndian) {
    for (size_t i = 0; i < width; ++i) {
        bytes[offset + i] = static_cast<uint8_t>(value >> (8 * (littleEndian ? i : width - 1 - i)));
    }
}

std::vector<uint8_t> makeMinimalJpeg(uint16_t width = 5184, uint16_t height = 3888) {
    std::vector<uint8_t> bytes{
        0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, 0, 0, 0, 0, 3, 1, 0x21, 0, 2, 0x11, 1, 3, 0x11, 1,
        0xff, 0xda, 0, 12, 3, 1, 0, 2, 0x11, 3, 0x11, 0, 63, 0,
        1, 2, 0xff, 0, 3, 0xff, 0xd0, 4, 0xff, 0xd9
    };
    putValue(bytes, 7, height, 2, false);
    putValue(bytes, 9, width, 2, false);
    return bytes;
}

std::vector<uint8_t> makeMinimalMpfJpeg() {
    std::vector<uint8_t> bytes(2 + 4 + 54 + 2 * 16, 0);
    bytes[0] = 0xff;
    bytes[1] = 0xd8;
    bytes[2] = 0xff;
    bytes[3] = 0xe2;
    putValue(bytes, 4, static_cast<uint32_t>(bytes.size() - 4), 2, false);
    bytes[6] = 'M';
    bytes[7] = 'P';
    bytes[8] = 'F';
    bytes[10] = 'I';
    bytes[11] = 'I';
    auto word = [&](size_t p, uint16_t v) { putValue(bytes, p, v, 2, true); };
    auto number = [&](size_t p, uint32_t v) { putValue(bytes, p, v, 4, true); };
    word(12, 42);
    number(14, 8);
    word(18, 3);
    word(20, 0xb000);
    word(22, 7);
    number(24, 4);
    bytes[28] = '0';
    bytes[29] = '1';
    bytes[30] = '0';
    bytes[31] = '0';
    word(32, 0xb001);
    word(34, 4);
    number(36, 1);
    number(40, 2);
    word(44, 0xb002);
    word(46, 7);
    number(48, 32);
    number(52, 50);

    const auto primary = makeMinimalJpeg();
    const auto thumbnail = makeMinimalJpeg(480, 360);
    bytes.insert(bytes.end(), primary.begin() + 2, primary.end());
    const size_t primaryEnd = bytes.size();
    number(60, 0xa0030000);
    number(64, static_cast<uint32_t>(primaryEnd));
    word(72, 2);
    bytes.insert(bytes.end(), 17, 0x31);
    number(76, 0x40000000u | 0x010002u);
    number(80, static_cast<uint32_t>(thumbnail.size()));
    number(84, static_cast<uint32_t>(bytes.size() - 10));
    bytes.insert(bytes.end(), thumbnail.begin(), thumbnail.end());
    return bytes;
}

sony2fuji_recipe_wb_request makeRecipeWbRequest(const char* inputPath) {
    sony2fuji_recipe_wb_request req{};
    req.version = SONY2FUJI_RECIPE_WB_REQUEST_VERSION;
    req.struct_size = sizeof(req);
    req.input_path = inputPath;
    req.processing_version = SONY2FUJI_PROCESSING_BASIC_V3;
    req.x3f_mode = SONY2FUJI_X3F_LEGACY;
    req.exposure_mode = SONY2FUJI_EXPOSURE_PREVIEW;
    req.recipe_active = 1;
    req.recipe_strength = 1.0f;
    req.custom_wb = 0;
    req.temperature = 6500.0f;
    req.tint = 0.0f;
    return req;
}

int32_t cancelImmediately(void*) {
    return 1;
}

void testInspectSdrJpegMpf(const TempDir& dir) {
    require(sony2fuji_inspect_sdr_jpeg_mpf(nullptr) == -1, "null path returns -1");
    require(sony2fuji_inspect_sdr_jpeg_mpf("") == -1, "empty path returns -1");
    require(sony2fuji_inspect_sdr_jpeg_mpf((dir.path / "missing.jpg").string().c_str()) == 0,
            "missing/non-jpeg path returns 0");

    const fs::path plainJpeg = dir.path / "plain.jpg";
    writeBytes(plainJpeg, makeMinimalJpeg());
    require(sony2fuji_inspect_sdr_jpeg_mpf(plainJpeg.string().c_str()) == 0,
            "single jpeg returns 0");

    const fs::path mpfJpeg = dir.path / "mpf.jpg";
    writeBytes(mpfJpeg, makeMinimalMpfJpeg());
    require(sony2fuji_inspect_sdr_jpeg_mpf(mpfJpeg.string().c_str()) == 2,
            "mpf jpeg returns 2 images");
}

void testIsNormalX3f(const TempDir& dir, const fs::path& dngPath) {
    require(sony2fuji_is_normal_x3f(nullptr, SONY2FUJI_X3F_NORMAL) == 0, "null path is not normal x3f");
    require(sony2fuji_is_normal_x3f("", SONY2FUJI_X3F_NORMAL) == 0, "empty path is not normal x3f");

    const fs::path x3fMagic = dir.path / "sample.x3f";
    writeBytes(x3fMagic, {'F', 'O', 'V', 'b', 0, 0, 0, 0});
    require(sony2fuji_is_normal_x3f(x3fMagic.string().c_str(), SONY2FUJI_X3F_NORMAL) == 1,
            "FOVb magic with NORMAL mode is normal x3f");
    require(sony2fuji_is_normal_x3f(x3fMagic.string().c_str(), SONY2FUJI_X3F_LEGACY) == 0,
            "FOVb magic with LEGACY mode is not normal x3f");

    const fs::path disguisedDng = dir.path / "disguised.x3f";
    fs::copy_file(dngPath, disguisedDng, fs::copy_options::overwrite_existing);
    require(sony2fuji_is_normal_x3f(disguisedDng.string().c_str(), SONY2FUJI_X3F_NORMAL) == 0,
            "DNG renamed .x3f must NOT be detected as normal x3f");
}

void testEffectiveRawWhiteBalance(const fs::path& dngPath) {
    auto session = createSession();
    float temp = 0.0f;
    float tint = 0.0f;
    require(sony2fuji_session_get_effective_raw_white_balance(session.get(), &temp, &tint) ==
                SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "unrendered session returns INVALID_ARGUMENT");

    // Display buffer render must yield UNSUPPORTED for effective RAW WB.
    std::vector<uint8_t> rgbPixels(4 * 4 * 3, 128);
    sony2fuji_request bufReq{};
    bufReq.version = SONY2FUJI_REQUEST_VERSION;
    bufReq.struct_size = sizeof(bufReq);
    bufReq.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    bufReq.input_pixels = rgbPixels.data();
    bufReq.input_width = 4;
    bufReq.input_height = 4;
    bufReq.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    bufReq.input_color_space = SONY2FUJI_COLOR_SRGB;
    bufReq.wb_mode = SONY2FUJI_WB_CAMERA;
    bufReq.temperature = 6500.0f;
    std::fill(std::begin(bufReq.wb_mul), std::end(bufReq.wb_mul), 1.0f);
    bufReq.brightness = bufReq.contrast = bufReq.saturation = 1.0f;
    bufReq.output_target = SONY2FUJI_TARGET_BUFFER;
    bufReq.output_format = SONY2FUJI_OUTPUT_RGB8;
    bufReq.size_mode = SONY2FUJI_SIZE_NATIVE;
    bufReq.intent = SONY2FUJI_INTENT_PREVIEW;

    sony2fuji_buffer out{};
    require(sony2fuji_process(session.get(), &bufReq, &out) == SONY2FUJI_STATUS_OK,
            "display buffer render failed");
    sony2fuji_release_buffer(&out);
    require(sony2fuji_session_get_effective_raw_white_balance(session.get(), &temp, &tint) ==
                SONY2FUJI_STATUS_UNSUPPORTED,
            "display buffer render yields UNSUPPORTED");

    // Calibrated RAW render returns rounded as-shot WB matching get_raw_white_balance.
    const std::string dngStr = dngPath.string();
    sony2fuji_request rawReq{};
    rawReq.version = SONY2FUJI_REQUEST_VERSION;
    rawReq.struct_size = sizeof(rawReq);
    rawReq.input_type = SONY2FUJI_INPUT_RAW;
    rawReq.input_path = dngStr.c_str();
    rawReq.wb_mode = SONY2FUJI_WB_CAMERA;
    rawReq.temperature = 6500.0f;
    std::fill(std::begin(rawReq.wb_mul), std::end(rawReq.wb_mul), 1.0f);
    rawReq.brightness = rawReq.contrast = rawReq.saturation = 1.0f;
    rawReq.output_target = SONY2FUJI_TARGET_BUFFER;
    rawReq.output_format = SONY2FUJI_OUTPUT_RGB8;
    rawReq.size_mode = SONY2FUJI_SIZE_NATIVE;
    rawReq.intent = SONY2FUJI_INTENT_PREVIEW;
    rawReq.preview_long_edge = 64;

    require(sony2fuji_session_set_processing_version(session.get(), SONY2FUJI_PROCESSING_BASIC_V3) == SONY2FUJI_STATUS_OK,
            "set processing v3");
    require(sony2fuji_process(session.get(), &rawReq, &out) == SONY2FUJI_STATUS_OK,
            "raw render failed");
    sony2fuji_release_buffer(&out);

    float rawTemp = 0.0f;
    float rawTint = 0.0f;
    require(sony2fuji_session_get_raw_white_balance(session.get(), &rawTemp, &rawTint) == SONY2FUJI_STATUS_OK,
            "get_raw_white_balance failed");
    require(sony2fuji_session_get_effective_raw_white_balance(session.get(), &temp, &tint) == SONY2FUJI_STATUS_OK,
            "get_effective_raw_white_balance failed after raw render");
    require(temp == std::round(rawTemp) && tint == std::round(rawTint),
            "effective WB must match half-away-from-zero rounded raw WB");

    // Subsequent display buffer render must NOT leak previous RAW WB.
    require(sony2fuji_process(session.get(), &bufReq, &out) == SONY2FUJI_STATUS_OK,
            "second display buffer render failed");
    sony2fuji_release_buffer(&out);
    require(sony2fuji_session_get_effective_raw_white_balance(session.get(), &temp, &tint) ==
                SONY2FUJI_STATUS_UNSUPPORTED,
            "display render after RAW must return UNSUPPORTED");
}

void testResolveRecipeWb(const TempDir& dir, const fs::path& dngPath) {
    auto session = createSession(SONY2FUJI_GPU_AUTO);

    // Invalid argument checks
    sony2fuji_recipe_wb_result res{};
    auto badReq = makeRecipeWbRequest("");
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &badReq, &res) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "empty path returns INVALID_ARGUMENT");
    badReq = makeRecipeWbRequest(dngPath.string().c_str());
    badReq.version = 999;
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &badReq, &res) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "bad version returns INVALID_ARGUMENT");
    badReq = makeRecipeWbRequest(dngPath.string().c_str());
    badReq.tint = NAN;
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &badReq, &res) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "NaN tint returns INVALID_ARGUMENT");

    // 1. Recipe inactive -> 0 decodes, preserves camera WB
    auto req = makeRecipeWbRequest(dngPath.string().c_str());
    req.recipe_active = 0;
    req.tint = 25.0f;
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &res) == SONY2FUJI_STATUS_OK,
            "inactive recipe returns OK");
    require(res.wb_mode == SONY2FUJI_WB_CAMERA && res.camera_calibrated == 0 && res.tint == 25.0f,
            "inactive recipe skips probe");
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 0,
            "inactive recipe must perform 0 decodes");

    // 2. Zero effective recipe tint + camera WB -> 0 decodes
    req.recipe_active = 1;
    req.custom_wb = 0;
    req.tint = 20.0f;
    req.recipe_strength = 0.0f;
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &res) == SONY2FUJI_STATUS_OK,
            "zero effective tint returns OK");
    require(res.wb_mode == SONY2FUJI_WB_CAMERA && res.camera_calibrated == 0,
            "zero effective tint skips probe");
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 0,
            "zero effective tint must perform 0 decodes");

    // 3. Normal X3F (FOVb header + NORMAL mode) -> 6500/0 with 0 decodes
    const fs::path x3fMagic = dir.path / "normal.x3f";
    writeBytes(x3fMagic, {'F', 'O', 'V', 'b', 0, 0, 0, 0});
    const std::string x3fMagicStr = x3fMagic.string();
    req = makeRecipeWbRequest(x3fMagicStr.c_str());
    req.x3f_mode = SONY2FUJI_X3F_NORMAL;
    req.tint = 20.0f;
    req.recipe_strength = 0.5f;
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &res) == SONY2FUJI_STATUS_OK,
            "normal x3f recipe wb returns OK");
    require(res.camera_calibrated == 1 && res.camera_temperature == 6500.0f && res.camera_tint == 0.0f &&
                res.wb_mode == SONY2FUJI_WB_TEMPERATURE && res.temperature == 6500.0f && res.tint == 10.0f,
            "normal x3f resolves to 6500 + relative recipe tint");
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 0,
            "normal x3f must not trigger LibRaw decode");

    // 4. Calibrated DNG probe + caching + stage preservation
    const fs::path tempDng = dir.path / "probe.DNG";
    fs::copy_file(dngPath, tempDng, fs::copy_options::overwrite_existing);
    const std::string tempDngPathStr = tempDng.string();

    // Configure non-default session state BEFORE probing to confirm ProbeGuard restores it.
    require(sony2fuji_session_set_processing_version(session.get(), SONY2FUJI_PROCESSING_LEGACY) == SONY2FUJI_STATUS_OK,
            "set legacy processing");
    require(sony2fuji_session_set_interactive_preview(session.get(), 1) == SONY2FUJI_STATUS_OK,
            "set interactive preview");

    req = makeRecipeWbRequest(tempDngPathStr.c_str());
    req.processing_version = SONY2FUJI_PROCESSING_BASIC_V3;
    req.exposure_mode = SONY2FUJI_EXPOSURE_PREVIEW;
    req.tint = 16.0f;
    req.recipe_strength = 0.5f;
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &res) == SONY2FUJI_STATUS_OK,
            "DNG probe failed");
    require(res.camera_calibrated == 1 && std::isfinite(res.camera_temperature) && std::isfinite(res.camera_tint),
            "DNG probe produced calibrated WB");
    require(res.wb_mode == SONY2FUJI_WB_TEMPERATURE && res.temperature == res.camera_temperature &&
                std::abs(res.tint - std::clamp(res.camera_tint + 8.0f, -150.0f, 150.0f)) < 1e-4f,
            "DNG recipe WB combines camera tint + recipe tint * strength");
    const uint64_t afterProbeDecodes = sony2fuji_session_get_raw_decode_count(session.get());
    require(afterProbeDecodes == 1, "first DNG probe decodes exactly once");

    // Cache hit for same identity + modes
    req.custom_wb = 1;
    req.temperature = 5200.0f;
    req.tint = 30.0f;
    req.recipe_strength = 1.0f;
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &res) == SONY2FUJI_STATUS_OK,
            "cached custom WB resolve failed");
    require(res.temperature == 5200.0f &&
                std::abs(res.tint - std::clamp(res.camera_tint + 30.0f, -150.0f, 150.0f)) < 1e-4f,
            "custom WB keeps temperature and offsets camera tint");
    require(sony2fuji_session_get_raw_decode_count(session.get()) == afterProbeDecodes,
            "cached resolve must not decode again");

    // Invalidate on exposure_mode change
    req.exposure_mode = SONY2FUJI_EXPOSURE_SCENE;
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &res) == SONY2FUJI_STATUS_OK,
            "exposure mode change resolve failed");
    require(sony2fuji_session_get_raw_decode_count(session.get()) == afterProbeDecodes + 1,
            "exposure mode change invalidates recipe WB cache");

    // Invalidate on same-path file replacement (inode/mtime change)
    const fs::path tempDng2 = dir.path / "probe_new.DNG";
    fs::copy_file(dngPath, tempDng2, fs::copy_options::overwrite_existing);
    fs::rename(tempDng2, tempDng);
    const uint64_t beforeReplace = sony2fuji_session_get_raw_decode_count(session.get());
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &res) == SONY2FUJI_STATUS_OK,
            "replaced file resolve failed");
    require(sony2fuji_session_get_raw_decode_count(session.get()) == beforeReplace + 1,
            "file replacement invalidates recipe WB cache");

    // Cancellation during probe returns CANCELLED and does not poison cache
    auto cancelSession = createSession();
    require(sony2fuji_session_set_cancellation_callback(cancelSession.get(), cancelImmediately, nullptr) ==
                SONY2FUJI_STATUS_OK,
            "set cancel callback");
    require(sony2fuji_session_resolve_recipe_wb(cancelSession.get(), &req, &res) == SONY2FUJI_STATUS_CANCELLED,
            "cancelled probe returns CANCELLED");
    require(sony2fuji_session_set_cancellation_callback(cancelSession.get(), nullptr, nullptr) ==
                SONY2FUJI_STATUS_OK,
            "clear cancel callback");
    require(sony2fuji_session_resolve_recipe_wb(cancelSession.get(), &req, &res) == SONY2FUJI_STATUS_OK,
            "non-cancelled retry succeeds after previous cancel");

    // Error returns IO_ERROR and missing file is never cached
    const fs::path missing = dir.path / "missing.DNG";
    const std::string missingStr = missing.string();
    auto missingReq = makeRecipeWbRequest(missingStr.c_str());
    missingReq.tint = 10.0f;
    require(sony2fuji_session_resolve_recipe_wb(cancelSession.get(), &missingReq, &res) ==
                SONY2FUJI_STATUS_IO_ERROR,
            "missing file returns IO_ERROR");

    // Render-first populates recipeWbCache_ so subsequent resolve_recipe_wb does 0 extra decodes
    auto renderFirst = createSession();
    sony2fuji_request rawReq{};
    rawReq.version = SONY2FUJI_REQUEST_VERSION;
    rawReq.struct_size = sizeof(rawReq);
    rawReq.input_type = SONY2FUJI_INPUT_RAW;
    rawReq.input_path = tempDngPathStr.c_str();
    rawReq.wb_mode = SONY2FUJI_WB_CAMERA;
    rawReq.temperature = 6500.0f;
    std::fill(std::begin(rawReq.wb_mul), std::end(rawReq.wb_mul), 1.0f);
    rawReq.brightness = rawReq.contrast = rawReq.saturation = 1.0f;
    rawReq.output_target = SONY2FUJI_TARGET_BUFFER;
    rawReq.output_format = SONY2FUJI_OUTPUT_RGB8;
    rawReq.size_mode = SONY2FUJI_SIZE_NATIVE;
    rawReq.intent = SONY2FUJI_INTENT_PREVIEW;
    rawReq.preview_long_edge = 64;
    sony2fuji_buffer out{};
    require(sony2fuji_session_set_processing_version(renderFirst.get(), SONY2FUJI_PROCESSING_BASIC_V3) == SONY2FUJI_STATUS_OK,
            "set v3 on renderFirst");
    require(sony2fuji_session_set_raw_exposure_mode(renderFirst.get(), SONY2FUJI_EXPOSURE_PREVIEW) == SONY2FUJI_STATUS_OK,
            "set preview mode on renderFirst");
    require(sony2fuji_process(renderFirst.get(), &rawReq, &out) == SONY2FUJI_STATUS_OK,
            "renderFirst process failed");
    sony2fuji_release_buffer(&out);
    require(sony2fuji_session_get_raw_decode_count(renderFirst.get()) == 1,
            "renderFirst decoded once");

    auto afterRenderReq = makeRecipeWbRequest(tempDngPathStr.c_str());
    afterRenderReq.tint = 14.0f;
    require(sony2fuji_session_resolve_recipe_wb(renderFirst.get(), &afterRenderReq, &res) == SONY2FUJI_STATUS_OK,
            "resolve after render failed");
    require(sony2fuji_session_get_raw_decode_count(renderFirst.get()) == 1,
            "resolve after matching render must reuse cached camera WB without re-decoding");
}

} // namespace

int main(int argc, char** argv) {
    try {
        require(argc >= 2, "usage: recipe_wb_abi_tests <dng_fixture>");
        const fs::path dngPath(argv[1]);
        require(fs::exists(dngPath), "DNG fixture missing");
        TempDir dir;
        testInspectSdrJpegMpf(dir);
        testIsNormalX3f(dir, dngPath);
        testEffectiveRawWhiteBalance(dngPath);
        testResolveRecipeWb(dir, dngPath);
        std::cout << "recipe_wb_abi_tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
