#include "raw_info.h"
#include "core/file_path.h"
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <memory>
#include <new>

namespace sony2fuji {
namespace {
using Json = nlohmann::json;

sony2fuji_status metadataStatus(int code) {
    switch (code) {
        case LIBRAW_IO_ERROR:
        case LIBRAW_INPUT_CLOSED: return SONY2FUJI_STATUS_IO_ERROR;
        case LIBRAW_FILE_UNSUPPORTED: return SONY2FUJI_STATUS_UNSUPPORTED;
        case LIBRAW_UNSUFFICIENT_MEMORY:
        case LIBRAW_MEMPOOL_OVERFLOW: return SONY2FUJI_STATUS_OUT_OF_MEMORY;
        default: return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

template <size_t N> Json text(const char (&value)[N]) {
    const std::string name(value, std::find(value, value + N, '\0'));
    const auto first = name.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return nullptr;
    return name.substr(first, name.find_last_not_of(" \t\r\n") - first + 1);
}

template <typename T> Json positive(T value) {
    return std::isfinite(value) && value > 0 ? Json(value) : Json(nullptr);
}

} // namespace

RawInfoResult inspectRawInfo(const std::string& absoluteUTF8Path) {
    try {
        if (absoluteUTF8Path.empty() || absoluteUTF8Path.find('\0') != std::string::npos ||
            !std::filesystem::u8path(absoluteUTF8Path).is_absolute()) {
            return {SONY2FUJI_STATUS_INVALID_ARGUMENT, "Input path must be absolute UTF-8", nullptr};
        }
        auto raw = std::make_unique<LibRaw>();
        const int code = openRawFile(*raw, absoluteUTF8Path);
        if (code != LIBRAW_SUCCESS) return {metadataStatus(code), libraw_strerror(code), nullptr};
        if (raw->error_count() != 0)
            return {SONY2FUJI_STATUS_PROCESSING_ERROR, libraw_strerror(LIBRAW_DATA_ERROR), nullptr};

        const auto& data = raw->imgdata;
        const auto& levels = data.color.dng_levels;
        // LibRaw 0.22.2 copies the selected IFD's value without its presence bit.
        // The public field remains -999 when absent; an explicit zero is valid.
        const Json baseline = levels.baseline_exposure != -999.f &&
            std::isfinite(levels.baseline_exposure) ? Json(levels.baseline_exposure) : Json(nullptr);
        const Json orientation = data.sizes.flip >= 0 && data.sizes.flip <= 7 ?
            Json(data.sizes.flip) : Json(nullptr);
        Json result = {
            {"input_path", absoluteUTF8Path},
            {"camera", {{"make", text(data.idata.make)}, {"model", text(data.idata.model)}}},
            {"lens", {{"model", text(data.lens.Lens[0] ? data.lens.Lens : data.lens.makernotes.Lens)},
                      {"focal_length_mm", positive(data.other.focal_len)}}},
            {"identified_size", {{"width", positive(data.sizes.width)},
                                 {"height", positive(data.sizes.height)}, {"orientation", orientation}}},
            // SDK Stage3, active crops and subsequent geometry can alter output dimensions.
            {"rendered_size", nullptr},
            {"capture", {{"iso", positive(data.other.iso_speed)}, {"aperture", positive(data.other.aperture)},
                         {"shutter_seconds", positive(data.other.shutter)}, {"exposure_bias_ev", nullptr},
                         {"baseline_exposure_ev", baseline}}},
            // LibRaw's channel multipliers are not a calibrated Kelvin/tint measurement.
            {"as_shot_white_balance", {{"temperature_kelvin", nullptr}, {"tint", nullptr}}}
        };
        return {SONY2FUJI_STATUS_OK, {}, std::move(result)};
    } catch (const std::bad_alloc&) {
        return {SONY2FUJI_STATUS_OUT_OF_MEMORY, libraw_strerror(LIBRAW_UNSUFFICIENT_MEMORY), nullptr};
    } catch (const std::filesystem::filesystem_error& error) {
        return {SONY2FUJI_STATUS_IO_ERROR, error.what(), nullptr};
    }
}

} // namespace sony2fuji
