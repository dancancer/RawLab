#include "sony2fuji/raw_processor.h"
#include <libraw/libraw.h>
#include <nlohmann/json.hpp>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace {
using Clock = std::chrono::steady_clock;
double milliseconds(Clock::time_point start, Clock::time_point end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
}

class TimedRaw : public LibRaw {
public:
    TimedRaw() {
        callbacks.pre_interpolate_cb = [](void* context) {
            static_cast<TimedRaw*>(context)->interpolationStart = Clock::now();
        };
        callbacks.post_interpolate_cb = [](void* context) {
            static_cast<TimedRaw*>(context)->interpolationEnd = Clock::now();
        };
    }
    Clock::time_point interpolationStart, interpolationEnd;
};

void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}

nlohmann::json measure(const char* path, int quality) {
    auto raw = std::make_unique<TimedRaw>();
    auto& params = raw->imgdata.params;
    params.use_camera_matrix = 3;
    params.use_camera_wb = 1;
    params.use_auto_wb = 0;
    const auto start = Clock::now();
    require(raw->open_file(path) == LIBRAW_SUCCESS, "open_file failed");
    const auto opened = Clock::now();
    require(raw->unpack() == LIBRAW_SUCCESS && raw->error_count() == 0, "unpack failed");
    raw->adjust_to_raw_inset_crop(3);
    const auto unpacked = Clock::now();
    const auto& metadata = raw->imgdata.idata;
    params.user_qual = metadata.colors == 3 && metadata.filters > 1000 && !metadata.is_foveon ? quality : -1;
    params.output_color = 0;
    params.output_bps = 16;
    params.no_auto_bright = 1;
    params.no_auto_scale = 0;
    params.adjust_maximum_thr = 0;
    params.highlight = 2;
    params.gamm[0] = params.gamm[1] = 1;
    params.bright = 1;
    params.exp_correc = 0;
    // post_interpolate_cb replaces the median branch; production also uses zero passes.
    params.med_passes = 0;
    require(raw->dcraw_process() == LIBRAW_SUCCESS, "dcraw_process failed");
    const auto processed = Clock::now();
    const auto& data = raw->imgdata;
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < size_t(data.sizes.width) * data.sizes.height; ++i)
        for (int c = 0; c < data.idata.colors; ++c) {
            hash = (hash ^ (data.image[i][c] & 255)) * UINT64_C(1099511628211);
            hash = (hash ^ (data.image[i][c] >> 8)) * UINT64_C(1099511628211);
        }
    nlohmann::json result{
        {"quality", quality}, {"width", data.sizes.width}, {"height", data.sizes.height}, {"channels", data.idata.colors},
        {"selected_quality", params.user_qual},
        {"open_ms", milliseconds(start, opened)}, {"unpack_ms", milliseconds(opened, unpacked)},
        {"dcraw_process_ms", milliseconds(unpacked, processed)},
        {"demosaic_and_mix_green_ms", milliseconds(raw->interpolationStart, raw->interpolationEnd)},
        {"image_fnv1a64", std::to_string(hash)}
    };
    raw.reset();
    sony2fuji::RAWProcessor processor;
    const auto coreStart = Clock::now();
    require(processor.loadFile(path) == sony2fuji::ErrorCode::Success, "RAWProcessor load failed");
    const auto loaded = Clock::now();
    sony2fuji::RAWProcessOptions options;
    options.bayerDemosaic = quality == 1 ? sony2fuji::BayerDemosaicMethod::VNG :
        sony2fuji::BayerDemosaicMethod::Legacy;
    sony2fuji::ImageData image;
    require(processor.process(options, image) == sony2fuji::ErrorCode::Success, "core process failed");
    const auto converted = Clock::now();
    image = {};
    options.matchEmbeddedPreviewExposure = true;
    const auto previewStart = Clock::now();
    require(processor.process(options, image) == sony2fuji::ErrorCode::Success, "preview match failed");
    const auto previewEnd = Clock::now();
    result["core_load_ms"] = milliseconds(coreStart, loaded);
    result["core_process_without_preview_ms"] = milliseconds(loaded, converted);
    result["core_process_with_preview_ms"] = milliseconds(previewStart, previewEnd);
    result["preview_exposure_ev"] = processor.getPreviewExposureEV();
    return result;
}
}

int main(int argc, char** argv) {
    try {
        require(argc == 4, "usage: raw_decode_benchmark RAW QUALITY(-1|1) REPEATS");
        const int quality = std::stoi(argv[2]), repeats = std::stoi(argv[3]);
        require((quality == -1 || quality == 1) && repeats > 0 && repeats <= 20, "invalid arguments");
        for (int i = 0; i < repeats; ++i) {
            auto result = measure(argv[1], quality);
            result["iteration"] = i;
            std::cout << result.dump() << std::endl;
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
