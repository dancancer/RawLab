#include "sony2fuji/ffi/sony2fuji_c.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

namespace {
std::vector<unsigned char> orient(const std::vector<unsigned char>& source, int width, int height, int orientation) {
    const int outWidth = orientation >= 5 ? height : width;
    std::vector<unsigned char> result(source.size());
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        int tx = x, ty = y;
        switch (orientation) {
        case 2: tx = width - 1 - x; break;
        case 3: tx = width - 1 - x; ty = height - 1 - y; break;
        case 4: ty = height - 1 - y; break;
        case 5: tx = y; ty = x; break;
        case 6: tx = height - 1 - y; ty = x; break;
        case 7: tx = height - 1 - y; ty = width - 1 - x; break;
        case 8: tx = y; ty = width - 1 - x; break;
        }
        std::copy_n(source.data() + (y * width + x) * 3, 3, result.data() + (ty * outWidth + tx) * 3);
    }
    return result;
}

struct Session {
    sony2fuji_session* value = nullptr;
    Session() { assert(sony2fuji_session_create(&value) == SONY2FUJI_STATUS_OK); }
    ~Session() { sony2fuji_session_destroy(value); }
};

sony2fuji_request requestFor(const std::vector<unsigned char>& pixels, int width, int height) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    request.input_pixels = pixels.data();
    request.input_width = width; request.input_height = height;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.brightness = request.contrast = request.saturation = 1;
    request.temperature = 6500;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.intent = SONY2FUJI_INTENT_FINAL;
    return request;
}

std::vector<unsigned char> render(sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji_buffer output{};
    assert(sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_OK);
    assert(output.width == request.input_width && output.height == request.input_height);
    const auto* begin = static_cast<const unsigned char*>(output.data);
    std::vector<unsigned char> pixels(begin, begin + output.size_bytes);
    sony2fuji_release_buffer(&output);
    return pixels;
}
}

int main() {
    Session session;
    assert(sony2fuji_session_set_lens_database(session.value, TEST_FIXTURE_DIR "/lenses.xml") == SONY2FUJI_STATUS_OK);
    sony2fuji_lens_metadata metadata{SONY2FUJI_LENS_METADATA_VERSION, sizeof(metadata),
        "RawLab", "Test Camera", "RawLab", "Test 24mm f/2.8", 24, 2.8f, 0, 0, 1};
    assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_OK);
    sony2fuji_lens_correction_config config{SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION, sizeof(config), 0, 0, 1, nullptr};
    assert(sony2fuji_session_set_lens_correction(session.value, &config) == SONY2FUJI_STATUS_OK);
    constexpr int width = 129, height = 97;
    std::vector<unsigned char> pixels(width * height * 3);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        pixels[(y * width + x) * 3] = (x * 3 + y * 7) % 256;
        pixels[(y * width + x) * 3 + 1] = (x * 13 + y * 2) % 256;
        pixels[(y * width + x) * 3 + 2] = (x * 5 + y * 11) % 256;
    }
    auto request = requestFor(pixels, width, height);
    const auto baseline = render(session.value, request);
    assert(baseline == pixels);
    sony2fuji_lens_correction_config_v2 vignette{config, 1};
    vignette.base.version = SONY2FUJI_LENS_CORRECTION_CONFIG_V2_VERSION;
    vignette.base.struct_size = sizeof(vignette);
    assert(sony2fuji_session_set_lens_correction_v2(nullptr, &vignette) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    assert(sony2fuji_session_set_lens_correction_v2(session.value, &vignette) == SONY2FUJI_STATUS_OK);
    const std::vector<unsigned char> flat(width * height * 3, 64);
    const auto brightened = render(session.value, requestFor(flat, width, height));
    assert(brightened[0] > 64 && std::abs(int(brightened[(48 * width + 64) * 3]) - 64) <= 1);
    sony2fuji_lens_report_v2 colorReport{};
    assert(sony2fuji_session_get_lens_report_v2(session.value, &colorReport) == SONY2FUJI_STATUS_OK);
    assert(colorReport.has_vignetting && colorReport.applied_vignetting && !colorReport.base.applied_distortion);
    for (int orientation = 1; orientation <= 8; ++orientation) {
        metadata.source_orientation = orientation;
        assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_OK);
        const auto actual = render(session.value, requestFor(flat, orientation >= 5 ? height : width, orientation >= 5 ? width : height));
        const auto expected = orient(brightened, width, height, orientation);
        for (size_t n = 0; n < actual.size(); ++n) assert(std::abs(int(actual[n]) - int(expected[n])) <= 1);
    }
    metadata.source_orientation = 1;
    assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_OK);
    auto invalidVignette = vignette; invalidVignette.vignetting = 2;
    assert(sony2fuji_session_set_lens_correction_v2(session.value, &invalidVignette) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    // A v1 caller resets the extension rather than inheriting a previous image's color correction.
    assert(sony2fuji_session_set_lens_correction(session.value, &config) == SONY2FUJI_STATUS_OK);
    assert(render(session.value, request) == baseline);
    config.distortion = config.tca = 1;
    assert(sony2fuji_session_set_lens_correction(session.value, &config) == SONY2FUJI_STATUS_OK);
    const auto corrected = render(session.value, request);
    assert(corrected != baseline);
    sony2fuji_lens_report report{};
    assert(sony2fuji_session_get_lens_report(session.value, &report) == SONY2FUJI_STATUS_OK);
    assert(report.state == SONY2FUJI_LENS_MATCHED && report.applied_distortion && report.applied_tca);
    assert(report.crop_scale >= 1);
    const std::string profileID(report.profile.id);
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    assert(render(session.value, request) == corrected);
    request.intent = SONY2FUJI_INTENT_FINAL;

    // The adapters already orient pixels; correction must commute with that orientation.
    for (int orientation = 1; orientation <= 8; ++orientation) {
        metadata.source_orientation = orientation;
        assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_OK);
        const auto input = orient(pixels, width, height, orientation);
        const auto expected = orient(corrected, width, height, orientation);
        const auto actual = render(session.value, requestFor(input, orientation >= 5 ? height : width, orientation >= 5 ? width : height));
        assert(actual.size() == expected.size());
        for (size_t i = 0; i < actual.size(); ++i) assert(std::abs(int(actual[i]) - int(expected[i])) <= 1);
    }
    metadata.source_orientation = 1;

    uint32_t count = 0;
    assert(sony2fuji_session_inspect_lens_metadata(session.value, &metadata, &report, nullptr, 0, &count) == SONY2FUJI_STATUS_OK);
    assert(count == 4 && report.state == SONY2FUJI_LENS_MATCHED);
    std::vector<sony2fuji_lens_profile> profiles(count);
    assert(sony2fuji_session_inspect_lens_metadata(session.value, &metadata, &report, profiles.data(), count, &count) == SONY2FUJI_STATUS_OK);

    std::string cameraName = "Unknown Camera", lensName = "Unknown Lens";
    metadata.camera_model = cameraName.c_str(); metadata.lens_model = lensName.c_str(); metadata.crop_factor = 1;
    config.profile_id = profileID.c_str();
    assert(sony2fuji_session_set_lens_correction(session.value, &config) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_OK);
    cameraName.assign("replaced"); lensName.assign("replaced");
    assert(render(session.value, request) == corrected);
    assert(sony2fuji_session_get_lens_report(session.value, &report) == SONY2FUJI_STATUS_OK);
    assert(std::strcmp(report.camera_model, "Unknown Camera") == 0);
    metadata.camera_model = "Unknown Camera"; metadata.lens_model = "Unknown Lens";

    const auto valid = metadata;
    for (float invalid : {-1.f, std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity()}) {
        metadata = valid; metadata.focal_length = invalid;
        assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
        assert(render(session.value, request) == corrected);
    }
    metadata = valid; metadata.source_orientation = 9;
    assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    metadata = valid; metadata.struct_size = 0;
    assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    metadata = valid; metadata.focal_length = 0;
    assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_OK);
    assert(render(session.value, request) == baseline);
    assert(sony2fuji_session_get_lens_report(session.value, &report) == SONY2FUJI_STATUS_OK);
    assert(report.state == SONY2FUJI_LENS_MISSING_FOCAL_LENGTH);
    metadata = valid; metadata.crop_factor = 0;
    assert(sony2fuji_session_set_display_lens_metadata(session.value, &metadata) == SONY2FUJI_STATUS_OK);
    assert(render(session.value, request) == baseline);
    assert(sony2fuji_session_get_lens_report(session.value, &report) == SONY2FUJI_STATUS_OK);
    assert(report.state == SONY2FUJI_LENS_NO_CAMERA);
    assert(sony2fuji_session_set_display_lens_metadata(session.value, nullptr) == SONY2FUJI_STATUS_OK);
    sony2fuji_buffer output{};
    assert(sony2fuji_process(session.value, &request, &output) == SONY2FUJI_STATUS_UNSUPPORTED);
    assert(sony2fuji_session_get_lens_report(session.value, &report) == SONY2FUJI_STATUS_OK);
    assert(report.state == SONY2FUJI_LENS_UNSUPPORTED_INPUT && !report.applied_distortion);
    config.distortion = config.tca = 0;
    assert(sony2fuji_session_set_lens_correction(session.value, &config) == SONY2FUJI_STATUS_OK);
    assert(render(session.value, request) == baseline);
    std::cout << "Display lens correction, metadata isolation and orientations 1-8 passed\n";
}
