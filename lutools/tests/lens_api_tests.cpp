#include "sony2fuji/ffi/sony2fuji_c.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

int main() {
    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    sony2fuji_lens_correction_config config{SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION, sizeof(config), 0, 0, 1, nullptr};
    assert(sony2fuji_session_set_lens_correction(session, &config) == SONY2FUJI_STATUS_OK);
    for (int bad : {-1, 2}) {
        auto invalid = config; invalid.distortion = bad;
        assert(sony2fuji_session_set_lens_correction(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
        invalid = config; invalid.tca = bad;
        assert(sony2fuji_session_set_lens_correction(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    }
    auto invalid = config; invalid.struct_size = 0;
    assert(sony2fuji_session_set_lens_correction(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    std::string oversized(512, 'a'); invalid = config; invalid.profile_id = oversized.c_str();
    assert(sony2fuji_session_set_lens_correction(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    sony2fuji_lens_report report{};
    uint32_t count = 999;
    assert(sony2fuji_session_inspect_lens(session, nullptr, &report, nullptr, 0, &count) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    assert(sony2fuji_session_inspect_lens(session, "/no/such/photo.ARW", &report, nullptr, 0, &count) == SONY2FUJI_STATUS_IO_ERROR);
    assert(count == 0);
    assert(sony2fuji_session_inspect_lens(session, TEST_RAW_PATH, &report, nullptr, 0, &count) == SONY2FUJI_STATUS_OK);
    assert(report.state == SONY2FUJI_LENS_OFF && !report.applied_distortion && !report.applied_tca);
    assert(sony2fuji_session_get_lens_report(nullptr, &report) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    std::vector<unsigned char> pixels(12 * 8 * 3, 80);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER; request.input_pixels = pixels.data();
    request.input_width = 12; request.input_height = 8; request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB; request.input_is_linear = 1;
    request.brightness = request.contrast = request.saturation = 1; request.temperature = 6500;
    request.size_mode = SONY2FUJI_SIZE_NATIVE; request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8; request.intent = SONY2FUJI_INTENT_FINAL;
    auto render = [&]() {
        sony2fuji_buffer output{};
        assert(sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_OK);
        const auto* data = static_cast<const unsigned char*>(output.data);
        std::vector<unsigned char> result(data, data + output.size_bytes);
        sony2fuji_release_buffer(&output);
        return result;
    };
    const auto baseline = render();
    config.distortion = config.tca = 1;
#ifdef SONY2FUJI_ENABLE_LENSFUN
    assert(sony2fuji_session_set_lens_database(session, TEST_FIXTURE_DIR "/lenses.xml") == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_lens_correction(session, &config) == SONY2FUJI_STATUS_OK);
    assert(render() == baseline);
    assert(sony2fuji_session_get_lens_report(session, &report) == SONY2FUJI_STATUS_OK);
    assert(report.state == SONY2FUJI_LENS_UNSUPPORTED_INPUT && !report.applied_distortion && !report.applied_tca);
#else
    assert(sony2fuji_session_set_lens_correction(session, &config) == SONY2FUJI_STATUS_UNSUPPORTED);
    assert(sony2fuji_session_set_lens_database(session, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED);
    assert(render() == baseline);
#endif
    const auto rasterRequest = request;
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = TEST_RAW_PATH;
    const auto rawRequest = request;
    const auto rawPixels = render();
    assert(sony2fuji_session_get_lens_report(session, &report) == SONY2FUJI_STATUS_OK);
    const auto rawReport = report;
    assert(rawReport.camera_model[0]);
    request = rasterRequest;
    render();
    request = rawRequest;
    assert(render() == rawPixels);
    assert(sony2fuji_session_get_lens_report(session, &report) == SONY2FUJI_STATUS_OK);
    assert(report.state == rawReport.state && std::strcmp(report.camera_model, rawReport.camera_model) == 0);
    assert(report.applied_distortion == rawReport.applied_distortion && report.applied_tca == rawReport.applied_tca);
    assert(report.crop_scale == rawReport.crop_scale);
    sony2fuji_session_destroy(session);
    std::cout << "Lens ABI validation, buffer isolation and optional build passed\n";
}
