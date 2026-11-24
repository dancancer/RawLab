#include "test_harness.h"

#include "core/edit_recipe_params.h"
#include "core/pipeline.h"
#include "nlohmann/json.hpp"
#include "sony2fuji/edit_recipe.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

using Json = nlohmann::json;
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
    explicit SessionGuard(sony2fuji_gpu_mode mode = SONY2FUJI_GPU_OFF) {
        require(sony2fuji_session_create(&ptr) == SONY2FUJI_STATUS_OK && ptr != nullptr,
            "sony2fuji_session_create failed", __FILE__, __LINE__);
        sony2fuji_gpu_config cfg{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(cfg), mode};
        require(sony2fuji_session_set_gpu_config(ptr, &cfg) == SONY2FUJI_STATUS_OK,
            "set_gpu_config failed", __FILE__, __LINE__);
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

struct HslProbeGuard {
    sony2fuji_hsl_probe* ptr = nullptr;
    ~HslProbeGuard() {
        if (ptr) sony2fuji_hsl_probe_destroy(ptr);
    }
};

struct TempDir {
    fs::path path;
    TempDir()
        : path(fs::temp_directory_path() /
               ("rawlab-canonical-state-" +
                std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()))) {
        require(fs::create_directories(path), "create temp dir", __FILE__, __LINE__);
    }
    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

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

void writeSyntheticDng(const fs::path& path, bool calibrated,
                       const std::array<std::pair<int32_t, int32_t>, 3>& asShotNeutral) {
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

    const int rawW = 64, rawH = 48;
    std::vector<uint8_t> rawBytes(static_cast<size_t>(rawW) * rawH * 2, 0);
    for (int y = 0; y < rawH; ++y) {
        for (int x = 0; x < rawW; ++x) {
            const uint16_t val = static_cast<uint16_t>(300 + ((x + y) & 31) * 40);
            writeU16LE(rawBytes, (static_cast<size_t>(y) * rawW + x) * 2, val);
        }
    }

    std::vector<TiffEntry> ifd0 = {
        entryU32(254, {0}),
        entryU32(256, {static_cast<uint32_t>(rawW)}),
        entryU32(257, {static_cast<uint32_t>(rawH)}),
        entryU16(258, {16}),
        entryU16(259, {1}),
        entryU16(262, {32803}),
        entryAscii(271, "RawLab"),
        entryAscii(272, calibrated ? "CalCam" : "UncalCam"),
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
        entryAscii(50708, calibrated ? "RawLab CalCam" : "RawLab UncalCam"),
        entryBytes(50710, {0, 1, 2}),
        entryU16(50711, {1}),
        entryU16(50713, {1, 1}),
        entryRationals(50714, 5, {{64, 1}}),
        entryU32(50717, {4095}),
    };
    if (calibrated) {
        ifd0.push_back(entryRationals(50721, 10, {
            {6722, 10000}, {-635, 10000}, {-963, 10000},
            {-4287, 10000}, {12460, 10000}, {2028, 10000},
            {-908, 10000}, {2162, 10000}, {5668, 10000}
        }));
        ifd0.push_back(entryRationals(50728, 5, {asShotNeutral[0], asShotNeutral[1], asShotNeutral[2]}));
        ifd0.push_back(entryU16(50778, {21}));
    }

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
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    require(static_cast<bool>(out), "open temp dng for write", __FILE__, __LINE__);
    out.write(reinterpret_cast<const char*>(file.data()), static_cast<std::streamsize>(file.size()));
    require(static_cast<bool>(out), "write temp dng", __FILE__, __LINE__);
}

std::vector<uint8_t> bufferBytes(const sony2fuji_buffer& buf) {
    const auto* p = static_cast<const uint8_t*>(buf.data);
    return std::vector<uint8_t>(p, p + buf.size_bytes);
}

void testOptionalFieldsAndStrictSeparation() {
    using namespace sony2fuji;
    std::string err;
    CanonicalEditState state;

    // Minimal processing-only JSON succeeds in SessionState mode without input/output/edits.
    const std::string processingOnly = Json({
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}}
    }).dump();
    require(parseCanonicalEditState(processingOnly, state, err, {RecipeParseMode::SessionState, true}),
        "SessionState should accept minimal processing-only JSON", __FILE__, __LINE__);
    require(!state.isHdr && state.processingVersion == ProcessingVersion::BasicV3 && state.aiDenoiseBlend == 1.0f,
        "Minimal processing-only defaults mismatch", __FILE__, __LINE__);

    // Strict FileRecipe mode still rejects missing input/output/edits.
    CanonicalSdrRecipe sdr;
    require(!parseCanonicalSdrRecipe(processingOnly, sdr, err, false),
        "FileRecipe must continue rejecting missing schema/input/output/edits", __FILE__, __LINE__);

    // SDR session JSON without input/output but with ai_denoise_blend and master_recipe.
    const std::string sdrSession = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.35}, {"brightness", 1.1}}},
            {"white_balance", {{"mode", "camera"}}},
            {"ai_denoise_blend", 0.42},
            {"master_recipe", {
                {"active", true},
                {"strength", 0.8},
                {"custom_wb", false},
                {"temperature_kelvin", 6500.0},
                {"tint", 12.0},
                {"uncalibrated_fallback", "camera"}
            }}
        }}
    }).dump();
    require(parseCanonicalEditState(sdrSession, state, err, {RecipeParseMode::SessionState, true}),
        "SessionState should accept SDR JSON with ai_denoise_blend and master_recipe", __FILE__, __LINE__);
    require(state.hasAiDenoiseBlend && std::abs(state.aiDenoiseBlend - 0.42f) < 1e-5f,
        "ai_denoise_blend value mismatch", __FILE__, __LINE__);
    require(state.masterRecipe.active && std::abs(state.masterRecipe.strength - 0.8f) < 1e-5f &&
            state.masterRecipe.uncalibratedFallback == UncalibratedWbPolicy::FallbackCamera,
        "master_recipe parsed fields mismatch", __FILE__, __LINE__);

    // Reject out-of-range ai_denoise_blend or unknown uncalibrated_fallback.
    const std::string badBlend = Json({
        {"edits", {{"ai_denoise_blend", 1.25}}}
    }).dump();
    require(!parseCanonicalEditState(badBlend, state, err, {RecipeParseMode::SessionState, true}),
        "ai_denoise_blend > 1.0 must fail", __FILE__, __LINE__);

    // Schema-less SessionState JSON containing "input" without "camera_development" must parse cleanly.
    const std::string schemaLessHdrRaster = Json({
        {"input", {{"type", "hdr_raster"}}},
        {"edits", {{"exposure", {{"ev", 0.25}}}}}
    }).dump();
    require(parseCanonicalEditState(schemaLessHdrRaster, state, err, {RecipeParseMode::SessionState, true}) &&
            state.isHdr && std::abs(state.exposureEv - 0.25f) < 1e-5f,
        ("Schema-less SessionState with input.type=hdr_raster must parse: " + err).c_str(), __FILE__, __LINE__);

    const std::string schemaLessSdrRaster = Json({
        {"input", {{"type", "raster"}}},
        {"edits", {{"exposure", {{"ev", 0.25}}}}}
    }).dump();
    require(parseCanonicalEditState(schemaLessSdrRaster, state, err, {RecipeParseMode::SessionState, true}) &&
            !state.isHdr && state.rasterInput && std::abs(state.exposureEv - 0.25f) < 1e-5f,
        ("Schema-less SessionState with input.type=raster must parse: " + err).c_str(), __FILE__, __LINE__);

    const std::string schemaLessInputPath = Json({
        {"input", {{"path", (fs::path("dir") / "photo.dng").string()}}},
        {"edits", {{"exposure", {{"ev", 0.25}}}}}
    }).dump();
    require(parseCanonicalEditState(schemaLessInputPath, state, err, {RecipeParseMode::SessionState, true}) &&
            !state.isHdr && !state.rasterInput && std::abs(state.exposureEv - 0.25f) < 1e-5f,
        ("Schema-less SessionState with input.path must parse: " + err).c_str(), __FILE__, __LINE__);
}

void testSdrParityAndStatelessNonLeakage() {
    constexpr uint32_t kW = 64;
    constexpr uint32_t kH = 48;
    std::vector<uint8_t> raster(static_cast<size_t>(kW) * kH * 3);
    for (uint32_t y = 0; y < kH; ++y) {
        for (uint32_t x = 0; x < kW; ++x) {
            const size_t i = (static_cast<size_t>(y) * kW + x) * 3;
            raster[i + 0] = static_cast<uint8_t>(30 + ((x * 3) % 190));
            raster[i + 1] = static_cast<uint8_t>(40 + ((y * 4) % 180));
            raster[i + 2] = static_cast<uint8_t>(50 + (((x + y) * 2) % 170));
        }
    }

    const Json v17Edits = {
        {"exposure", {{"mode", "sensor"}, {"ev", 0.25}, {"brightness", 1.0}}},
        {"white_balance", {{"mode", "relative"}, {"relative_temperature", 7100.0}, {"relative_tint", 14.0}}},
        {"tone", {
            {"contrast", 1.12},
            {"saturation", 1.08},
            {"highlights", 0.2},
            {"shadows", 0.15},
            {"s_curve", 0.0},
            {"black_point", 0.05},
            {"white_point", -0.05},
            {"curve", {
                {"mode", "custom"},
                {"points", {{0.0, 0.04}, {0.5, 0.56}, {1.0, 0.96}}},
                {"apply_to_luminosity", true},
                {"parametric", {
                    {"highlights", -12.0}, {"lights", 8.0}, {"darks", -5.0}, {"shadows", 10.0},
                    {"split_shadow", 0.22}, {"split_midtone", 0.50}, {"split_highlight", 0.78}
                }},
                {"channels", {
                    {"red", {{"mode", "custom"}, {"points", {{0.0, 0.0}, {0.5, 0.52}, {1.0, 1.0}}}}}
                }}
            }}
        }},
        {"color", {{"vibrance", 0.18}}},
        {"color_grading", {
            {"shadows", {{"hue", 215.0}, {"saturation", 20.0}, {"luminance", -5.0}}},
            {"midtones", {{"hue", 40.0}, {"saturation", 12.0}, {"luminance", 4.0}}},
            {"highlights", {{"hue", 55.0}, {"saturation", 15.0}, {"luminance", 6.0}}},
            {"global", {{"hue", 10.0}, {"saturation", 5.0}, {"luminance", 2.0}}},
            {"blending", 65.0},
            {"balance", -15.0}
        }},
        {"detail", {{"sharpening", 0.35}}},
        {"hsl", {
            {"hue", {5, 0, -4, 0, 0, 8, 0, 0}},
            {"saturation", {10, -5, 0, 12, 0, 0, 0, 0}},
            {"lightness", {0, 0, 6, 0, -8, 0, 0, 0}}
        }},
        {"effects", {
            {"vignette_amount", -18.0}, {"vignette_midpoint", 45.0},
            {"vignette_roundness", 10.0}, {"vignette_feather", 55.0},
            {"vignette_highlights", 20.0}, {"grain_amount", 0.0},
            {"grain_size", 25.0}, {"grain_roughness", 50.0},
            {"clarity", 0.12}, {"dehaze", 0.08}
        }},
        {"geometry", {
            {"crop", {{"x", 0.05}, {"y", 0.05}, {"width", 0.9}, {"height", 0.9}}},
            {"quarter_turns", 1},
            {"flip_horizontal", false},
            {"flip_vertical", true},
            {"straighten_degrees", 2.5},
            {"perspective", {{"horizontal", 0.05}, {"vertical", -0.05}}}
        }}
    };

    const std::string legacyJson = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"input", {{"path", "session.png"}, {"type", "raster"}}},
        {"edits", v17Edits},
        {"output", {{"path", "session.png"}, {"format", "png"}, {"output_sharpening", "standard"}, {"size", {{"mode", "native"}}}}}
    }).dump();

    // New session-state JSON: omits input.path and output completely (only input.type for raster relative WB).
    const std::string sessionJson = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"input", {{"type", "raster"}}},
        {"edits", v17Edits},
        {"output", {{"output_sharpening", "standard"}}}
    }).dump();

    SessionGuard legacySess, newSess;
    require(sony2fuji_apply_params(legacySess.ptr, legacyJson.c_str()) == SONY2FUJI_STATUS_OK,
        "legacy apply_params failed", __FILE__, __LINE__);

    sony2fuji_request req{};
    req.version = SONY2FUJI_REQUEST_VERSION;
    req.struct_size = sizeof(req);
    req.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    req.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    req.input_pixels = raster.data();
    req.input_width = kW;
    req.input_height = kH;
    req.input_color_space = SONY2FUJI_COLOR_SRGB;
    req.wb_mode = SONY2FUJI_WB_CAMERA;
    req.temperature = 6500.0f;
    req.exposure_ev = 0.25f;
    req.brightness = 1.0f;
    req.contrast = 1.12f;
    req.saturation = 1.08f;
    req.highlights = 0.2f;
    req.shadows = 0.15f;
    req.sharpening = 0.35f;
    req.lut_strength = 1.0f;
    req.intent = SONY2FUJI_INTENT_FINAL;
    req.size_mode = SONY2FUJI_SIZE_NATIVE;
    req.output_target = SONY2FUJI_TARGET_BUFFER;
    req.output_format = SONY2FUJI_OUTPUT_RGBA8;

    BufferGuard legacyBuf;
    require(sony2fuji_process(legacySess.ptr, &req, &legacyBuf.value) == SONY2FUJI_STATUS_OK,
        "legacy sony2fuji_process failed", __FILE__, __LINE__);

    sony2fuji_render_options_v1 opts{};
    opts.version = SONY2FUJI_RENDER_OPTIONS_V1_VERSION;
    opts.struct_size = sizeof(opts);
    opts.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    opts.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    opts.input_pixels = raster.data();
    opts.input_width = kW;
    opts.input_height = kH;
    opts.input_color_space = SONY2FUJI_COLOR_SRGB;
    opts.intent = SONY2FUJI_INTENT_FINAL;
    opts.size_mode = SONY2FUJI_SIZE_NATIVE;
    opts.output_target = SONY2FUJI_TARGET_BUFFER;
    opts.output_format = SONY2FUJI_OUTPUT_RGBA8;

    BufferGuard newBuf;
    sony2fuji_viewport_roi_result roiRes{};
    roiRes.struct_size = sizeof(roiRes);
    require(sony2fuji_session_render(newSess.ptr, &opts, sessionJson.c_str(), &newBuf.value, &roiRes) == SONY2FUJI_STATUS_OK,
        "sony2fuji_session_render failed", __FILE__, __LINE__);
    require(roiRes.active == 0 && newBuf.value.width == legacyBuf.value.width &&
            newBuf.value.height == legacyBuf.value.height &&
            bufferBytes(newBuf.value) == bufferBytes(legacyBuf.value),
        "SDR CanonicalEditState render output must match legacy path byte-for-byte", __FILE__, __LINE__);

    // Re-render with edit_state_json == nullptr must match committed session state identically.
    BufferGuard repeatBuf;
    require(sony2fuji_session_render(newSess.ptr, &opts, nullptr, &repeatBuf.value, nullptr) == SONY2FUJI_STATUS_OK,
        "sony2fuji_session_render with null edit_state_json failed", __FILE__, __LINE__);
    require(bufferBytes(repeatBuf.value) == bufferBytes(legacyBuf.value),
        "Repeat render with null edit_state_json must match committed state", __FILE__, __LINE__);

    // RGBA16 parity check.
    BufferGuard legacyR16, newR16;
    require(sony2fuji_session_render_rgba16(legacySess.ptr, &req, &legacyR16.value) == SONY2FUJI_STATUS_OK &&
            sony2fuji_session_render_rgba16_with_options(newSess.ptr, &opts, nullptr, &newR16.value) == SONY2FUJI_STATUS_OK,
        "render_rgba16 parity failed", __FILE__, __LINE__);
    require(bufferBytes(newR16.value) == bufferBytes(legacyR16.value),
        "render_rgba16_with_options must match legacy sony2fuji_session_render_rgba16", __FILE__, __LINE__);

    // Transient viewport_roi & intent non-leakage check.
    sony2fuji_viewport_roi roi{};
    roi.struct_size = sizeof(roi);
    roi.enabled = 1;
    roi.norm_x0 = 0.25;
    roi.norm_y0 = 0.25;
    roi.norm_x1 = 0.75;
    roi.norm_y1 = 0.75;
    roi.max_output_long_edge = 512;

    auto roiOpts = opts;
    roiOpts.intent = SONY2FUJI_INTENT_PREVIEW;
    roiOpts.interactive_preview = 1;
    roiOpts.viewport_preview = 1;
    roiOpts.viewport_roi = &roi;

    BufferGuard roiBuf;
    sony2fuji_viewport_roi_result roiOut{};
    roiOut.struct_size = sizeof(roiOut);
    require(sony2fuji_session_render(newSess.ptr, &roiOpts, nullptr, &roiBuf.value, &roiOut) == SONY2FUJI_STATUS_OK,
        "transient ROI render failed", __FILE__, __LINE__);
    require(roiOut.active == 1 && roiBuf.value.width < newBuf.value.width && roiBuf.value.height < newBuf.value.height,
        "transient ROI render must crop output to ROI", __FILE__, __LINE__);

    // Immediate subsequent render WITHOUT viewport_roi must restore full dimensions & inactive ROI.
    BufferGuard afterRoiBuf;
    sony2fuji_viewport_roi_result afterRoiOut{};
    afterRoiOut.struct_size = sizeof(afterRoiOut);
    require(sony2fuji_session_render(newSess.ptr, &opts, nullptr, &afterRoiBuf.value, &afterRoiOut) == SONY2FUJI_STATUS_OK,
        "post-ROI full render failed", __FILE__, __LINE__);
    require(afterRoiOut.active == 0 && bufferBytes(afterRoiBuf.value) == bufferBytes(legacyBuf.value),
        "transient viewport_roi/intent must not leak into subsequent calls", __FILE__, __LINE__);
}

void testMasterRecipeWbInCore(const TempDir& dir) {
    const fs::path calDng = dir.path / "cal.dng";
    const fs::path uncalDng = dir.path / "uncal.dng";
    writeSyntheticDng(calDng, /*calibrated=*/true, {{{1, 2}, {1, 1}, {2, 3}}});
    writeSyntheticDng(uncalDng, /*calibrated=*/false, {{{1, 1}, {1, 1}, {1, 1}}});

    const std::string calStr = calDng.string();
    const std::string uncalStr = uncalDng.string();

    // Verify calibrated RAW master_recipe WB parity against legacy resolve_recipe_wb + process.
    SessionGuard legacySess, newSess;
    sony2fuji_recipe_wb_request wbReq{};
    wbReq.version = SONY2FUJI_RECIPE_WB_REQUEST_VERSION;
    wbReq.struct_size = sizeof(wbReq);
    wbReq.input_path = calStr.c_str();
    wbReq.processing_version = SONY2FUJI_PROCESSING_BASIC_V3;
    wbReq.x3f_mode = SONY2FUJI_X3F_LEGACY;
    wbReq.exposure_mode = SONY2FUJI_EXPOSURE_PREVIEW;
    wbReq.recipe_active = 1;
    wbReq.recipe_strength = 0.75f;
    wbReq.custom_wb = 0;
    wbReq.temperature = 6500.0f;
    wbReq.tint = 16.0f;
    sony2fuji_recipe_wb_result wbRes{};
    require(sony2fuji_session_resolve_recipe_wb(legacySess.ptr, &wbReq, &wbRes) == SONY2FUJI_STATUS_OK,
        "legacy resolve_recipe_wb failed", __FILE__, __LINE__);

    const std::string neutralLegacyJson = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"input", {{"path", calStr}, {"type", "raw"}}},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}}
        }}
    }).dump();
    require(sony2fuji_apply_params(legacySess.ptr, neutralLegacyJson.c_str()) == SONY2FUJI_STATUS_OK,
        "legacy apply_params for calibrated DNG failed", __FILE__, __LINE__);

    sony2fuji_request rawReq{};
    rawReq.version = SONY2FUJI_REQUEST_VERSION;
    rawReq.struct_size = sizeof(rawReq);
    rawReq.input_type = SONY2FUJI_INPUT_RAW;
    rawReq.input_path = calStr.c_str();
    rawReq.wb_mode = wbRes.wb_mode;
    rawReq.temperature = wbRes.temperature;
    rawReq.tint = wbRes.tint;
    rawReq.brightness = rawReq.contrast = rawReq.saturation = rawReq.lut_strength = 1.0f;
    rawReq.intent = SONY2FUJI_INTENT_FINAL;
    rawReq.size_mode = SONY2FUJI_SIZE_NATIVE;
    rawReq.output_target = SONY2FUJI_TARGET_BUFFER;
    rawReq.output_format = SONY2FUJI_OUTPUT_RGBA8;
    BufferGuard legacyBuf;
    require(sony2fuji_process(legacySess.ptr, &rawReq, &legacyBuf.value) == SONY2FUJI_STATUS_OK,
        "legacy calibrated RAW render failed", __FILE__, __LINE__);

    const std::string masterErrJson = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}},
            {"master_recipe", {
                {"active", true},
                {"strength", 0.75},
                {"custom_wb", false},
                {"temperature_kelvin", 6500.0},
                {"tint", 16.0},
                {"uncalibrated_fallback", "error"}
            }}
        }}
    }).dump();

    sony2fuji_render_options_v1 rawOpts{};
    rawOpts.version = SONY2FUJI_RENDER_OPTIONS_V1_VERSION;
    rawOpts.struct_size = sizeof(rawOpts);
    rawOpts.input_type = SONY2FUJI_INPUT_RAW;
    rawOpts.input_path = calStr.c_str();
    rawOpts.intent = SONY2FUJI_INTENT_FINAL;
    rawOpts.size_mode = SONY2FUJI_SIZE_NATIVE;
    rawOpts.output_target = SONY2FUJI_TARGET_BUFFER;
    rawOpts.output_format = SONY2FUJI_OUTPUT_RGBA8;

    BufferGuard newBuf;
    require(sony2fuji_session_render(newSess.ptr, &rawOpts, masterErrJson.c_str(), &newBuf.value, nullptr) == SONY2FUJI_STATUS_OK,
        "new render with master_recipe failed on calibrated DNG", __FILE__, __LINE__);
    require(bufferBytes(newBuf.value) == bufferBytes(legacyBuf.value),
        "closed master_recipe WB render must match legacy pre-resolved WB byte-for-byte", __FILE__, __LINE__);

    // Also exercise auto_exposure_json, wb_probe_json, hsl_probe_json with master_recipe.
    float autoEv = 0.0f;
    require(sony2fuji_session_estimate_auto_exposure_json(newSess.ptr, &rawOpts, nullptr, &autoEv) == SONY2FUJI_STATUS_OK &&
            std::isfinite(autoEv),
        "estimate_auto_exposure_json failed", __FILE__, __LINE__);

    sony2fuji_wb_probe_query wbQ{SONY2FUJI_WB_PROBE_VERSION, sizeof(wbQ), 0.5f, 0.5f, 3u, 0u};
    sony2fuji_wb_probe_result wbP{};
    wbP.version = SONY2FUJI_WB_PROBE_VERSION;
    wbP.struct_size = sizeof(wbP);
    require(sony2fuji_session_sample_wb_probe_json(newSess.ptr, &rawOpts, nullptr, &wbQ, &wbP) == SONY2FUJI_STATUS_OK &&
            wbP.availability == SONY2FUJI_WB_PROBE_AVAILABLE,
        "sample_wb_probe_json failed", __FILE__, __LINE__);

    HslProbeGuard hslProbe;
    require(sony2fuji_session_create_hsl_probe_json(newSess.ptr, &rawOpts, nullptr, 1u, 1u, &hslProbe.ptr) == SONY2FUJI_STATUS_OK &&
            hslProbe.ptr != nullptr,
        "create_hsl_probe_json failed", __FILE__, __LINE__);

    // Uncalibrated DNG: uncalibrated_fallback = "error" -> UNSUPPORTED; "camera" -> OK!
    auto uncalOpts = rawOpts;
    uncalOpts.input_path = uncalStr.c_str();
    BufferGuard uncalFailBuf;
    require(sony2fuji_session_render(newSess.ptr, &uncalOpts, masterErrJson.c_str(), &uncalFailBuf.value, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED &&
            uncalFailBuf.value.data == nullptr,
        "uncalibrated_fallback=error must return UNSUPPORTED on uncalibrated RAW", __FILE__, __LINE__);

    const std::string masterCamJson = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}},
            {"master_recipe", {
                {"active", true},
                {"strength", 0.75},
                {"custom_wb", false},
                {"temperature_kelvin", 6500.0},
                {"tint", 16.0},
                {"uncalibrated_fallback", "camera"}
            }}
        }}
    }).dump();
    BufferGuard uncalOkBuf;
    require(sony2fuji_session_render(newSess.ptr, &uncalOpts, masterCamJson.c_str(), &uncalOkBuf.value, nullptr) == SONY2FUJI_STATUS_OK &&
            uncalOkBuf.value.data != nullptr,
        "uncalibrated_fallback=camera must fall back to camera WB cleanly on uncalibrated RAW", __FILE__, __LINE__);

    // Neutral Camera WB baselines for calibrated & uncalibrated DNGs.
    const std::string neutralCamJson = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}}
        }}
    }).dump();
    BufferGuard calNeutralBuf, uncalNeutralBuf;
    require(sony2fuji_session_render(newSess.ptr, &rawOpts, neutralCamJson.c_str(), &calNeutralBuf.value, nullptr) == SONY2FUJI_STATUS_OK &&
            sony2fuji_session_render(newSess.ptr, &uncalOpts, neutralCamJson.c_str(), &uncalNeutralBuf.value, nullptr) == SONY2FUJI_STATUS_OK,
        "neutral Camera WB baseline renders failed", __FILE__, __LINE__);

    // custom_wb=false with strength=0.0, temperature_kelvin=4800.0, tint=16.0 must render neutral Camera WB.
    const std::string zeroStrengthMasterJson = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}},
            {"master_recipe", {
                {"active", true},
                {"strength", 0.0},
                {"custom_wb", false},
                {"temperature_kelvin", 4800.0},
                {"tint", 16.0},
                {"uncalibrated_fallback", "error"}
            }}
        }}
    }).dump();
    BufferGuard zeroStrengthBuf;
    require(sony2fuji_session_render(newSess.ptr, &rawOpts, zeroStrengthMasterJson.c_str(), &zeroStrengthBuf.value, nullptr) == SONY2FUJI_STATUS_OK &&
            bufferBytes(zeroStrengthBuf.value) == bufferBytes(calNeutralBuf.value),
        "master_recipe custom_wb=false, strength=0.0 must match neutral Camera WB byte-for-byte", __FILE__, __LINE__);

    // custom_wb=false with strength=0.75, temperature_kelvin=4800.0, tint=0.0 must render neutral Camera WB.
    const std::string zeroTintMasterJson = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}},
            {"master_recipe", {
                {"active", true},
                {"strength", 0.75},
                {"custom_wb", false},
                {"temperature_kelvin", 4800.0},
                {"tint", 0.0},
                {"uncalibrated_fallback", "error"}
            }}
        }}
    }).dump();
    BufferGuard zeroTintBuf;
    require(sony2fuji_session_render(newSess.ptr, &rawOpts, zeroTintMasterJson.c_str(), &zeroTintBuf.value, nullptr) == SONY2FUJI_STATUS_OK &&
            bufferBytes(zeroTintBuf.value) == bufferBytes(calNeutralBuf.value),
        "master_recipe custom_wb=false, tint=0.0 must match neutral Camera WB byte-for-byte", __FILE__, __LINE__);

    // uncalibrated_fallback="camera" with non-default temperature_kelvin=4800.0, tint=16.0 must fall back to neutral Camera WB.
    const std::string uncalNonNeutralFallbackJson = Json({
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}},
            {"master_recipe", {
                {"active", true},
                {"strength", 0.75},
                {"custom_wb", false},
                {"temperature_kelvin", 4800.0},
                {"tint", 16.0},
                {"uncalibrated_fallback", "camera"}
            }}
        }}
    }).dump();
    BufferGuard uncalFallbackNeutralBuf;
    require(sony2fuji_session_render(newSess.ptr, &uncalOpts, uncalNonNeutralFallbackJson.c_str(), &uncalFallbackNeutralBuf.value, nullptr) == SONY2FUJI_STATUS_OK &&
            bufferBytes(uncalFallbackNeutralBuf.value) == bufferBytes(uncalNeutralBuf.value),
        "uncalibrated_fallback=camera must normalize temperature/tint to neutral Camera WB", __FILE__, __LINE__);

    // Direct C++ CanonicalEditState with Camera WB without master_recipe must also normalize temperature/tint to (6500, 0).
    {
        sony2fuji::Pipeline directPipe;
        sony2fuji::CanonicalEditState directState{};
        directState.processingVersion = sony2fuji::ProcessingVersion::BasicV3;
        directState.exposureMode = sony2fuji::RawExposureMode::Preview;
        directState.whiteBalanceMode = sony2fuji::RenderWhiteBalanceMode::Camera;
        directState.temperatureKelvin = 4800.0f;
        directState.tint = 16.0f;
        require(directPipe.applyEditState(directState, false) == sony2fuji::RenderStatus::Ok,
            "direct applyEditState Camera WB failed", __FILE__, __LINE__);
        sony2fuji::Pipeline::RenderExecutionOptions directOpts{};
        directOpts.inputType = sony2fuji::RenderInputType::Raw;
        directOpts.inputPath = calStr;
        directOpts.intent = sony2fuji::RenderIntent::Final;
        directOpts.sizeMode = sony2fuji::RenderSizeMode::Native;
        directOpts.outputTarget = sony2fuji::RenderOutputTarget::Buffer;
        directOpts.outputFormat = sony2fuji::RenderOutputFormat::RGBA8;
        sony2fuji::OwnedPixelBuffer directBuf;
        const bool directOk = directPipe.renderWithOptions(directOpts, nullptr, &directBuf, nullptr) == sony2fuji::RenderStatus::Ok &&
                              directBuf.data != nullptr;
        const std::vector<uint8_t> directBytes = directOk
            ? std::vector<uint8_t>(static_cast<const uint8_t*>(directBuf.data),
                                   static_cast<const uint8_t*>(directBuf.data) + directBuf.sizeBytes)
            : std::vector<uint8_t>{};
        std::free(directBuf.data);
        directBuf.data = nullptr;
        require(directOk && directBytes == bufferBytes(calNeutralBuf.value),
            "Camera WB without master_recipe must ignore non-neutral temperature/tint", __FILE__, __LINE__);
    }
}

void testHdrCanonicalEditStateParityAndCameraRaw(const TempDir& dir) {
    constexpr uint32_t kW = 32;
    constexpr uint32_t kH = 24;
    std::vector<float> hdrPixels(static_cast<size_t>(kW) * kH * 3);
    std::vector<float> sdrPixels(static_cast<size_t>(kW) * kH * 3);
    for (uint32_t y = 0; y < kH; ++y) {
        for (uint32_t x = 0; x < kW; ++x) {
            const size_t i = (static_cast<size_t>(y) * kW + x) * 3;
            const float v = 0.15f + 0.02f * static_cast<float>(x);
            hdrPixels[i + 0] = v * 2.2f;
            hdrPixels[i + 1] = v * 1.9f;
            hdrPixels[i + 2] = v * 1.6f;
            sdrPixels[i + 0] = std::min(1.0f, v * 0.9f);
            sdrPixels[i + 1] = std::min(1.0f, v * 0.8f);
            sdrPixels[i + 2] = std::min(1.0f, v * 0.7f);
        }
    }

    HdrPairGuard src;
    src.value.hdr = hdrInit<sony2fuji_hdr_buffer_v1>();
    src.value.hdr.data = hdrPixels.data();
    src.value.hdr.width = kW;
    src.value.hdr.height = kH;
    src.value.hdr.stride_bytes = kW * 12u;
    src.value.hdr.size_bytes = hdrPixels.size() * sizeof(float);
    src.value.hdr.pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
    src.value.hdr.color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
    src.value.hdr.content_headroom = 4.0f;
    src.value.hdr.headroom_kind = SONY2FUJI_HDR_HEADROOM_DECLARED;
    src.value.sdr = src.value.hdr;
    src.value.sdr.data = sdrPixels.data();
    src.value.sdr.content_headroom = 1.0f;
    src.value.native_width = kW;
    src.value.native_height = kH;
    src.value.output_native_width = kW;
    src.value.output_native_height = kH;
    src.value.orientation_applied = 1;
    src.value.source_intent = src.value.render_intent = SONY2FUJI_INTENT_FINAL;
    src.value.source_headroom = 4.0f;
    src.value.source_headroom_kind = SONY2FUJI_HDR_HEADROOM_DECLARED;

    sony2fuji_hdr_request_v9 req9{};
    auto& base1 = req9.base.base.base.base.base.base.base.base;
    auto& tone2 = req9.base.base.base.base.base.base.base;
    auto& color3 = req9.base.base.base.base.base.base;
    auto& rend4 = req9.base.base.base.base.base;
    auto& fx5 = req9.base.base.base.base;
    auto& det6 = req9.base.base.base;
    auto& ch8 = req9.base;

    base1.version = 1;
    base1.struct_size = sizeof(req9);
    base1.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_V2_GRADING_CURVE_VERSION;
    base1.intent = SONY2FUJI_INTENT_FINAL;
    base1.long_edge = 0;
    base1.exposure_ev = 0.4f;
    base1.temperature = 6800.0f;
    base1.tint = 8.0f;
    base1.contrast = (1.10f - 1.0f) * 100.0f;
    base1.highlights = -25.0f;
    base1.shadows = 20.0f;
    base1.saturation = (1.15f - 1.0f) * 100.0f;
    base1.crop_width = 0.9f;
    base1.crop_height = 0.85f;
    base1.crop_x = 0.05f;
    base1.crop_y = 0.05f;
    base1.quarter_turns = 1;
    tone2.black_point = 5.0f;
    tone2.white_point = -5.0f;
    tone2.curve_strength = 0.0f;
    tone2.curve.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
    tone2.curve.struct_size = sizeof(tone2.curve);
    tone2.curve.mode = SONY2FUJI_CURVE_CUSTOM;
    tone2.curve.count = 3;
    tone2.curve.points[0] = {0.0, 0.03};
    tone2.curve.points[1] = {0.5, 0.55};
    tone2.curve.points[2] = {1.0, 0.97};
    color3.vibrance = 12.0f;
    color3.hsl.version = SONY2FUJI_HSL_CONFIG_VERSION;
    color3.hsl.struct_size = sizeof(color3.hsl);
    color3.hsl.hue[0] = 6.0f;
    color3.grading.version = SONY2FUJI_COLOR_GRADING_CONFIG_VERSION;
    color3.grading.struct_size = sizeof(color3.grading);
    color3.grading.shadows_hue = 210.0f;
    color3.grading.shadows_saturation = 15.0f;
    rend4.peak_limit_ev = 3.0f;
    rend4.sdr_exposure_ev = 0.1f;
    rend4.sdr_contrast = 5.0f;
    rend4.sdr_saturation = -4.0f;
    fx5.effects.version = SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION;
    fx5.effects.struct_size = sizeof(fx5.effects);
    fx5.effects.vignette_midpoint = 50.0f;
    fx5.effects.vignette_feather = 50.0f;
    fx5.effects.grain_size = 25.0f;
    fx5.effects.grain_roughness = 50.0f;
    fx5.effects.vignette_amount = -10.0f;
    det6.sharpening = 0.4f;
    det6.clarity = 0.1f;
    det6.dehaze = 0.05f;
    det6.denoise = 0.0f;
    for (auto& c : ch8.channels) {
        c.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
        c.struct_size = sizeof(c);
        c.mode = SONY2FUJI_CURVE_LEGACY;
    }
    ch8.channels[0].mode = SONY2FUJI_CURVE_CUSTOM;
    ch8.channels[0].count = 2;
    ch8.channels[0].points[0] = {0.0, 0.02};
    ch8.channels[0].points[1] = {1.0, 0.98};
    req9.curve_apply_to_luminosity = 1;
    req9.output_sharpening = SONY2FUJI_OUTPUT_SHARPENING_LOW;
    req9.parametric_curve = {
        SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION, sizeof(req9.parametric_curve),
        -10.0f, 5.0f, -4.0f, 8.0f, 0.25f, 0.5f, 0.75f, 0u
    };
    req9.grading_v2 = {
        SONY2FUJI_COLOR_GRADING_V2_CONFIG_VERSION, sizeof(req9.grading_v2),
        210.0f, 15.0f, -3.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
        15.0f, 6.0f, 1.0f, 60.0f, 10.0f
    };

    const std::string hdrJson = Json({
        {"schema_version", 16},
        {"processing", {{"family", "rawlab_hdr"}, {"version", 9}, {"quality", "standard"}}},
        {"edits", {
            {"exposure", {{"ev", 0.4}}},
            {"white_balance", {{"mode", "relative"}, {"relative_temperature", 6800.0}, {"relative_tint", 8.0}}},
            {"tone", {
                {"contrast", 1.10},
                {"saturation", 1.15},
                {"highlights", 0.25},
                {"shadows", 0.20},
                {"s_curve", 0.0},
                {"black_point", 0.05},
                {"white_point", -0.05},
                {"curve", {
                    {"mode", "custom"},
                    {"points", {{0.0, 0.03}, {0.5, 0.55}, {1.0, 0.97}}},
                    {"apply_to_luminosity", true},
                    {"parametric", {
                        {"highlights", -10.0}, {"lights", 5.0}, {"darks", -4.0}, {"shadows", 8.0},
                        {"split_shadow", 0.25}, {"split_midtone", 0.5}, {"split_highlight", 0.75}
                    }},
                    {"channels", {
                        {"red", {{"mode", "custom"}, {"points", {{0.0, 0.02}, {1.0, 0.98}}}}}
                    }}
                }}
            }},
            {"color", {{"vibrance", 0.12}}},
            {"hsl", {{"hue", {6, 0, 0, 0, 0, 0, 0, 0}}}},
            {"color_grading", {
                {"shadows", {{"hue", 210.0}, {"saturation", 15.0}, {"luminance", -3.0}}},
                {"global", {{"hue", 15.0}, {"saturation", 6.0}, {"luminance", 1.0}}},
                {"blending", 60.0},
                {"balance", 10.0}
            }},
            {"rendition", {{"peak_limit_ev", 3.0}, {"sdr_exposure_ev", 0.1}, {"sdr_contrast", 0.05}, {"sdr_saturation", -0.04}}},
            {"effects", {{"vignette_amount", -10.0}}},
            {"detail", {{"sharpening", 0.4}, {"clarity", 0.1}, {"dehaze", 0.05}, {"denoise", 0.0}}},
            {"geometry", {
                {"crop", {{"x", 0.05}, {"y", 0.05}, {"width", 0.9}, {"height", 0.85}}},
                {"quarter_turns", 1}
            }}
        }},
        {"output", {{"output_sharpening", "low"}}}
    }).dump();

    SessionGuard hdrSess;
    auto diag = hdrInit<sony2fuji_hdr_diagnostic_v1>();

    // Geometry size parity.
    uint32_t lw = 0, lh = 0, jw = 0, jh = 0;
    require(sony2fuji_hdr_geometry_size(kW, kH, &base1, &lw, &lh, &diag) == SONY2FUJI_STATUS_OK &&
            sony2fuji_hdr_geometry_size_json(kW, kH, nullptr, hdrJson.c_str(), &jw, &jh, &diag) == SONY2FUJI_STATUS_OK &&
            lw == jw && lh == jh,
        "hdr_geometry_size_json parity mismatch", __FILE__, __LINE__);

    // Full render parity.
    HdrPairGuard legacyOut, jsonOut;
    sony2fuji_hdr_render_options_v1 execOpts{SONY2FUJI_HDR_RENDER_OPTIONS_V1_VERSION, sizeof(execOpts), SONY2FUJI_INTENT_FINAL, 0u};
    require(sony2fuji_hdr_render(hdrSess.ptr, &src.value, &base1, &legacyOut.value, &diag) == SONY2FUJI_STATUS_OK &&
            sony2fuji_hdr_render_json(hdrSess.ptr, &src.value, &execOpts, hdrJson.c_str(), &jsonOut.value, &diag) == SONY2FUJI_STATUS_OK,
        "hdr_render_json failed", __FILE__, __LINE__);
    require(legacyOut.value.hdr.width == jsonOut.value.hdr.width &&
            legacyOut.value.hdr.height == jsonOut.value.hdr.height &&
            std::memcmp(legacyOut.value.hdr.data, jsonOut.value.hdr.data, legacyOut.value.hdr.size_bytes) == 0 &&
            std::memcmp(legacyOut.value.sdr.data, jsonOut.value.sdr.data, legacyOut.value.sdr.size_bytes) == 0,
        "hdr_render_json pixels must match legacy hdr_render_v9 bit-for-bit", __FILE__, __LINE__);

    // ROI source bounds + render ROI parity.
    auto roi = hdrInit<sony2fuji_hdr_roi_v1>();
    roi.norm_x0 = 0.2; roi.norm_y0 = 0.2; roi.norm_x1 = 0.8; roi.norm_y1 = 0.8; roi.max_output_long_edge = 128;
    auto lb = hdrInit<sony2fuji_hdr_roi_source_bounds_v1>();
    auto jb = hdrInit<sony2fuji_hdr_roi_source_bounds_v1>();
    require(sony2fuji_hdr_roi_source_bounds(kW, kH, &base1, &roi, &lb, &diag) == SONY2FUJI_STATUS_OK &&
            sony2fuji_hdr_roi_source_bounds_json(kW, kH, &execOpts, hdrJson.c_str(), &roi, &jb, &diag) == SONY2FUJI_STATUS_OK &&
            lb.source_x0 == jb.source_x0 && lb.source_y0 == jb.source_y0 &&
            lb.source_x1 == jb.source_x1 && lb.source_y1 == jb.source_y1 &&
            lb.output_width == jb.output_width && lb.output_height == jb.output_height,
        "hdr_roi_source_bounds_json parity mismatch", __FILE__, __LINE__);

    HdrPairGuard legacyRoiOut, jsonRoiOut;
    auto lRoiRes = hdrInit<sony2fuji_hdr_roi_result_v1>();
    auto jRoiRes = hdrInit<sony2fuji_hdr_roi_result_v1>();
    require(sony2fuji_hdr_render_roi(hdrSess.ptr, &src.value, &base1, &roi, &legacyRoiOut.value, &lRoiRes, &diag) == SONY2FUJI_STATUS_OK &&
            sony2fuji_hdr_render_roi_json(hdrSess.ptr, &src.value, &execOpts, hdrJson.c_str(), &roi, &jsonRoiOut.value, &jRoiRes, &diag) == SONY2FUJI_STATUS_OK,
        "hdr_render_roi_json failed", __FILE__, __LINE__);
    require(std::memcmp(legacyRoiOut.value.hdr.data, jsonRoiOut.value.hdr.data, legacyRoiOut.value.hdr.size_bytes) == 0,
        "hdr_render_roi_json pixels mismatch", __FILE__, __LINE__);

    // HSL probe JSON parity.
    HslProbeGuard lProbe, jProbe;
    require(sony2fuji_hdr_create_hsl_probe(hdrSess.ptr, &src.value, &base1, 1u, 1u, &lProbe.ptr, &diag) == SONY2FUJI_STATUS_OK &&
            sony2fuji_hdr_create_hsl_probe_json(hdrSess.ptr, &src.value, &execOpts, hdrJson.c_str(), 1u, 1u, &jProbe.ptr, &diag) == SONY2FUJI_STATUS_OK,
        "hdr_create_hsl_probe_json failed", __FILE__, __LINE__);
    sony2fuji_hsl_probe_query hq{SONY2FUJI_HSL_PROBE_VERSION, sizeof(hq), 1u, 1u, 0.5f, 0.5f};
    sony2fuji_hsl_probe_result hrL{}, hrJ{};
    require(sony2fuji_hsl_probe_sample(lProbe.ptr, &hq, &hrL) == SONY2FUJI_STATUS_OK &&
            sony2fuji_hsl_probe_sample(jProbe.ptr, &hq, &hrJ) == SONY2FUJI_STATUS_OK &&
            std::memcmp(hrL.rgb, hrJ.rgb, sizeof(hrL.rgb)) == 0,
        "hdr_create_hsl_probe_json sample mismatch", __FILE__, __LINE__);

    // Camera RAW decode & ROI JSON with camera_development.
    const fs::path hdrDng = dir.path / "hdr_cam.dng";
    writeSyntheticDng(hdrDng, true, {{{1, 2}, {1, 1}, {2, 3}}});
    const std::string hdrDngStr = hdrDng.string();

    auto dev1 = hdrInit<sony2fuji_hdr_camera_development_v1>();
    dev1.white_balance = SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE;
    dev1.temperature = 5400.0f;
    dev1.tint = 10.0f;
    dev1.exposure_reference = SONY2FUJI_HDR_CAMERA_EXPOSURE_SENSOR;
    dev1.fbdd_level = 1;

    auto decOpts = hdrInit<sony2fuji_hdr_decode_options_v1>();
    decOpts.intent = SONY2FUJI_INTENT_FINAL;

    const std::string camDevJson = Json({
        {"schema_version", 16},
        {"processing", {{"family", "rawlab_hdr"}, {"version", 9}, {"quality", "standard"}}},
        {"camera_development", {
            {"wb_mode", "temperature"},
            {"temperature", 5400.0},
            {"tint", 10.0},
            {"sensor_exposure", true},
            {"fbdd_level", 1},
            {"processing_version", 3}
        }},
        {"edits", {
            {"exposure", {{"ev", 0.25}}},
            {"white_balance", {{"mode", "relative"}, {"relative_temperature", 6500.0}, {"relative_tint", 0.0}}}
        }}
    }).dump();

    HdrPairGuard decLegacy, decJson;
    require(sony2fuji_hdr_decode_camera_raw_with_development(hdrSess.ptr, hdrDngStr.c_str(), &decOpts, &dev1, &decLegacy.value, &diag) == SONY2FUJI_STATUS_OK &&
            sony2fuji_hdr_decode_camera_raw_json(hdrSess.ptr, hdrDngStr.c_str(), &decOpts, camDevJson.c_str(), &decJson.value, &diag) == SONY2FUJI_STATUS_OK,
        "hdr_decode_camera_raw_json failed", __FILE__, __LINE__);
    require(decLegacy.value.hdr.width == decJson.value.hdr.width &&
            decLegacy.value.hdr.height == decJson.value.hdr.height,
        "hdr_decode_camera_raw_json dimension mismatch", __FILE__, __LINE__);

    HdrPairGuard camRoiOut;
    auto camRoiRes = hdrInit<sony2fuji_hdr_roi_result_v1>();
    require(sony2fuji_hdr_render_camera_raw_roi_json(hdrSess.ptr, hdrDngStr.c_str(), &execOpts, camDevJson.c_str(),
                                                     &roi, &camRoiOut.value, &camRoiRes, &diag) == SONY2FUJI_STATUS_OK &&
            camRoiOut.value.hdr.data != nullptr,
        "hdr_render_camera_raw_roi_json failed", __FILE__, __LINE__);
}

void testCameraDevelopmentLensFlagsContract(const TempDir& dir) {
    using namespace sony2fuji;
    std::string err;
    CanonicalEditState state;

    auto parseCamDev = [&](const Json& camDev) {
        const std::string doc = Json({{"camera_development", camDev}}).dump();
        require(parseCanonicalEditState(doc, state, err, {RecipeParseMode::SessionState, true}),
            ("parseCanonicalEditState failed for camera_development: " + err).c_str(), __FILE__, __LINE__);
    };

    // 1. Boolean lens_* keys must map to exact C ABI bitmask constants (1=distortion, 2=tca, 4=auto_crop, 8=vignetting).
    parseCamDev({
        {"lens_distortion", false},
        {"lens_tca", false},
        {"lens_vignetting", true},
        {"lens_auto_crop", false}
    });
    require(state.hdr.cameraDevelopment.lensFlags() == SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING &&
            state.toCameraRawDevSpec(false, 0, true).lensFlags == SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING,
        "lens_vignetting=true, lens_auto_crop=false must map to SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING (8)",
        __FILE__, __LINE__);

    parseCamDev({
        {"lens_distortion", true},
        {"lens_tca", false},
        {"lens_vignetting", false},
        {"lens_auto_crop", true}
    });
    require(state.hdr.cameraDevelopment.lensFlags() ==
                (SONY2FUJI_HDR_CAMERA_LENS_DISTORTION | SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP),
        "lens_distortion=true, lens_auto_crop=true must map to DISTORTION|AUTO_CROP (5)",
        __FILE__, __LINE__);

    parseCamDev({
        {"lens_distortion", false},
        {"lens_tca", false},
        {"lens_vignetting", false},
        {"lens_auto_crop", true}
    });
    require(state.hdr.cameraDevelopment.lensFlags() == 0u,
        "lens_auto_crop alone without active correction must produce lensFlags() == 0",
        __FILE__, __LINE__);

    parseCamDev({
        {"lens_distortion", true},
        {"lens_tca", true},
        {"lens_vignetting", true},
        {"lens_auto_crop", true}
    });
    require(state.hdr.cameraDevelopment.lensFlags() ==
                (SONY2FUJI_HDR_CAMERA_LENS_DISTORTION | SONY2FUJI_HDR_CAMERA_LENS_TCA |
                 SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP | SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING),
        "all four lens_* flags must map to bits 1|2|4|8 (15)",
        __FILE__, __LINE__);

    // 2. Integer lens_flags must decode bits 4 (auto_crop) and 8 (vignetting) identically to sony2fuji_hdr.h.
    parseCamDev({
        {"lens_flags", SONY2FUJI_HDR_CAMERA_LENS_DISTORTION | SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP}
    });
    require(state.hdr.cameraDevelopment.lensDistortion &&
            !state.hdr.cameraDevelopment.lensTca &&
            state.hdr.cameraDevelopment.lensAutoCrop &&
            !state.hdr.cameraDevelopment.lensVignetting &&
            state.hdr.cameraDevelopment.lensFlags() ==
                (SONY2FUJI_HDR_CAMERA_LENS_DISTORTION | SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP),
        "integer lens_flags bit 4 must decode as lensAutoCrop, not lensVignetting",
        __FILE__, __LINE__);

    parseCamDev({
        {"lens_flags", SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING}
    });
    require(!state.hdr.cameraDevelopment.lensDistortion &&
            !state.hdr.cameraDevelopment.lensTca &&
            !state.hdr.cameraDevelopment.lensAutoCrop &&
            state.hdr.cameraDevelopment.lensVignetting &&
            state.hdr.cameraDevelopment.lensFlags() == SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING,
        "integer lens_flags bit 8 must decode as lensVignetting, not lensAutoCrop",
        __FILE__, __LINE__);

    // 3. End-to-end decodeCameraRaw parity: lens_vignetting=true, lens_auto_crop=false must reach lens DB check
    // (UNSUPPORTED / CAMERA_DEVELOPMENT), NOT fail hdr::decodeCameraRaw validation as invalid autoCrop-only bit 4!
    const fs::path hdrDng = dir.path / "hdr_lens_flags.dng";
    writeSyntheticDng(hdrDng, true, {{{1, 2}, {1, 1}, {2, 3}}});
    const std::string hdrDngStr = hdrDng.string();

    SessionGuard hdrSess;
    auto decOpts = hdrInit<sony2fuji_hdr_decode_options_v1>();
    decOpts.intent = SONY2FUJI_INTENT_FINAL;

    auto devVigOnly = hdrInit<sony2fuji_hdr_camera_development_v1>();
    devVigOnly.lens_flags = SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING;

    const std::string vigOnlyJson = Json({
        {"camera_development", {
            {"lens_distortion", false},
            {"lens_tca", false},
            {"lens_vignetting", true},
            {"lens_auto_crop", false}
        }}
    }).dump();

    HdrPairGuard legacyPair, jsonPair;
    auto legacyDiag = hdrInit<sony2fuji_hdr_diagnostic_v1>();
    auto jsonDiag = hdrInit<sony2fuji_hdr_diagnostic_v1>();
    const auto legacyStatus = sony2fuji_hdr_decode_camera_raw_with_development(
        hdrSess.ptr, hdrDngStr.c_str(), &decOpts, &devVigOnly, &legacyPair.value, &legacyDiag);
    const auto jsonStatus = sony2fuji_hdr_decode_camera_raw_json(
        hdrSess.ptr, hdrDngStr.c_str(), &decOpts, vigOnlyJson.c_str(), &jsonPair.value, &jsonDiag);
    require(legacyStatus == SONY2FUJI_STATUS_UNSUPPORTED &&
            legacyDiag.reason == SONY2FUJI_HDR_REASON_CAMERA_DEVELOPMENT &&
            jsonStatus == legacyStatus &&
            jsonDiag.reason == legacyDiag.reason &&
            jsonDiag.field == legacyDiag.field,
        "decode_camera_raw_json with lens_vignetting=true, lens_auto_crop=false must match legacy VIGNETTING=8",
        __FILE__, __LINE__);

    // 4. wb_mode="as_shot" with non-zero temperature/tint must zero them in toCameraRawDevSpec and match legacy AsShot decode.
    auto devAsShot = hdrInit<sony2fuji_hdr_camera_development_v1>();
    devAsShot.white_balance = SONY2FUJI_HDR_CAMERA_WB_AS_SHOT;
    devAsShot.temperature = 0.0f;
    devAsShot.tint = 0.0f;
    const std::string asShotWithTempJson = Json({
        {"camera_development", {
            {"wb_mode", "as_shot"},
            {"temperature", 6500.0},
            {"tint", 5.0}
        }}
    }).dump();
    HdrPairGuard asShotLegacyPair, asShotJsonPair;
    auto asShotLegacyDiag = hdrInit<sony2fuji_hdr_diagnostic_v1>();
    auto asShotJsonDiag = hdrInit<sony2fuji_hdr_diagnostic_v1>();
    const auto asShotLegacyStatus = sony2fuji_hdr_decode_camera_raw_with_development(
        hdrSess.ptr, hdrDngStr.c_str(), &decOpts, &devAsShot, &asShotLegacyPair.value, &asShotLegacyDiag);
    const auto asShotJsonStatus = sony2fuji_hdr_decode_camera_raw_json(
        hdrSess.ptr, hdrDngStr.c_str(), &decOpts, asShotWithTempJson.c_str(), &asShotJsonPair.value, &asShotJsonDiag);
    require(asShotLegacyStatus == SONY2FUJI_STATUS_OK &&
            asShotJsonStatus == SONY2FUJI_STATUS_OK &&
            asShotLegacyPair.value.hdr.size_bytes == asShotJsonPair.value.hdr.size_bytes &&
            std::memcmp(asShotLegacyPair.value.hdr.data, asShotJsonPair.value.hdr.data, asShotLegacyPair.value.hdr.size_bytes) == 0,
        "decode_camera_raw_json with wb_mode=as_shot + non-zero temperature/tint must match legacy AsShot decode",
        __FILE__, __LINE__);

    const std::string missingDngStr = (dir.path / "missing_dummy.dng").string();
    HdrPairGuard missingLegacyPair, missingJsonPair;
    auto missingLegacyDiag = hdrInit<sony2fuji_hdr_diagnostic_v1>();
    auto missingJsonDiag = hdrInit<sony2fuji_hdr_diagnostic_v1>();
    const auto missingLegacyStatus = sony2fuji_hdr_decode_camera_raw_with_development(
        hdrSess.ptr, missingDngStr.c_str(), &decOpts, &devAsShot, &missingLegacyPair.value, &missingLegacyDiag);
    const auto missingJsonStatus = sony2fuji_hdr_decode_camera_raw_json(
        hdrSess.ptr, missingDngStr.c_str(), &decOpts, asShotWithTempJson.c_str(), &missingJsonPair.value, &missingJsonDiag);
    require(missingLegacyStatus != SONY2FUJI_STATUS_INVALID_ARGUMENT &&
            missingJsonStatus == missingLegacyStatus &&
            missingJsonDiag.reason == missingLegacyDiag.reason &&
            missingJsonDiag.field == missingLegacyDiag.field,
        "decode_camera_raw_json with wb_mode=as_shot on missing path must match legacy AsShot failure, not INVALID_ARGUMENT",
        __FILE__, __LINE__);

    // 5. lens_profile_id with all lens correction toggles disabled (lensFlags == 0) must clear lensProfileId
    //    in toCameraRawDevSpec and match legacy zero-lens-flags decode (not INVALID_ARGUMENT).
    const std::string disabledLensWithProfileJson = Json({
        {"camera_development", {
            {"lens_distortion", false},
            {"lens_tca", false},
            {"lens_vignetting", false},
            {"lens_profile_id", "sony-fe-35"}
        }}
    }).dump();
    require(parseCanonicalEditState(disabledLensWithProfileJson, state, err, {RecipeParseMode::SessionState, true}) &&
            state.toCameraRawDevSpec(false, 0, true).lensFlags == 0u &&
            state.toCameraRawDevSpec(false, 0, true).lensProfileId == nullptr,
        "toCameraRawDevSpec must clear lensProfileId when lensFlags == 0",
        __FILE__, __LINE__);
    HdrPairGuard disabledLensPair;
    auto disabledLensDiag = hdrInit<sony2fuji_hdr_diagnostic_v1>();
    const auto disabledLensStatus = sony2fuji_hdr_decode_camera_raw_json(
        hdrSess.ptr, hdrDngStr.c_str(), &decOpts, disabledLensWithProfileJson.c_str(), &disabledLensPair.value, &disabledLensDiag);
    require(disabledLensStatus == SONY2FUJI_STATUS_OK &&
            disabledLensPair.value.hdr.size_bytes == asShotLegacyPair.value.hdr.size_bytes &&
            std::memcmp(disabledLensPair.value.hdr.data, asShotLegacyPair.value.hdr.data, asShotLegacyPair.value.hdr.size_bytes) == 0,
        "decode_camera_raw_json with lens_profile_id and disabled lens toggles must match legacy zero-lens-flags decode",
        __FILE__, __LINE__);
}

void testFreeEndpointXSessionVersions() {
    using namespace sony2fuji;
    std::string err;
    CanonicalEditState state;
    const Json freeXCurve = {{"mode", "custom"}, {"points", Json::array({Json::array({0.1, 0.0}), Json::array({0.9, 1.0})})}};
    const auto sdr = [&](uint32_t schema) {
        return Json({{"schema_version", schema}, {"edits", {{"tone", {{"curve", freeXCurve}}}}}}).dump();
    };
    const auto hdr = [&](uint32_t schema, uint32_t processing) {
        return Json({
            {"schema_version", schema},
            {"processing", {{"family", "rawlab_hdr"}, {"version", processing}, {"quality", "standard"}}},
            {"edits", {{"tone", {{"curve", {{"mode", "legacy"}, {"points", Json::array()},
                {"channels", {{"green", freeXCurve}}}}}}}}}
        }).dump();
    };
    // 已发布的 SDR 17 / HDR 处理版本 9 只放开端点 y；客户端会话 JSON 遇到端点 x 内移必须写 18 / 19。
    require(parseCanonicalEditState(sdr(18), state, err, {RecipeParseMode::SessionState, true}) &&
            !state.isHdr && state.schemaVersion == 18 && state.toneCurve.points[0].x == 0.1,
        ("SDR session schema 18 must accept free endpoint X: " + err).c_str(), __FILE__, __LINE__);
    require(!parseCanonicalEditState(sdr(17), state, err, {RecipeParseMode::SessionState, true}),
        "SDR session schema 17 must reject free endpoint X", __FILE__, __LINE__);
    require(parseCanonicalEditState(hdr(19, 10), state, err, {RecipeParseMode::SessionState, true}) &&
            state.isHdr && state.hdr.processingVersion == 10 && state.channelCurves[1].points[0].x == 0.1,
        ("HDR session schema 19 / processing 10 must accept free endpoint X: " + err).c_str(), __FILE__, __LINE__);
    require(!parseCanonicalEditState(hdr(16, 9), state, err, {RecipeParseMode::SessionState, true}),
        "HDR session schema 16 / processing 9 must reject free endpoint X", __FILE__, __LINE__);
    require(!parseCanonicalEditState(hdr(16, 10), state, err, {RecipeParseMode::SessionState, true}),
        "HDR schema 16 must not carry processing 10", __FILE__, __LINE__);
}

} // namespace

TEST_MAIN(
    TempDir dir;
    testOptionalFieldsAndStrictSeparation();
    testSdrParityAndStatelessNonLeakage();
    testMasterRecipeWbInCore(dir);
    testHdrCanonicalEditStateParityAndCameraRaw(dir);
    testCameraDevelopmentLensFlagsContract(dir);
    testFreeEndpointXSessionVersions();
    std::cout << "canonical_edit_state_tests passed (" << ::rawlab::test::checkCount() << " checks)\n";
)
