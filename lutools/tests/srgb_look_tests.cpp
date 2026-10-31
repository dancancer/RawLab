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
                           const std::string& gamma, const std::string& gamut, bool swap,
                           bool limitedDomain = false) {
    const auto path = dir / (name + ".cube");
    std::ofstream out(path);
    out << "#Gamma:" << gamma << "\n#Gamut:" << gamut << "\nLUT_3D_SIZE 2\n";
    if (limitedDomain) out << "DOMAIN_MIN 0.15 0.20 0.10\nDOMAIN_MAX 0.85 0.80 0.90\n";
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

void checkGPU(sony2fuji_session* session, const sony2fuji_request& r,
              const std::vector<unsigned char>& expected, const std::string& label) {
#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_D3D11)
#if defined(SONY2FUJI_ENABLE_D3D11)
    constexpr auto backend = SONY2FUJI_BACKEND_D3D11;
#else
    constexpr auto backend = SONY2FUJI_BACKEND_METAL;
#endif
    for (auto mode : {SONY2FUJI_GPU_AUTO, SONY2FUJI_GPU_FORCE}) {
        const auto name = label + (mode == SONY2FUJI_GPU_AUTO ? " Auto" : " Force");
        const auto actual = render(session, r, mode, name);
        check(!actual.empty() && sony2fuji_session_get_last_backend(session) == backend,
              name + " completes on the actual photo GPU backend");
        int maximum = 0;
        bool parity = actual.size() == expected.size() && !actual.empty();
        for (size_t i = 0; parity && i < actual.size(); ++i)
            maximum = std::max(maximum, std::abs(int(actual[i]) - expected[i]));
        check(parity && maximum <= 2, name + " agrees with CPU within two DN (max " +
              std::to_string(maximum) + ")");
    }
#endif
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
    sony2fuji_session* gpu = nullptr;
    check(sony2fuji_session_create(&gpu) == SONY2FUJI_STATUS_OK, "Create persistent GPU session");
    auto r = request(pixels);
    const auto base = render(session, r, SONY2FUJI_GPU_OFF, "CPU neutral baseline");
    const std::string identityPath = identity.u8string(), swapPath = swap.u8string();
    r.lut_path = identityPath.c_str(); r.lut_strength = 1;
    auto same = render(session, r, SONY2FUJI_GPU_OFF, "CPU display identity");
    check(!same.empty() && same == base, "Identity display CUBE applies neutral exactly once");
    checkGPU(gpu, r, same, "Display identity");
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
        checkGPU(gpu, r, actual, "Display swap at " + std::to_string(strength));
    }

    const auto domain = cube(dir, "domain", "sRGB to sRGB", "ITU-R BT.709 to ITU-R BT.709", true, true);
    const auto domainPath = domain.u8string();
    r.lut_path = domainPath.c_str();
    for (float strength : {0.f, .5f, 1.f, 2.f}) {
        r.lut_strength = strength;
        const auto expected = render(session, r, SONY2FUJI_GPU_OFF, "CPU limited display domain");
        checkGPU(gpu, r, expected, "Display domain clamp at " + std::to_string(strength));
    }

    for (const auto& path : {swapPath, legacy.u8string(), swapPath, std::string{}}) {
        r.lut_path = path.empty() ? nullptr : path.c_str(); r.lut_strength = 1;
        const auto expected = render(session, r, SONY2FUJI_GPU_OFF, "CPU transfer switch");
        checkGPU(gpu, r, expected, "Cached display/Log/neutral switch " + path);
    }

    std::vector<std::filesystem::path> bundled;
    for (const auto& entry : std::filesystem::directory_iterator(BUNDLED_LOOKS_DIR))
        if (entry.path().extension() == ".cube") bundled.push_back(entry.path());
    std::sort(bundled.begin(), bundled.end());
    check(!bundled.empty(), "Bundled CUBE fixtures are available");
    for (const auto& path : bundled) {
        const auto utf8 = path.u8string();
        r.lut_path = utf8.c_str(); r.lut_strength = 1;
        const auto name = path.filename().u8string();
        const auto expected = render(session, r, SONY2FUJI_GPU_OFF, "CPU bundled " + name);
        checkGPU(gpu, r, expected, "Bundled " + name);
    }

    const auto kodak = (std::filesystem::path(BUNDLED_LOOKS_DIR) / "RawLab_look_2383_sRGB_v1.cube").u8string();
    r.lut_path = kodak.c_str(); r.lut_strength = 1.5f;
    r.exposure_ev = .7f; r.contrast = 1.2f; r.saturation = .8f;
    r.highlights = .3f; r.shadows = -.2f; r.tone_curve = .1f;
    r.noise_reduction = .3f; r.sharpening = .6f;
    sony2fuji_hsl_config hsl{SONY2FUJI_HSL_CONFIG_VERSION, sizeof(hsl), {}, {}, {}};
    hsl.hue[0] = 40; hsl.saturation[3] = -35; hsl.lightness[5] = 15;
    for (auto* target : {session, gpu})
        check(sony2fuji_session_set_hsl(target, &hsl) == SONY2FUJI_STATUS_OK, "Set post-LUT HSL");
    const auto adjusted = render(session, r, SONY2FUJI_GPU_OFF, "CPU Kodak with exposure/tone/HSL/detail");
    checkGPU(gpu, r, adjusted, "Kodak with exposure/tone/HSL/detail");

    r = request(pixels); r.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER; r.input_is_linear = 0;
    r.lut_path = swapPath.c_str(); r.lut_strength = 1;
    const auto rasterCPU = render(session, r, SONY2FUJI_GPU_OFF, "CPU raster with sRGB look");
    const auto rasterAuto = render(gpu, r, SONY2FUJI_GPU_AUTO, "Auto raster with sRGB look");
    check(!rasterAuto.empty() && rasterAuto == rasterCPU &&
          sony2fuji_session_get_last_backend(gpu) == SONY2FUJI_BACKEND_CPU,
          "sRGB look support preserves raster Auto CPU policy");
    sony2fuji_gpu_config forced{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(forced), SONY2FUJI_GPU_FORCE};
    check(sony2fuji_session_set_gpu_config(gpu, &forced) == SONY2FUJI_STATUS_OK, "Force raster config");
    sony2fuji_buffer rejected{};
    check(sony2fuji_process(gpu, &r, &rejected) == SONY2FUJI_STATUS_UNSUPPORTED && !rejected.data,
          "sRGB look support preserves raster Force rejection");
    sony2fuji_release_buffer(&rejected);
    sony2fuji_session_destroy(gpu);
    sony2fuji_session_destroy(session);
    std::filesystem::remove_all(dir);
    return failures ? 1 : 0;
}
