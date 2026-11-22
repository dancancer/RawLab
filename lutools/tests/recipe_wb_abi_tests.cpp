#include "sony2fuji/ffi/sony2fuji_c.h"

#include <algorithm>
#include <array>
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

void writeU16LE(std::vector<uint8_t>& dst, size_t offset, uint16_t v) {
    dst[offset] = static_cast<uint8_t>(v & 0xff);
    dst[offset + 1] = static_cast<uint8_t>((v >> 8) & 0xff);
}

void writeU32LE(std::vector<uint8_t>& dst, size_t offset, uint32_t v) {
    dst[offset] = static_cast<uint8_t>(v & 0xff);
    dst[offset + 1] = static_cast<uint8_t>((v >> 8) & 0xff);
    dst[offset + 2] = static_cast<uint8_t>((v >> 16) & 0xff);
    dst[offset + 3] = static_cast<uint8_t>((v >> 24) & 0xff);
}

void writeSyntheticCalibratedDng(const fs::path& path, const std::array<std::pair<int32_t, int32_t>, 3>& asShotNeutral) {
    struct TiffEntry {
        uint16_t tag;
        uint16_t type;
        uint32_t count;
        std::vector<uint8_t> payload;
    };
    auto entryU16 = [](uint16_t tag, std::initializer_list<uint16_t> values) {
        TiffEntry e{tag, 3, static_cast<uint32_t>(values.size()), std::vector<uint8_t>(values.size() * 2)};
        size_t i = 0;
        for (uint16_t v : values) { writeU16LE(e.payload, i, v); i += 2; }
        return e;
    };
    auto entryU32 = [](uint16_t tag, std::initializer_list<uint32_t> values) {
        TiffEntry e{tag, 4, static_cast<uint32_t>(values.size()), std::vector<uint8_t>(values.size() * 4)};
        size_t i = 0;
        for (uint32_t v : values) { writeU32LE(e.payload, i, v); i += 4; }
        return e;
    };
    auto entryBytes = [](uint16_t tag, std::initializer_list<uint8_t> values) {
        return TiffEntry{tag, 1, static_cast<uint32_t>(values.size()), std::vector<uint8_t>(values)};
    };
    auto entryAscii = [](uint16_t tag, const std::string& text) {
        std::vector<uint8_t> bytes(text.begin(), text.end());
        bytes.push_back(0);
        return TiffEntry{tag, 2, static_cast<uint32_t>(bytes.size()), std::move(bytes)};
    };
    auto entryRationals = [](uint16_t tag, uint16_t type, const std::vector<std::pair<int32_t, int32_t>>& pairs) {
        TiffEntry e{tag, type, static_cast<uint32_t>(pairs.size()), std::vector<uint8_t>(pairs.size() * 8)};
        for (size_t i = 0; i < pairs.size(); ++i) {
            writeU32LE(e.payload, i * 8, static_cast<uint32_t>(pairs[i].first));
            writeU32LE(e.payload, i * 8 + 4, static_cast<uint32_t>(pairs[i].second));
        }
        return e;
    };
    const int rawW = 128, rawH = 96;
    std::vector<uint8_t> rawBytes(static_cast<size_t>(rawW) * rawH * 2, 0);
    for (size_t i = 0; i < static_cast<size_t>(rawW) * rawH; ++i) {
        writeU16LE(rawBytes, i * 2, 265);
    }
    std::vector<TiffEntry> ifd0 = {
        entryU32(254, {0}),
        entryU32(256, {static_cast<uint32_t>(rawW)}),
        entryU32(257, {static_cast<uint32_t>(rawH)}),
        entryU16(258, {16}),
        entryU16(259, {1}),
        entryU16(262, {32803}),
        entryAscii(271, "RawLab"),
        entryAscii(272, "WbProbe"),
        entryU32(273, {0}),
        entryU16(274, {1}),
        entryU16(277, {1}),
        entryU32(278, {static_cast<uint32_t>(rawH)}),
        entryU32(279, {static_cast<uint32_t>(rawBytes.size())}),
        entryU16(284, {1}),
        entryU16(33421, {2, 2}),
        entryBytes(33422, {0, 1, 1, 2}),
        entryBytes(50706, {1, 4, 0, 0}),
        entryBytes(50707, {1, 3, 0, 0}),
        entryAscii(50708, "RawLab WbProbe"),
        entryBytes(50710, {0, 1, 2}),
        entryU16(50711, {1}),
        entryU16(50713, {1, 1}),
        entryRationals(50714, 5, {{64, 1}}),
        entryU32(50717, {4095}),
        entryRationals(50721, 10, {
            {6722, 10000}, {-635, 10000}, {-963, 10000},
            {-4287, 10000}, {12460, 10000}, {2028, 10000},
            {-908, 10000}, {2162, 10000}, {5668, 10000}
        }),
        entryRationals(50728, 5, {asShotNeutral[0], asShotNeutral[1], asShotNeutral[2]}),
        entryU16(50778, {21}),
    };
    size_t ifdSize = 2 + ifd0.size() * 12 + 4;
    for (const auto& e : ifd0) {
        if (e.payload.size() > 4) ifdSize += (e.payload.size() + 1) & ~size_t(1);
    }
    const uint32_t ifdOffset = 8;
    const uint32_t rawOffset = static_cast<uint32_t>((ifdOffset + ifdSize + 3) & ~size_t(3));
    for (auto& e : ifd0) {
        if (e.tag == 273) writeU32LE(e.payload, 0, rawOffset);
    }
    std::vector<uint8_t> file(rawOffset + rawBytes.size(), 0);
    file[0] = 'I'; file[1] = 'I';
    writeU16LE(file, 2, 42);
    writeU32LE(file, 4, ifdOffset);
    writeU16LE(file, ifdOffset, static_cast<uint16_t>(ifd0.size()));
    uint32_t entryOffset = ifdOffset + 2;
    uint32_t dataOffset = entryOffset + static_cast<uint32_t>(ifd0.size()) * 12 + 4;
    for (const auto& e : ifd0) {
        writeU16LE(file, entryOffset, e.tag);
        writeU16LE(file, entryOffset + 2, e.type);
        writeU32LE(file, entryOffset + 4, e.count);
        if (e.payload.size() <= 4) {
            std::copy(e.payload.begin(), e.payload.end(), file.begin() + entryOffset + 8);
        } else {
            writeU32LE(file, entryOffset + 8, dataOffset);
            std::copy(e.payload.begin(), e.payload.end(), file.begin() + dataOffset);
            dataOffset += static_cast<uint32_t>((e.payload.size() + 1) & ~size_t(1));
        }
        entryOffset += 12;
    }
    std::copy(rawBytes.begin(), rawBytes.end(), file.begin() + rawOffset);
    writeBytes(path, file);
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
    require(afterProbeDecodes == 0, "metadata-only DNG probe must perform 0 pixel decodes");
    const float firstCamTemp = res.camera_temperature;
    const float firstCamTint = res.camera_tint;

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
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 0,
            "cached resolve must still have 0 pixel decodes");

    // Invalidate on exposure_mode change
    req.exposure_mode = SONY2FUJI_EXPOSURE_SCENE;
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &res) == SONY2FUJI_STATUS_OK,
            "exposure mode change resolve failed");
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 0,
            "metadata-only resolve on exposure mode change performs 0 pixel decodes");
    require(res.camera_temperature == firstCamTemp && res.camera_tint == firstCamTint,
            "exposure mode change preserves calibrated camera WB");

    // Invalidate on same-path file replacement (inode/mtime change): verify updated WB and corrupt rejection.
    const fs::path tempDngWarm = dir.path / "probe_warm.DNG";
    writeSyntheticCalibratedDng(tempDngWarm, {{{1, 2}, {1, 1}, {2, 3}}});
    fs::rename(tempDngWarm, tempDng);
    sony2fuji_recipe_wb_result warmRes{};
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &warmRes) == SONY2FUJI_STATUS_OK,
            "replaced synthetic warm DNG resolve failed");
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 0,
            "replaced file metadata probe performs 0 pixel decodes");

    const fs::path tempDngCool = dir.path / "probe_cool.DNG";
    writeSyntheticCalibratedDng(tempDngCool, {{{2, 3}, {1, 1}, {1, 3}}});
    fs::rename(tempDngCool, tempDng);
    sony2fuji_recipe_wb_result coolRes{};
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &coolRes) == SONY2FUJI_STATUS_OK,
            "replaced synthetic cool DNG resolve failed");
    require(coolRes.camera_temperature != warmRes.camera_temperature,
            "file replacement invalidates recipe WB cache and reflects new AsShotNeutral");

    const fs::path corruptReplacement = dir.path / "probe_corrupt.DNG";
    writeBytes(corruptReplacement, {'N', 'O', 'T', '_', 'R', 'A', 'W'});
    fs::rename(corruptReplacement, tempDng);
    require(sony2fuji_session_resolve_recipe_wb(session.get(), &req, &res) != SONY2FUJI_STATUS_OK,
            "corrupt replacement invalidates recipe WB cache instead of returning stale OK");

    // Restore calibrated DNG at tempDng for remaining tests
    const fs::path tempDng2 = dir.path / "probe_new.DNG";
    fs::copy_file(dngPath, tempDng2, fs::copy_options::overwrite_existing);
    fs::rename(tempDng2, tempDng);

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

void testInteractiveWbMatrixShortcut(const fs::path& dngPath) {
    auto session = createSession(SONY2FUJI_GPU_AUTO);
    require(sony2fuji_session_set_processing_version(session.get(), SONY2FUJI_PROCESSING_BASIC_V3) == SONY2FUJI_STATUS_OK,
            "v3 for wb shortcut");
    require(sony2fuji_session_set_raw_exposure_mode(session.get(), SONY2FUJI_EXPOSURE_PREVIEW) == SONY2FUJI_STATUS_OK,
            "preview exposure mode for wb shortcut");
    require(sony2fuji_session_set_viewport_preview(session.get(), 1) == SONY2FUJI_STATUS_OK,
            "viewport preview for wb shortcut");
    require(sony2fuji_session_set_interactive_preview(session.get(), 0) == SONY2FUJI_STATUS_OK,
            "settled initial frame");

    const std::string pathStr = dngPath.string();
    sony2fuji_request req{};
    req.version = SONY2FUJI_REQUEST_VERSION;
    req.struct_size = sizeof(req);
    req.input_type = SONY2FUJI_INPUT_RAW;
    req.input_path = pathStr.c_str();
    req.wb_mode = SONY2FUJI_WB_CAMERA;
    req.temperature = 6500.0f;
    std::fill(std::begin(req.wb_mul), std::end(req.wb_mul), 1.0f);
    req.brightness = req.saturation = 1.0f;
    req.contrast = 1.2f;
    req.highlights = -0.35f;
    req.shadows = 0.40f;
    req.output_target = SONY2FUJI_TARGET_BUFFER;
    req.output_format = SONY2FUJI_OUTPUT_RGB8;
    req.size_mode = SONY2FUJI_SIZE_NATIVE;
    req.intent = SONY2FUJI_INTENT_PREVIEW;
    req.preview_long_edge = 128;

    auto renderPixels = [&]() {
        sony2fuji_buffer out{};
        require(sony2fuji_process(session.get(), &req, &out) == SONY2FUJI_STATUS_OK, "wb shortcut render");
        const auto* bytes = static_cast<const uint8_t*>(out.data);
        std::vector<uint8_t> pixels(bytes, bytes + out.size_bytes);
        sony2fuji_release_buffer(&out);
        return pixels;
    };

    const auto camPx = renderPixels();
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 1,
            "initial settled BasicToneV3 Camera WB decodes once");

    require(sony2fuji_session_set_interactive_preview(session.get(), 1) == SONY2FUJI_STATUS_OK,
            "enable interactive preview");
    req.wb_mode = SONY2FUJI_WB_TEMPERATURE;
    req.temperature = 4500.0f;
    const auto inter4500 = renderPixels();
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 1,
            "interactive 4500K WB switch must trigger 0 extra RAW decodes");

    req.temperature = 7500.0f;
    const auto inter7500 = renderPixels();
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 1,
            "interactive 7500K WB switch must trigger 0 extra RAW decodes");
    require(inter4500 != camPx && inter7500 != inter4500,
            "interactive WB matrix shortcut must noticeably change rendered WB colors");

    require(sony2fuji_session_set_interactive_preview(session.get(), 0) == SONY2FUJI_STATUS_OK,
            "disable interactive preview to settle");
    const auto settled7500 = renderPixels();
    require(sony2fuji_session_get_raw_decode_count(session.get()) == 2,
            "settled 7500K WB must perform exact LibRaw WB-before-demosaic decode");
    require(inter7500.size() == settled7500.size(), "interactive and settled output size match");

    double unclippedSum = 0.0;
    size_t unclippedCount = 0;
    for (size_t i = 0; i + 2 < settled7500.size(); i += 3) {
        if (std::max({settled7500[i], settled7500[i + 1], settled7500[i + 2]}) < 235 &&
            std::max({inter7500[i], inter7500[i + 1], inter7500[i + 2]}) < 235) {
            const int d = std::max({
                std::abs(int(inter7500[i]) - int(settled7500[i])),
                std::abs(int(inter7500[i + 1]) - int(settled7500[i + 1])),
                std::abs(int(inter7500[i + 2]) - int(settled7500[i + 2]))
            });
            unclippedSum += d;
            ++unclippedCount;
        }
    }
    require(unclippedCount > 0 && (unclippedSum / unclippedCount) <= 4.0,
            "interactive 7500K WB must closely match settled LibRaw WB on unclipped pixels");
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
        testInteractiveWbMatrixShortcut(dngPath);
        std::cout << "recipe_wb_abi_tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
