#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {
template<class T> T init() {
    T value{};
    value.version = 1;
    value.struct_size = sizeof(T);
    return value;
}
void check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
struct Session {
    sony2fuji_session* value = nullptr;
    Session() { check(sony2fuji_session_create(&value) == SONY2FUJI_STATUS_OK, "session creation failed"); }
    ~Session() { sony2fuji_session_destroy(value); }
};
using Clock = std::chrono::steady_clock;
long long elapsed(Clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
}
struct TemporaryDirectory {
    std::filesystem::path path = std::filesystem::temp_directory_path() /
        ("rawlab-camera-hdr-" + std::to_string(Clock::now().time_since_epoch().count()));
    TemporaryDirectory() { check(std::filesystem::create_directory(path), "cannot create test output directory"); }
    ~TemporaryDirectory() { std::error_code error; std::filesystem::remove_all(path, error); }
};
struct Pair {
    sony2fuji_hdr_image_pair_v1 value = init<sony2fuji_hdr_image_pair_v1>();
    ~Pair() { sony2fuji_hdr_release_pair(&value); }
};
}

int main() {
    try {
        const auto fixture = std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng";
        const auto* external = std::getenv("RAWLAB_TEST_CAMERA_HDR");
        const auto* input = external ? external : fixture.c_str();
        auto info = init<sony2fuji_hdr_source_info_v1>();
        auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
        check(sony2fuji_hdr_probe_camera_raw(input, &info, &diagnostic) == SONY2FUJI_STATUS_OK,
              "validated Bayer RAW was rejected");
        check(info.container == SONY2FUJI_HDR_CONTAINER_CAMERA_RAW && info.width > 32 && info.height > 32,
              "RAW probe did not describe the native source");
        auto options = init<sony2fuji_hdr_decode_options_v1>();
        options.intent = SONY2FUJI_INTENT_PREVIEW;
        options.long_edge = external ? 1536 : 32;
        Session session;
        Pair preview;
        sony2fuji_session_set_cancellation_callback(session.value, [](void*) -> int32_t { return 1; }, nullptr);
        check(sony2fuji_hdr_decode_camera_raw(session.value, input, &options, &preview.value, &diagnostic)
                  == SONY2FUJI_STATUS_CANCELLED && !preview.value.owner_token, "cancelled RAW decode published pixels");
        sony2fuji_session_set_cancellation_callback(session.value, nullptr, nullptr);
        auto gpu = init<sony2fuji_gpu_config>();
        gpu.mode = SONY2FUJI_GPU_FORCE;
        check(sony2fuji_session_set_gpu_config(session.value, &gpu) == SONY2FUJI_STATUS_OK,
              "could not configure GPU Force");
        check(sony2fuji_hdr_decode_camera_raw(session.value, input, &options, &preview.value, &diagnostic)
                  == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU,
              "camera RAW HDR silently fell back in GPU Force mode");
        gpu.mode = SONY2FUJI_GPU_AUTO;
        check(sony2fuji_session_set_gpu_config(session.value, &gpu) == SONY2FUJI_STATUS_OK,
              "could not configure GPU Auto");
        auto start = Clock::now();
        check(sony2fuji_hdr_decode_camera_raw(session.value, input, &options, &preview.value, &diagnostic)
                  == SONY2FUJI_STATUS_OK && sony2fuji_session_get_last_backend(session.value) == SONY2FUJI_BACKEND_CPU,
              "RAW preview failed to report its CPU fallback");
        check(std::max(preview.value.hdr.width, preview.value.hdr.height) == options.long_edge && preview.value.is_proxy &&
              preview.value.native_width == info.width && preview.value.native_height == info.height &&
              preview.value.source_headroom_kind == SONY2FUJI_HDR_HEADROOM_UNKNOWN,
              "RAW preview lost native dimensions or claimed full-source measurements");
        const auto previewMs = elapsed(start);
        if (external && std::getenv("RAWLAB_TEST_CAMERA_HDR_PREVIEW_ONLY")) {
            std::cout << "RAW preview " << preview.value.hdr.width << 'x' << preview.value.hdr.height
                      << ", " << previewMs << " ms\n";
            return 0;
        }
        auto request = init<sony2fuji_hdr_request_v1>();
        request.hdr_processing_version = 1;
        request.intent = SONY2FUJI_INTENT_FINAL;
        request.temperature = 6500;
        request.crop_width = request.crop_height = 1;
        Pair rendered;
        check(sony2fuji_hdr_render(session.value, &preview.value, &request, &rendered.value, &diagnostic)
                  == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_PREVIEW_SOURCE,
              "RAW preview was accepted for FINAL rendering");
        std::array<uint8_t, 32> previewIdentity{};
        std::copy_n(preview.value.source_sha256, previewIdentity.size(), previewIdentity.begin());
        sony2fuji_hdr_release_pair(&preview.value);

        options.intent = SONY2FUJI_INTENT_FINAL;
        options.long_edge = 0;
        Pair source;
        start = Clock::now();
        check(sony2fuji_hdr_decode_camera_raw(nullptr, input, &options, &source.value, &diagnostic)
                  == SONY2FUJI_STATUS_OK, "full RAW HDR decode failed");
        check(source.value.hdr.width == info.width && source.value.hdr.height == info.height,
              "full RAW decode lost native dimensions");
        check(external || source.value.source_headroom > 1.05f, "full RAW decode lost the synthetic highlight steps");
        check(std::any_of(previewIdentity.begin(), previewIdentity.end(), [](uint8_t x) { return x != 0; }) &&
              std::equal(previewIdentity.begin(), previewIdentity.end(), source.value.source_sha256),
              "RAW preview and FINAL disagree on original source identity");
        const auto finalMs = elapsed(start);
        const auto* sdr = static_cast<const float*>(source.value.sdr.data);
        check(std::all_of(sdr, sdr + source.value.sdr.size_bytes / sizeof(float),
                          [](float x) { return x >= 0 && x <= 1; }), "SDR base exceeded its output gamut");
        const float headroom = source.value.source_headroom;
        request.exposure_ev = external ? 2 : -1;
        rendered.value = init<sony2fuji_hdr_image_pair_v1>();
        start = Clock::now();
        check(sony2fuji_hdr_render(session.value, &source.value, &request, &rendered.value, &diagnostic)
                  == SONY2FUJI_STATUS_OK, "RAW HDR edit failed");
        if (external) {
            const auto* before = static_cast<const float*>(source.value.hdr.data);
            const auto* after = static_cast<const float*>(rendered.value.hdr.data);
            check(std::equal(before, before + source.value.hdr.size_bytes / sizeof(float), after,
                             [](float a, float b) { return b == 4 * a; }),
                  "RAW edit changed the color ratios or clipped before export");
        } else {
            check(std::abs(rendered.value.hdr.content_headroom - std::max(1.0f, headroom / 2)) < 1e-5f,
                  "user exposure did not move recovered high values by one stop");
        }
        const auto renderMs = elapsed(start);
        auto& exportPair = external ? rendered.value : source.value;
        sony2fuji_hdr_release_pair(external ? &source.value : &rendered.value);
        TemporaryDirectory directory;
        const auto jpeg = (directory.path / "raw-hdr.jpg").u8string();
        auto config = init<sony2fuji_hdr_export_config_v1>();
        config.jpeg_quality = 92;
        config.base_color = SONY2FUJI_HDR_COLOR_SRGB;
        config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP;
        start = Clock::now();
        check(sony2fuji_hdr_export_jpeg(&exportPair, &config, jpeg.c_str(), &diagnostic) == SONY2FUJI_STATUS_OK,
              "RAW HDR gain-map export failed");
        const auto exportMs = elapsed(start);
        if (!external) {
            const auto sdrPath = (directory.path / "raw-sdr.jpg").u8string();
            auto sdrConfig = init<sony2fuji_hdr_sdr_export_config_v1>();
            sdrConfig.output_format = SONY2FUJI_OUTPUT_JPEG;
            sdrConfig.quality = 92;
            check(sony2fuji_hdr_export_sdr(&exportPair, &sdrConfig, sdrPath.c_str(), &diagnostic) == SONY2FUJI_STATUS_OK,
                  "RAW HDR SDR-compatible export failed");
            auto sdrInfo = init<sony2fuji_hdr_source_info_v1>();
            check(sony2fuji_hdr_probe_camera_raw(sdrPath.c_str(), &sdrInfo, &diagnostic) == SONY2FUJI_STATUS_UNSUPPORTED &&
                  diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                  "ordinary JPEG was accepted as a camera RAW source");
        }
        sony2fuji_hdr_release_pair(&exportPair);
        Pair reimport;
        check(sony2fuji_hdr_decode(jpeg.c_str(), &options, &reimport.value, &diagnostic) == SONY2FUJI_STATUS_OK &&
              reimport.value.hdr.width == info.width && reimport.value.hdr.height == info.height &&
              reimport.value.hdr.content_headroom > 1.0f,
              "gain-map JPEG round trip lost native dimensions or HDR highlights");
        std::cout << "RAW " << info.width << "x" << info.height << ", source headroom " << headroom
                  << ", JPEG headroom " << reimport.value.hdr.content_headroom
                  << ", ms preview/final/edit/export " << previewMs << '/' << finalMs << '/'
                  << renderMs << '/' << exportMs << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
