#include "sony2fuji/ffi/sony2fuji_c.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>
#ifdef _WIN32
#include <process.h>
#define getpid _getpid
#else
#include <unistd.h>
#endif

namespace {
void check(bool condition, const std::string& name) {
    std::cout << (condition ? "PASS " : "FAIL ") << name << std::endl;
    if (!condition) std::exit(1);
}
struct Session {
    sony2fuji_session* value = nullptr;
    explicit Session(sony2fuji_gpu_mode mode) {
        check(sony2fuji_session_create(&value) == SONY2FUJI_STATUS_OK, "create session");
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), mode};
        check(sony2fuji_session_set_gpu_config(value, &config) == SONY2FUJI_STATUS_OK, "set GPU mode");
    }
    ~Session() { sony2fuji_session_destroy(value); }
};
std::vector<uint8_t> render(Session& session, const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    check(sony2fuji_process(session.value, &request, &buffer) == SONY2FUJI_STATUS_OK, "render");
    auto* bytes = static_cast<uint8_t*>(buffer.data);
    std::vector<uint8_t> output(bytes, bytes + buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);
    return output;
}
void compare(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b, int tolerance,
             const std::string& name) {
    check(a.size() == b.size() && !a.empty(), name + " dimensions");
    int maximum = 0;
    for (size_t i = 0; i < a.size(); ++i) maximum = std::max(maximum, std::abs(int(a[i])-int(b[i])));
    check(maximum <= tolerance, name + " max DN=" + std::to_string(maximum));
}
std::vector<uint8_t> readFile(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
}

int main(int argc, char** argv) {
    if (argc != 3) return 2;
#ifdef SONY2FUJI_ENABLE_METAL
    const bool nativeCpuOnly = false;
#else
    const bool nativeCpuOnly = std::filesystem::u8path(argv[2]).extension() == ".rlook";
#endif
    Session cpu(SONY2FUJI_GPU_OFF), gpu(nativeCpuOnly ? SONY2FUJI_GPU_AUTO : SONY2FUJI_GPU_FORCE);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = argv[1];
    request.lut_path = argv[2]; request.lut_strength = 0.65f;
    request.temperature = 6500; request.brightness = request.contrast = request.saturation = 1;
    request.intent = SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge = 600;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGBA8;
    if (nativeCpuOnly) {
        Session forced(SONY2FUJI_GPU_FORCE);
        sony2fuji_buffer buffer{};
        check(sony2fuji_process(forced.value, &request, &buffer) == SONY2FUJI_STATUS_PROCESSING_ERROR,
              "CPU-only look explicitly rejects forced GPU");
        sony2fuji_release_buffer(&buffer);
    }
    for (float temperature : {0.f, 4000.f, 8500.f}) {
        request.wb_mode = temperature ? SONY2FUJI_WB_TEMPERATURE : SONY2FUJI_WB_CAMERA;
        request.temperature = temperature ? temperature : 6500;
        compare(render(cpu, request), render(gpu, request), nativeCpuOnly ? 0 : 2,
                (nativeCpuOnly ? "RAW CPU/Auto WB " : "RAW CPU/GPU WB ") + std::to_string(temperature));
        if (nativeCpuOnly) {
            check(sony2fuji_session_get_last_backend(gpu.value) == SONY2FUJI_BACKEND_CPU,
                  "CPU-only look reports actual CPU backend");
        } else {
#ifdef SONY2FUJI_ENABLE_D3D11
        check(sony2fuji_session_get_last_backend(gpu.value) == SONY2FUJI_BACKEND_D3D11, "actual Direct3D 11 hardware backend");
#else
        check(sony2fuji_session_get_last_backend(gpu.value) == SONY2FUJI_BACKEND_METAL, "actual Metal backend");
#endif
        }
    }
    request.exposure_ev = .4f; request.contrast = 1.2f; request.saturation = .7f;
    request.highlights = .3f; request.shadows = -.2f; request.tone_curve = .2f;
    request.noise_reduction = .3f; request.sharpening = .4f;
    compare(render(cpu, request), render(gpu, request), 2, "RAW all adjustments and full-resolution detail");
    const auto cachedExact = render(gpu, request);
    check(sony2fuji_session_set_interactive_preview(gpu.value, 1) == SONY2FUJI_STATUS_OK, "enable interactive");
    compare(cachedExact, render(gpu, request), 0, "interactive may reuse a matching exact RAW cache");
    request.temperature = 5000;
    const auto proxy = render(gpu, request);
    sony2fuji_session_set_interactive_preview(gpu.value, 0);
    const auto exact = render(gpu, request);
    check(proxy != exact, "new WB interactive preview uses reduced RAW processing");
    compare(render(cpu, request), exact, 2, "exact output restored after interactive preview");

    request.intent = SONY2FUJI_INTENT_FINAL;
    request.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE; request.long_edge = 600;
    const auto final = render(gpu, request);
    sony2fuji_session_set_interactive_preview(gpu.value, 1);
    compare(final, render(gpu, request), 0, "FINAL ignores interactive flag");

    // Even callers that accidentally retain PREVIEW intent must never export a proxy.
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.output_target = SONY2FUJI_TARGET_FILE; request.output_format = SONY2FUJI_OUTPUT_PNG;
    auto path = std::filesystem::temp_directory_path() /
        ("rawtools-acceleration-" + std::to_string(getpid()) + ".png");
    const auto outputPath = path.u8string();
    request.output_path = outputPath.c_str();
    check(sony2fuji_process(gpu.value, &request, nullptr) == SONY2FUJI_STATUS_OK, "export with interactive flag");
    const auto interactiveFile = readFile(path);
    sony2fuji_session_set_interactive_preview(gpu.value, 0);
    check(sony2fuji_process(gpu.value, &request, nullptr) == SONY2FUJI_STATUS_OK, "export exact");
    compare(interactiveFile, readFile(path), 0, "file export ignores interactive flag");
    std::filesystem::remove(path);
    return 0;
}
