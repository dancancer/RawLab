#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/lut_parser.h"
#include "core/stb_image_write.h"
#include <GLES3/gl31.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {
int dispatches = 0;
bool injectFailure = false;
bool failureReached = false;
bool parityPassed = true;

void require(bool value, const std::string& label) {
    if (!value) { std::cerr << "FAIL " << label << std::endl; std::exit(1); }
    std::cout << "PASS " << label << std::endl;
}

struct Session {
    sony2fuji_session* value = nullptr;
    Session() { require(sony2fuji_session_create(&value) == SONY2FUJI_STATUS_OK, "create session"); }
    ~Session() { sony2fuji_session_destroy(value); }
    void mode(sony2fuji_gpu_mode mode) {
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), mode};
        require(sony2fuji_session_set_gpu_config(value, &config) == SONY2FUJI_STATUS_OK, "set GPU mode");
    }
};

std::vector<uint8_t> render(Session& session, const sony2fuji_request& request,
    sony2fuji_render_backend backend, uint64_t minimumPixels, uint32_t* width = nullptr, uint32_t* height = nullptr) {
    sony2fuji_buffer output{};
    require(sony2fuji_process(session.value, &request, &output) == SONY2FUJI_STATUS_OK, "render");
    require(sony2fuji_session_get_last_backend(session.value) == backend, "actual backend");
    std::cout << "SIZE " << output.width << 'x' << output.height << std::endl;
    require(uint64_t(output.width) * output.height >= minimumPixels, "full-resolution result");
    if (request.input_type != SONY2FUJI_INPUT_RAW && request.intent == SONY2FUJI_INTENT_FINAL)
        require(output.width == request.input_width && output.height == request.input_height,
            "synthetic image preserves width and height");
    if (width) *width = output.width;
    if (height) *height = output.height;
    auto* data = static_cast<uint8_t*>(output.data);
    std::vector<uint8_t> result(data, data + output.size_bytes);
    sony2fuji_release_buffer(&output);
    return result;
}

void compare(const std::vector<uint8_t>& expected, const std::vector<uint8_t>& actual,
    int tolerance, const std::string& label) {
    require(expected.size() == actual.size() && !actual.empty(), label + " size");
    int maximum = 0;
    size_t exceeded = 0;
    double square = 0;
    for (size_t i = 0; i < expected.size(); ++i) {
        const int delta = std::abs(int(expected[i]) - int(actual[i]));
        maximum = std::max(maximum, delta);
        square += delta * delta;
        if (delta > tolerance && exceeded++ < 5)
            std::cout << "PIXEL byte=" << i << " CPU=" << int(expected[i]) << " GPU=" << int(actual[i]) << std::endl;
    }
    std::cout << "DIFF " << label << " maxDN=" << maximum << " rms=" << std::sqrt(square / actual.size()) << std::endl;
    if (maximum > tolerance) {
        std::cerr << "FAIL " << label << " out-of-tolerance bytes=" << exceeded << std::endl;
        parityPassed = false;
    } else require(true, label);
}

std::vector<uint8_t> readFile(const char* path) {
    std::ifstream file(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
}

extern "C" void __real_glDispatchCompute(GLuint, GLuint, GLuint);
extern "C" void __wrap_glDispatchCompute(GLuint x, GLuint y, GLuint z) {
    ++dispatches;
    if (injectFailure && dispatches == 2) {
        GLint maximum = 0;
        glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0, &maximum);
        x = static_cast<GLuint>(maximum) + 1;
        failureReached = true;
    }
    __real_glDispatchCompute(x, y, z);
}

int main(int argc, char** argv) {
    require(argc == 4 || argc == 5, "usage: rawlab_large_image_tests <raw path|scene|display> <LUT path> <minimum pixels|WIDTHxHEIGHT> [export]");
    const std::string source = argv[1];
    const std::string dimensions = argv[3];
    const auto separator = dimensions.find('x');
    const uint32_t width = separator == std::string::npos ? 0 : std::stoul(dimensions.substr(0, separator));
    const uint32_t height = separator == std::string::npos ? 0 : std::stoul(dimensions.substr(separator + 1));
    const uint64_t count = separator == std::string::npos ? std::stoull(dimensions) : uint64_t(width) * height;
    require(count > 0, "positive pixel count");
    if (argc == 5) {
        for (const char* path : {"large-cpu.jpg", "large-gpu.jpg", "large-auto.jpg", "large-reference-gpu.jpg"})
            std::remove(path);
    }
    Session session;
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = argv[1];
    std::vector<uint8_t> pixels;
    if (source == "scene" || source == "display") {
        require(width > 0 && height > 0, "synthetic image requires WIDTHxHEIGHT");
        pixels.resize(count * 3);
        for (size_t i = 0; i < pixels.size(); ++i) pixels[i] = uint8_t((i * 71 + i / 9) % 256);
        request.input_type = source == "scene" ? SONY2FUJI_INPUT_BUFFER : SONY2FUJI_INPUT_DISPLAY_BUFFER;
        request.input_pixels = pixels.data(); request.input_width = width; request.input_height = height;
        request.input_is_linear = source == "scene";
    }
    request.brightness = 1.05f; request.contrast = 1.17f; request.saturation = .81f;
    request.exposure_ev = .65f; request.highlights = -.25f; request.shadows = .35f; request.tone_curve = .2f;
    request.temperature = source == "display" ? 6500 : 5600;
    request.tint = source == "display" ? 0 : 8;
    request.wb_mode = source == "display" || source == "scene" ? SONY2FUJI_WB_CAMERA : SONY2FUJI_WB_TEMPERATURE;
    request.lut_path = argv[2]; request.lut_strength = .83f;
    request.intent = SONY2FUJI_INTENT_FINAL; request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGBA8;
    request.jpeg_quality = 95;
    // display 不设置 HSL，确保 JPEG 实际使用的单独 LUT GPU 路径被覆盖。
    if (source != "display" && !std::getenv("RAWLAB_TEST_NO_HSL")) {
        sony2fuji_hsl_config hsl{SONY2FUJI_HSL_CONFIG_VERSION, sizeof(hsl), {}, {}, {}};
        hsl.hue[4] = 12; hsl.saturation[0] = -20; hsl.lightness[5] = 10;
        require(sony2fuji_session_set_hsl(session.value, &hsl) == SONY2FUJI_STATUS_OK, "set HSL adjustments");
    }
    sony2fuji::LUT3D lut;
    require(lut.loadFromFile(argv[2]) == sony2fuji::ErrorCode::Success, "read LUT contract");
    const bool cpuLook = source != "display" && lut.inputTransfer() == sony2fuji::LUTTransfer::SRGB;
    const auto gpuBackend = source == "display" || cpuLook ? SONY2FUJI_BACKEND_CPU : SONY2FUJI_BACKEND_GLES;
    {
        auto preview = request;
        preview.intent = SONY2FUJI_INTENT_PREVIEW; preview.preview_long_edge = 1600;
        session.mode(SONY2FUJI_GPU_OFF);
        const auto cpuPreview = render(session, preview, SONY2FUJI_BACKEND_CPU, 1);
        session.mode(SONY2FUJI_GPU_AUTO);
        compare(cpuPreview, render(session, preview, gpuBackend, 1), 2, "preview preserves configured adjustments");
    }
    session.mode(SONY2FUJI_GPU_OFF);
    const auto expected = render(session, request, SONY2FUJI_BACKEND_CPU, count);
    session.mode(SONY2FUJI_GPU_AUTO);
    dispatches = 0;
    {
        uint32_t outputWidth = 0, outputHeight = 0;
        const auto gpu = render(session, request, gpuBackend, count, &outputWidth, &outputHeight);
        compare(expected, gpu, 2, "large image CPU/GPU with adjustments");
        // GPU/CPU 画质在编码前比较；单独编码已核验的 GPU buffer，检查文件输出是否提交了同一图像。
        if (argc == 5 && !cpuLook)
            require(stbi_write_jpg("large-reference-gpu.jpg", outputWidth, outputHeight, 4,
                gpu.data(), request.jpeg_quality) != 0, "encode independently rendered GPU buffer");
    }
    if (cpuLook) {
        require(dispatches == 0, "RAW display look uses the CPU fallback");
        if (argc == 5) {
            auto file = request;
            file.output_target = SONY2FUJI_TARGET_FILE; file.output_format = SONY2FUJI_OUTPUT_JPEG;
            file.output_path = "large-auto.jpg";
            require(sony2fuji_process(session.value, &file, nullptr) == SONY2FUJI_STATUS_OK,
                "RAW display-look Auto JPEG export");
            session.mode(SONY2FUJI_GPU_OFF);
            file.output_path = "large-cpu.jpg";
            require(sony2fuji_process(session.value, &file, nullptr) == SONY2FUJI_STATUS_OK, "RAW display-look CPU JPEG export");
            const auto autoBytes = readFile("large-auto.jpg");
            require(!autoBytes.empty() && autoBytes == readFile("large-cpu.jpg"), "RAW display-look JPEG matches CPU exactly");
            if (!std::getenv("RAWLAB_TEST_KEEP_EXPORTS")) {
                std::remove("large-auto.jpg"); std::remove("large-cpu.jpg");
            }
        }
        session.mode(SONY2FUJI_GPU_FORCE);
        sony2fuji_buffer output{};
        require(sony2fuji_process(session.value, &request, &output) == SONY2FUJI_STATUS_PROCESSING_ERROR &&
            output.data == nullptr && output.size_bytes == 0, "Force rejects unsupported RAW look without output");
        return parityPassed ? 0 : 1;
    }
    require(dispatches > 1, "GPU used multiple bands");

    if (source != "display") {
        session.mode(SONY2FUJI_GPU_FORCE);
        dispatches = 0; injectFailure = true; failureReached = false;
        sony2fuji_buffer output{};
        require(sony2fuji_process(session.value, &request, &output) == SONY2FUJI_STATUS_PROCESSING_ERROR,
            "Force reports mid-render GPU failure");
        require(failureReached && output.data == nullptr && output.size_bytes == 0,
            "Force publishes no partial result");
    }
    session.mode(SONY2FUJI_GPU_AUTO);
    dispatches = 0; injectFailure = true; failureReached = false;
    compare(expected, render(session, request, SONY2FUJI_BACKEND_CPU, count), 0,
        "Auto fallback preserves all configured adjustments");
    require(failureReached, "Auto reached mid-render GPU failure");
    injectFailure = false; dispatches = 0;
    compare(expected, render(session, request, gpuBackend, count), 2, "same session recovers after GPU failure");
    require(dispatches > 1, "GPU recovered without changing settings");
    if (argc == 5) {
        request.output_target = SONY2FUJI_TARGET_FILE; request.output_format = SONY2FUJI_OUTPUT_JPEG;
        request.output_path = "large-cpu.jpg";
        session.mode(SONY2FUJI_GPU_OFF);
        require(sony2fuji_process(session.value, &request, nullptr) == SONY2FUJI_STATUS_OK, "CPU JPEG export");
        request.output_path = "large-gpu.jpg";
        session.mode(SONY2FUJI_GPU_AUTO);
        dispatches = 0;
        require(sony2fuji_process(session.value, &request, nullptr) == SONY2FUJI_STATUS_OK && dispatches > 1 &&
            sony2fuji_session_get_last_backend(session.value) == gpuBackend, "successful GPU JPEG export");
        const auto gpuBytes = readFile("large-gpu.jpg");
        require(!gpuBytes.empty() && gpuBytes == readFile("large-reference-gpu.jpg"),
            "successful GPU JPEG matches the verified full-resolution buffer");
        request.output_path = "large-auto.jpg";
        session.mode(SONY2FUJI_GPU_AUTO);
        dispatches = 0; injectFailure = true; failureReached = false;
        require(sony2fuji_process(session.value, &request, nullptr) == SONY2FUJI_STATUS_OK && failureReached,
            "JPEG export falls back after mid-render GPU failure");
        const auto cpuBytes = readFile("large-cpu.jpg"), autoBytes = readFile("large-auto.jpg");
        require(!cpuBytes.empty() && cpuBytes == autoBytes, "fallback JPEG exactly matches adjusted CPU export");
        if (!std::getenv("RAWLAB_TEST_KEEP_EXPORTS")) {
            std::remove("large-cpu.jpg"); std::remove("large-gpu.jpg"); std::remove("large-auto.jpg");
            std::remove("large-reference-gpu.jpg");
        }
    }
    require(parityPassed, "all pixel comparisons passed");
}
