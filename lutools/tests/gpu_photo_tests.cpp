#include "sony2fuji/color_converter.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/lut_parser.h"
#include "gpu/photo_gpu.h"
#ifdef SONY2FUJI_ENABLE_D3D11
#include "gpu/d3d11_photo.h"
#endif

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#ifdef _WIN32
#include <process.h>
#define getpid _getpid
#else
#include <unistd.h>
#endif
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const std::string& name) {
    std::cout << (condition ? "PASS " : "FAIL ") << name << '\n';
    if (!condition) {
        ++failures;
    }
}

sony2fuji_request baseRequest(
    const std::vector<unsigned char>& pixels,
    uint32_t width,
    uint32_t height
) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER;
    request.input_pixels = pixels.data();
    request.input_width = width;
    request.input_height = height;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.input_is_linear = 1;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.brightness = 1.0f;
    request.contrast = 1.0f;
    request.saturation = 1.0f;
    request.temperature = 6500.0f;
    request.size_mode = SONY2FUJI_SIZE_EXACT;
    request.target_width = width;
    request.target_height = height;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    return request;
}

sony2fuji::ImageData toLinearImage(
    const std::vector<unsigned char>& pixels,
    uint32_t width,
    uint32_t height
) {
    sony2fuji::ImageData image(static_cast<int>(width), static_cast<int>(height));
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        image.pixels[i] = sony2fuji::RGB(
            pixels[i * 3] / 255.0f,
            pixels[i * 3 + 1] / 255.0f,
            pixels[i * 3 + 2] / 255.0f
        );
    }
    return image;
}

std::vector<unsigned char> encodeRGB8(const sony2fuji::ImageData& image) {
    std::vector<unsigned char> result(image.pixels.size() * 3);
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        const auto& pixel = image.pixels[i];
        result[i * 3] = static_cast<unsigned char>(
            std::clamp(pixel.r, 0.0f, 1.0f) * 255.0f + 0.5f
        );
        result[i * 3 + 1] = static_cast<unsigned char>(
            std::clamp(pixel.g, 0.0f, 1.0f) * 255.0f + 0.5f
        );
        result[i * 3 + 2] = static_cast<unsigned char>(
            std::clamp(pixel.b, 0.0f, 1.0f) * 255.0f + 0.5f
        );
    }
    return result;
}

bool withinTwoDN(
    const std::vector<unsigned char>& gpu,
    const sony2fuji_buffer& cpu,
    size_t* maxDifference
) {
    if (!cpu.data || cpu.size_bytes != gpu.size()) {
        return false;
    }
    const auto* cpuPixels = static_cast<const unsigned char*>(cpu.data);
    size_t maximum = 0;
    for (size_t i = 0; i < gpu.size(); ++i) {
        maximum = std::max(
            maximum,
            static_cast<size_t>(std::abs(static_cast<int>(gpu[i]) - static_cast<int>(cpuPixels[i])))
        );
    }
    if (maxDifference) {
        *maxDifference = maximum;
    }
    return maximum <= 2;
}

std::filesystem::path makePhotoLUT(const std::string& input = "FLog2", const std::string& output = "ETERNA") {
    const auto path = std::filesystem::temp_directory_path() /
        ("rawtools-gpu-photo-" + std::to_string(static_cast<long long>(::getpid())) + "-" + input + "-" + output + ".cube");
    std::ofstream file(path);
    file << "# Gamma: " << input << " to " << output << '\n'
         << "# Gamut: " << (input == "FLog2C" ? "FGamutC" : "FGamut") << " to ITUR BT709\n"
         << "TITLE \"GPU photo parity\"\n"
         << "LUT_3D_SIZE 2\n"
         << "DOMAIN_MIN 0.15 0.20 0.10\n"
         << "DOMAIN_MAX 0.85 0.80 0.90\n";
    for (int b = 0; b < 2; ++b) {
        for (int g = 0; g < 2; ++g) {
            for (int r = 0; r < 2; ++r) {
                file << (0.05f + 0.9f * r) << ' '
                     << (0.10f + 0.75f * g) << ' '
                     << (0.15f + 0.95f * b) << '\n';
            }
        }
    }
    return path;
}

bool compareCase(
    sony2fuji_session* session,
    const std::vector<unsigned char>& pixels,
    uint32_t width,
    uint32_t height,
    sony2fuji_request request,
    const std::shared_ptr<sony2fuji::LUT3D>& lut,
    uint32_t targetWidth,
    uint32_t targetHeight,
    const std::string& name
) {
    request.input_pixels = pixels.data();
    request.input_width = width;
    request.input_height = height;
    request.target_width = targetWidth;
    request.target_height = targetHeight;

    sony2fuji_buffer cpu{};
    const auto cpuStatus = sony2fuji_process(session, &request, &cpu);

    const auto input = toLinearImage(pixels, width, height);
    sony2fuji::ImageData gpu;
#ifdef SONY2FUJI_ENABLE_D3D11
    static sony2fuji::D3D11PhotoRenderer renderer;
    const bool gpuStatus = renderer.render(input, sony2fuji::ColorSpace::sRGB,
        request, lut, sony2fuji::RGB(1,1,1), targetWidth, targetHeight, 0, gpu);
#else
    const bool gpuStatus = sony2fuji::renderPhotoMetal(
        input,
        sony2fuji::ColorSpace::sRGB,
        request,
        lut,
        sony2fuji::RGB(1.0f, 1.0f, 1.0f),
        targetWidth,
        targetHeight,
        gpu
    );
#endif

    bool result = cpuStatus == SONY2FUJI_STATUS_OK && gpuStatus;
    size_t maximum = 0;
    if (!result) {
        std::cerr << "CPU status=" << cpuStatus << " GPU status=" << gpuStatus << '\n';
    }
    if (result) {
        result = withinTwoDN(encodeRGB8(gpu), cpu, &maximum);
    }
    check(result, name + " (max DN " + std::to_string(maximum) + ")");
    sony2fuji_release_buffer(&cpu);
    return result;
}

void compareForcedCase(sony2fuji_session* cpuSession, sony2fuji_session* gpuSession,
                      const sony2fuji_request& request, const std::string& name) {
    sony2fuji_buffer cpu{}, gpu{};
    const auto cpuStatus = sony2fuji_process(cpuSession, &request, &cpu);
    const auto gpuStatus = sony2fuji_process(gpuSession, &request, &gpu);
#ifdef SONY2FUJI_ENABLE_D3D11
    const auto expectedBackend = SONY2FUJI_BACKEND_D3D11;
#else
    const auto expectedBackend = SONY2FUJI_BACKEND_METAL;
#endif
    check(gpuStatus == SONY2FUJI_STATUS_OK && sony2fuji_session_get_last_backend(gpuSession) == expectedBackend,
          name + " Force completes on the actual photo GPU backend");
    size_t maximum = 0;
    bool matched = false;
    if (cpuStatus == SONY2FUJI_STATUS_OK && gpuStatus == SONY2FUJI_STATUS_OK && gpu.data) {
        const auto* bytes = static_cast<const unsigned char*>(gpu.data);
        matched = withinTwoDN(std::vector<unsigned char>(bytes, bytes + gpu.size_bytes), cpu, &maximum);
    }
    check(matched, name + " forced CPU/GPU parity (max DN " + std::to_string(maximum) + ")");
    sony2fuji_release_buffer(&cpu);
    sony2fuji_release_buffer(&gpu);
}

} // namespace

int main() {
    if (!std::getenv("SONY2FUJI_TEST_GPU")) {
        std::cout << "SKIP gpu_photo_tests (set SONY2FUJI_TEST_GPU=1)\n";
        return 0;
    }

    const auto lutPath = makePhotoLUT();
    const auto lutUtf8 = lutPath.u8string();
    auto lut = std::shared_ptr<sony2fuji::LUT3D>(
        sony2fuji::LUTParser::loadLUT(lutPath.string())
    );
    check(lut && lut->isValid() && lut->isPhotoLUT(), "custom photo LUT loads");

    sony2fuji_session* session = nullptr;
    check(
        sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK && session,
        "CPU comparison session creates"
    );

    const std::vector<unsigned char> pixels = {
        0, 7, 31, 32, 64, 96, 128, 160, 192, 224, 245, 255,
        14, 52, 103, 156, 201, 240, 11, 88, 177, 219, 231, 17
    };
    const auto baseline = baseRequest(pixels, 4, 2);

    const float strengths[] = {0.0f, 0.5f, 1.0f, 2.0f};
    for (float strength : strengths) {
        auto request = baseline;
        request.lut_path = lutUtf8.c_str();
        request.lut_strength = strength;
        request.exposure_ev = 0.35f;
        request.brightness = 1.1f;
        request.contrast = 1.2f;
        request.saturation = 0.8f;
        request.highlights = 0.3f;
        request.shadows = -0.2f;
        request.tone_curve = 0.2f;
        request.noise_reduction = 0.4f;
        request.sharpening = 0.6f;
        compareCase(
            session,
            pixels,
            4,
            2,
            request,
            lut,
            4,
            2,
            "all controls, LUT strength " + std::to_string(strength)
        );
    }

    auto neutralRequest = baseline;
    neutralRequest.exposure_ev = -0.25f;
    neutralRequest.brightness = 0.9f;
    neutralRequest.lut_strength = 1.0f;
    compareCase(
        session,
        pixels,
        4,
        2,
        neutralRequest,
        nullptr,
        4,
        2,
        "nullptr LUT keeps the neutral display path"
    );

    const std::vector<unsigned char> oneByN = {
        3, 32, 91, 60, 4, 120, 212, 151, 17, 208, 247, 99
    };
    auto borderRequest = baseRequest(oneByN, 1, 4);
    borderRequest.sharpening = 1.0f;
    borderRequest.noise_reduction = 0.6f;
    borderRequest.lut_path = lutUtf8.c_str();
    borderRequest.lut_strength = 1.0f;
    compareCase(session, oneByN, 1, 4, borderRequest, lut, 1, 4, "3x3 borders on 1xN input");

    auto previewRequest = baseRequest(pixels, 4, 2);
    previewRequest.intent = SONY2FUJI_INTENT_PREVIEW;
    previewRequest.preview_long_edge = 2;
    previewRequest.target_width = 2;
    previewRequest.target_height = 1;
    previewRequest.lut_path = lutUtf8.c_str();
    previewRequest.lut_strength = 0.5f;
    previewRequest.noise_reduction = 0.3f;
    compareCase(session, pixels, 4, 2, previewRequest, lut, 2, 1, "preview resize precedes effects");

    auto finalRequest = previewRequest;
    finalRequest.intent = SONY2FUJI_INTENT_FINAL;
    finalRequest.preview_long_edge = 0;
    compareCase(session, pixels, 4, 2, finalRequest, lut, 2, 1, "final resize follows effects");

    sony2fuji_session* forced = nullptr;
    check(sony2fuji_session_create(&forced) == SONY2FUJI_STATUS_OK, "Force comparison session creates");
    sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), SONY2FUJI_GPU_FORCE};
    sony2fuji_session_set_gpu_config(forced, &config);
    std::vector<unsigned char> ramp(17 * 13 * 3);
    for (size_t i=0; i<ramp.size(); ++i) ramp[i] = static_cast<unsigned char>((i*73+i/7)%256);
    for (const auto& inputName : {"FLog", "FLog2", "FLog2C"}) {
        for (const auto& outputName : {"ETERNA", "FLog", "FLog2", "FLog2C"}) {
            const auto path = makePhotoLUT(inputName, outputName);
            const auto utf8 = path.u8string();
            const auto film = sony2fuji::LUTParser::loadLUTCached(utf8);
            auto request = baseRequest(ramp, 17, 13);
            request.lut_path = utf8.c_str();
            for (float strength : strengths) {
                request.lut_strength = strength;
                request.exposure_ev = strength == 0.5f ? -6.0f : 2.0f;
                request.contrast = 1.1f; request.saturation = .9f;
                request.shadows = -.2f; request.highlights = .3f; request.tone_curve = .1f;
                const auto name = std::string(inputName) + " to " + outputName + " strength " + std::to_string(strength);
                compareCase(session, ramp, 17, 13, request, film, 17, 13, name + " shader");
                compareForcedCase(session, forced, request, name);
            }
            std::filesystem::remove(path);
        }
    }
    sony2fuji_session_destroy(forced);

    sony2fuji_session_destroy(session);
    std::error_code error;
    std::filesystem::remove(lutPath, error);
    return failures ? 1 : 0;
}
