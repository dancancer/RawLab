#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/lut_parser.h"
#include "core/photo_rendering.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {
int failures = 0;
void check(bool value, const std::string& name) {
    std::cout << (value ? "PASS " : "FAIL ") << name << '\n';
    if (!value) ++failures;
}

std::filesystem::path cube(const std::filesystem::path& dir, const std::string& name,
                           const std::string& gamma, const std::string& gamut, bool swap) {
    const auto path = dir / (name + ".cube");
    std::ofstream out(path);
    out << "#Gamma:" << gamma << "\n#Gamut:" << gamut << "\nLUT_3D_SIZE 2\n";
    for (int b = 0; b < 2; ++b) for (int g = 0; g < 2; ++g) for (int r = 0; r < 2; ++r)
        out << (swap ? b : r) << ' ' << g << ' ' << (swap ? r : b) << '\n';
    return path;
}

sony2fuji_request request(const std::array<unsigned char, 12>& pixels) {
    sony2fuji_request r{};
    r.version = SONY2FUJI_REQUEST_VERSION;
    r.struct_size = sizeof(r);
    r.input_type = SONY2FUJI_INPUT_BUFFER;
    r.input_pixels = pixels.data();
    r.input_width = 4; r.input_height = 1;
    r.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    r.input_color_space = SONY2FUJI_COLOR_SRGB;
    r.input_is_linear = 1;
    r.brightness = r.contrast = r.saturation = 1;
    r.temperature = 6500;
    r.size_mode = SONY2FUJI_SIZE_NATIVE;
    r.output_target = SONY2FUJI_TARGET_BUFFER;
    r.output_format = SONY2FUJI_OUTPUT_RGB8;
    r.intent = SONY2FUJI_INTENT_FINAL;
    return r;
}

std::vector<unsigned char> render(sony2fuji_session* session, const sony2fuji_request& r,
                                  sony2fuji_gpu_mode mode, const std::string& label) {
    sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(sony2fuji_gpu_config), mode};
    sony2fuji_session_set_gpu_config(session, &config);
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_process(session, &r, &buffer);
    check(status == SONY2FUJI_STATUS_OK && buffer.data && buffer.size_bytes == 12, label);
    std::vector<unsigned char> result;
    if (status == SONY2FUJI_STATUS_OK && buffer.data) {
        auto p = static_cast<unsigned char*>(buffer.data);
        result.assign(p, p + buffer.size_bytes);
    }
    sony2fuji_release_buffer(&buffer);
    return result;
}
}

int main() {
    const auto dir = std::filesystem::temp_directory_path() /
        ("rawlab-srgb-tests-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directory(dir);
    const auto identity = cube(dir, "identity", "sRGB to sRGB", "ITU-R BT.709 to ITU-R BT.709", false);
    const auto swap = cube(dir, "swap", "sRGB to sRGB", "ITU-R BT.709 to ITU-R BT.709", true);
    check(sony2fuji_validate_look(identity.u8string().c_str(), nullptr, nullptr) == SONY2FUJI_STATUS_OK,
          "Explicit display sRGB CUBE is accepted by PHOTO import");
    for (const auto& gamma : {"sRGB to F-Log2", "sRGB to Unknown", "Linear to sRGB"}) {
        auto invalid = cube(dir, std::to_string(gamma[0]) + std::string(gamma), gamma,
                            "ITU-R BT.709 to ITU-R BT.709", false);
        check(sony2fuji_validate_look(invalid.u8string().c_str(), nullptr, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
              "Ambiguous display transfer remains unsupported: " + std::string(gamma));
    }
    auto wrongGamut = cube(dir, "wrong-gamut", "sRGB to sRGB", "F-Gamut to ITU-R BT.709", false);
    check(sony2fuji_validate_look(wrongGamut.u8string().c_str(), nullptr, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
          "Display declaration cannot disguise F-Gamut input");
    auto legacy = cube(dir, "legacy", "F-Log2 to Display", "F-Gamut to ITU-R BT.709", false);
    auto legacyTable = sony2fuji::LUTParser::loadLUT(legacy.u8string());
    check(legacyTable && legacyTable->inputTransfer() == sony2fuji::LUTTransfer::FLog2 &&
          legacyTable->outputTransfer() == sony2fuji::LUTTransfer::Display, "Legacy Display name remains Log-input");

    const std::array<unsigned char, 12> pixels{9, 80, 180, 46, 150, 21, 255, 2, 91, 0, 0, 0};
    sony2fuji_session* session = nullptr;
    check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "Create test session");
    auto r = request(pixels);
    const auto base = render(session, r, SONY2FUJI_GPU_OFF, "CPU neutral baseline");
    const std::string identityPath = identity.u8string(), swapPath = swap.u8string();
    r.lut_path = identityPath.c_str(); r.lut_strength = 1;
    auto same = render(session, r, SONY2FUJI_GPU_OFF, "CPU display identity");
    check(!same.empty() && same == base, "Identity display CUBE applies neutral exactly once");
    r.lut_path = swapPath.c_str();
    for (float strength : {0.f, .5f, 1.f, 2.f}) {
        r.lut_strength = strength;
        const auto actual = render(session, r, SONY2FUJI_GPU_OFF, "CPU display swap at " + std::to_string(strength));
        bool accurate = actual.size() == pixels.size();
        for (size_t i = 0; accurate && i < actual.size(); ++i) {
            const size_t j = i - i % 3 + (2 - i % 3);
            const float neutral = sony2fuji::neutralDisplay(pixels[i] / 255.f);
            const float endpoint = sony2fuji::neutralDisplay(pixels[j] / 255.f);
            const int expected = int(std::clamp(neutral + (endpoint - neutral) * strength, 0.f, 1.f) * 255 + .5f);
            accurate = std::abs(int(actual[i]) - expected) <= 1;
        }
        check(accurate, "Strength blends display endpoints without extra neutral");
#if defined(SONY2FUJI_ENABLE_METAL)
        const auto gpu = render(session, r, SONY2FUJI_GPU_FORCE, "Metal display swap");
        bool parity = gpu.size() == actual.size() && !gpu.empty();
        for (size_t i = 0; parity && i < gpu.size(); ++i)
            parity = std::abs(int(gpu[i]) - actual[i]) <= 2;
        check(parity && sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_METAL,
              "Actual Metal display CUBE agrees with CPU within two DN");
#elif defined(SONY2FUJI_ENABLE_D3D11)
        if (strength > 0) {
            auto fallback = render(session, r, SONY2FUJI_GPU_AUTO, "Unsupported D3D11 display uses Auto fallback");
            check(fallback == actual && sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_CPU,
                  "Auto reports actual CPU fallback");
            sony2fuji_gpu_config forced{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(sony2fuji_gpu_config), SONY2FUJI_GPU_FORCE};
            sony2fuji_session_set_gpu_config(session, &forced);
            sony2fuji_buffer rejected{};
            check(sony2fuji_process(session, &r, &rejected) == SONY2FUJI_STATUS_PROCESSING_ERROR,
                  "Force does not conceal unsupported display path");
            sony2fuji_release_buffer(&rejected);
        }
#endif
    }
    sony2fuji_session_destroy(session);
    std::filesystem::remove_all(dir);
    return failures ? 1 : 0;
}
