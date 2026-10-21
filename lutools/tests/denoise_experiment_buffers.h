#pragma once

#include "sony2fuji/color_converter.h"
#include "sony2fuji/processing_version.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#ifdef SONY2FUJI_ENABLE_METAL
#include "gpu/photo_gpu.h"
#endif
#include <libraw/libraw.h>
#include <nlohmann/json.hpp>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace denoise_experiment {
using Json = nlohmann::json;
using sony2fuji::ImageData;
using sony2fuji::RGB;

inline Json writeBuffer(const std::filesystem::path& path, const void* pixels, size_t bytes,
                        const Json& shape, const char* dtype, const char* space, const char* stage) {
    const uint16_t endian = 1;
    static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559);
    if (*reinterpret_cast<const uint8_t*>(&endian) != 1)
        throw std::runtime_error("experiment buffers require a little-endian host");
    if (std::filesystem::exists(path)) throw std::runtime_error("experiment buffer already exists");
    std::ofstream stream(path, std::ios::binary);
    stream.write(static_cast<const char*>(pixels), static_cast<std::streamsize>(bytes));
    stream.close();
    if (!stream) throw std::runtime_error("experiment buffer write failed");
    return {{"path", path.string()}, {"bytes", bytes}, {"shape", shape},
            {"dtype", dtype}, {"space", space}, {"stage", stage}};
}

inline Json writeImage(const std::filesystem::path& directory, const std::string& name,
                       const ImageData& image, const char* space, const char* stage) {
    static_assert(sizeof(RGB) == 3 * sizeof(float));
    return writeBuffer(directory / (name + ".f32"), image.pixels.data(), image.pixels.size() * sizeof(RGB),
                       {image.height, image.width, 3}, "<f4", space, stage);
}

inline Json exportSensor(const std::filesystem::path& directory, const std::string& path,
                         const ImageData& source, bool vng) {
    LibRaw raw;
    raw.imgdata.params.use_camera_wb = 1;
    raw.imgdata.params.use_camera_matrix = 3;
    if (raw.open_file(path.c_str()) != LIBRAW_SUCCESS || raw.unpack() != LIBRAW_SUCCESS)
        throw std::runtime_error("experiment sensor unpack failed");
    raw.adjust_to_raw_inset_crop(3);
    auto& data = raw.imgdata;
    if (data.idata.colors != 3 || !data.idata.filters || data.idata.filters == 9 || !data.rawdata.raw_image)
        return {{"status", "NOT_SUPPORTED_NON_BAYER"}};
    const int width = data.sizes.width, height = data.sizes.height;
    Json metadata = {{"status", "EXPORTED_BAYER"}, {"width", width}, {"height", height},
                     {"raw_width", data.sizes.raw_width}, {"raw_height", data.sizes.raw_height},
                     {"left_margin", data.sizes.left_margin}, {"top_margin", data.sizes.top_margin},
                     {"black", data.color.black}, {"white", data.color.maximum},
                     {"cblack", Json::array()}, {"pattern", {{raw.COLOR(0, 0), raw.COLOR(0, 1)},
                                                          {raw.COLOR(1, 0), raw.COLOR(1, 1)}}}};
    for (int channel = 0; channel < 6; ++channel) metadata["cblack"].push_back(data.color.cblack[channel]);
    if (data.color.cblack[4] && data.color.cblack[5]) {
        const size_t cells = static_cast<size_t>(data.color.cblack[4]) * data.color.cblack[5];
        if (cells > 4096 || !std::all_of(data.color.cblack + 6, data.color.cblack + 6 + cells,
                [&](unsigned value) { return value == data.color.cblack[6]; }))
            return {{"status", "NOT_SUPPORTED_NONUNIFORM_SPATIAL_BLACK_LEVEL"}};
        metadata["uniform_black_table_folded"] = data.color.cblack[6];
        metadata["black"] = data.color.black + data.color.cblack[6];
        metadata["cblack"][4] = metadata["cblack"][5] = 0;
    }
    std::vector<uint16_t> mosaic(static_cast<size_t>(width) * height);
    const size_t pitch = data.sizes.raw_pitch / sizeof(uint16_t);
    for (int y = 0; y < height; ++y)
        std::copy_n(data.rawdata.raw_image + (y + data.sizes.top_margin) * pitch + data.sizes.left_margin,
                    width, mosaic.data() + static_cast<size_t>(y) * width);
    metadata["buffer"] = writeBuffer(directory / "mosaic.u16", mosaic.data(), mosaic.size() * sizeof(uint16_t),
                                     {height, width}, "<u2", "sensor_CFA", "active_before_black_subtraction");
    auto& params = data.params;
    params.half_size = 0;
    params.fbdd_noiserd = 0;
    params.user_qual = vng ? 1 : 11;
    params.use_auto_wb = 0;
    params.output_color = 0;
    params.output_bps = 16;
    params.no_auto_bright = 1;
    params.no_auto_scale = 0;
    params.adjust_maximum_thr = 0;
    params.highlight = 2;
    params.gamm[0] = params.gamm[1] = 1;
    params.bright = 1;
    params.exp_correc = 0;
    if (raw.dcraw_process() != LIBRAW_SUCCESS || !data.image || data.idata.colors != 3 ||
        data.sizes.iwidth != width || data.sizes.iheight != height ||
        !std::isfinite(data.color.pre_mul[1]) || data.color.pre_mul[1] <= 0)
        throw std::runtime_error("unsupported experiment sensor geometry/calibration");
    const int flip = data.sizes.flip;
    if (flip < 0 || flip > 7 || source.width != ((flip & 4) ? height : width) ||
        source.height != ((flip & 4) ? width : height))
        throw std::runtime_error("experiment sensor orientation mismatch: sensor=" +
            std::to_string(width) + "x" + std::to_string(height) + ", flip=" + std::to_string(flip) +
            ", native=" + std::to_string(source.width) + "x" + std::to_string(source.height));
    metadata["flip"] = flip;
    metadata["post_scale_pre_mul"] = Json::array();
    metadata["rgb_cam"] = Json::array();
    for (int channel = 0; channel < 4; ++channel) metadata["post_scale_pre_mul"].push_back(data.color.pre_mul[channel]);
    for (int row = 0; row < 3; ++row)
        metadata["rgb_cam"].push_back({data.color.rgb_cam[row][0], data.color.rgb_cam[row][1], data.color.rgb_cam[row][2]});
    const auto matrix = sony2fuji::ColorConverter::getConversionMatrix(sony2fuji::ColorSpace::sRGB, sony2fuji::ColorSpace::sRGB);
    metadata["native_working_matrix"] = Json::array();
    for (int row = 0; row < 3; ++row)
        metadata["native_working_matrix"].push_back({matrix[row][0], matrix[row][1], matrix[row][2]});
    const float scale = 1.f / (65535.f * data.color.pre_mul[1]);
    float maximum = 0;
    for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x) {
        int row = y, col = x;
        if (flip & 4) std::swap(row, col);
        if (flip & 2) row = height - 1 - row;
        if (flip & 1) col = width - 1 - col;
        const auto& pixel = data.image[static_cast<size_t>(row) * width + col];
        float rgb[3]{};
        for (int channel = 0; channel < 3; ++channel)
            for (int c = 0; c < 3; ++c) rgb[channel] += data.color.rgb_cam[channel][c] * pixel[c] * scale;
        const auto converted = sony2fuji::ColorConverter::applyMatrix(RGB(rgb[0], rgb[1], rgb[2]), matrix);
        const auto& expected = source.at(x, y);
        maximum = std::max({maximum, std::abs(converted.r - expected.r),
                            std::abs(converted.g - expected.g), std::abs(converted.b - expected.b)});
    }
    metadata["independent_native_max_abs"] = maximum;
    if (maximum != 0) throw std::runtime_error("sensor export does not reproduce the frozen native decode");
    return metadata;
}

inline Json exportBuffers(const std::filesystem::path& directory, const ImageData& source,
                          const ImageData& swt, const ImageData* reference,
                          const std::string& rawPath, bool vng, bool displayRequested, sony2fuji::ProcessingVersion processingVersion) {
    if (!std::filesystem::create_directory(directory))
        throw std::runtime_error("experiment directory must not exist");
    Json result = {{"processing", {{"family", "rawlab"}, {"version", static_cast<int>(processingVersion)}, {"quality", "standard"}}},
                   {"buffers", Json::object()}};
    auto& buffers = result["buffers"];
    buffers["source"] = writeImage(directory, "source", source, "linear_sRGB", "native_decode");
    buffers["swt"] = writeImage(directory, "swt", swt, "linear_sRGB", processingVersion == sony2fuji::ProcessingVersion::Legacy ? "frozen_swt_legacy" : "frozen_c5_v2");
    if (reference) buffers["reference"] = writeImage(directory, "reference", *reference, "linear_sRGB", "declared_reference");
    result["sensor"] = rawPath.empty() ? Json{{"status", "NOT_APPLICABLE_SYNTHETIC"}} :
        exportSensor(directory, rawPath, source, vng);
    if (!displayRequested) {
        result["display"] = {{"status", "NOT_REQUESTED"}};
        return result;
    }
#ifdef SONY2FUJI_ENABLE_METAL
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.input_is_linear = 1;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.brightness = request.contrast = request.saturation = 1;
    request.temperature = 6500;
    request.size_mode = SONY2FUJI_SIZE_EXACT;
    request.target_width = swt.width;
    request.target_height = swt.height;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    result["display"] = {{"backend", "Metal"}, {"lut", nullptr}, {"exposure_ev", 0},
                          {"noise_reduction", 0}, {"chroma_denoise", 0}, {"timings_ms", Json::object()}};
    for (const auto& item : std::vector<std::pair<std::string, float>>{
             {"display", 0}, {"display_sharp_05", .5f}, {"display_sharp_1", 1}, {"display_sharp_2", 2}}) {
        request.sharpening = item.second;
        ImageData display;
        const auto start = std::chrono::steady_clock::now();
        if (!sony2fuji::renderPhotoMetal(swt, sony2fuji::ColorSpace::sRGB, request, nullptr,
                                       RGB(1, 1, 1), swt.width, swt.height, display))
            throw std::runtime_error("actual Metal display export failed; no CPU substitution");
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        buffers[item.first] = writeImage(directory, item.first, display, "display_RGB",
                                         item.second == 0 ? "neutral_before_sharpen" : "native_ordinary_sharpen");
        buffers[item.first]["sharpening"] = item.second;
        result["display"]["timings_ms"][item.first] = ms;
    }
#else
    throw std::runtime_error("experiment display export requires a Metal-enabled build");
#endif
    return result;
}
} // namespace denoise_experiment
