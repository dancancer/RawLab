#include "sony2fuji/ffi/sony2fuji_c.h"
#include <cmath>
#include <iostream>
#include <vector>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>

int main() {
    std::vector<unsigned char> input(256 * 3);
    for (int i = 0; i < 256; ++i) input[i * 3] = input[i * 3 + 1] = input[i * 3 + 2] = i;
    sony2fuji_session* session = nullptr;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return 1;
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = static_cast<sony2fuji_input_type>(2);
    request.input_pixels = input.data();
    request.input_width = 256; request.input_height = 1;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.temperature = 6500;
    request.brightness = request.contrast = request.saturation = 1;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    sony2fuji_buffer output{};
    bool passed = true;
    for (auto exposure : {SONY2FUJI_EXPOSURE_SCENE, SONY2FUJI_EXPOSURE_PREVIEW, SONY2FUJI_EXPOSURE_SENSOR}) {
        sony2fuji_session_set_raw_exposure_mode(session, exposure);
        const auto status = sony2fuji_process(session, &request, &output);
        if (status != SONY2FUJI_STATUS_OK) {
            std::cerr << "FAIL display input rejected: " << status << '\n';
            passed = false;
            break;
        }
        const auto* pixels = static_cast<const unsigned char*>(output.data);
        for (size_t i = 0; i < input.size(); ++i)
            if (pixels[i] != input[i]) passed = false;
        sony2fuji_release_buffer(&output);
    }
    if (!passed) std::cerr << "FAIL display input must round trip without RAW baseline, gamma or neutral curve\n";
    else std::cout << "PASS display input identity in scene/preview/sensor sessions\n";
    request.exposure_ev = 1;
    if (sony2fuji_process(session, &request, &output) != SONY2FUJI_STATUS_OK) passed = false;
    else {
        const auto* pixels = static_cast<const unsigned char*>(output.data);
        const double encoded = 64.0 / 255;
        const double linear = std::pow((encoded + .055) / 1.055, 2.4) * 2;
        const int expected = std::lround((1.055 * std::pow(linear, 1 / 2.4) - .055) * 255);
        if (std::abs(int(pixels[64 * 3]) - expected) > 1) passed = false;
    }
    sony2fuji_release_buffer(&output);
    const unsigned char transparent[] = {255, 40, 20, 127};
    auto alpha = request;
    alpha.input_pixels = transparent;
    alpha.input_pixel_format = SONY2FUJI_PIXEL_RGBA8;
    alpha.input_width = alpha.input_height = 1;
    if (sony2fuji_process(session, &alpha, &output) != SONY2FUJI_STATUS_UNSUPPORTED) {
        std::cerr << "FAIL display buffer must reject transparency instead of dropping alpha\n";
        passed = false;
    }
    sony2fuji_release_buffer(&output);
    const auto look = std::filesystem::temp_directory_path() /
        ("rawlab-protected-look-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + ".cube");
    { std::ofstream file(look); file << "protected look"; }
    const auto path = look.u8string();
    request.output_target = SONY2FUJI_TARGET_FILE;
    request.output_format = SONY2FUJI_OUTPUT_PNG;
    request.output_path = path.c_str(); request.lut_path = path.c_str();
    if (sony2fuji_process(session, &request, nullptr) != SONY2FUJI_STATUS_INVALID_ARGUMENT) passed = false;
    std::ifstream file(look);
    std::string contents((std::istreambuf_iterator<char>(file)), {});
    if (contents != "protected look") passed = false;
    file.close(); std::filesystem::remove(look);
    sony2fuji_session_destroy(session);
    return passed ? 0 : 1;
}
