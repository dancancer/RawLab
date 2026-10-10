#include "sony2fuji/ffi/sony2fuji_c.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>
#include <fstream>
#include <thread>
#include <cstdio>

void require(bool value, const std::string& label) {
    if (!value) { std::cerr << "FAIL " << label << std::endl; std::exit(1); }
    std::cout << "PASS " << label << std::endl;
}
struct Session {
    sony2fuji_session* value = nullptr;
    explicit Session(sony2fuji_gpu_mode mode) {
        require(sony2fuji_session_create(&value) == SONY2FUJI_STATUS_OK, "session create");
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), mode};
        require(sony2fuji_session_set_gpu_config(value, &config) == SONY2FUJI_STATUS_OK, "GPU mode");
    }
    ~Session() { sony2fuji_session_destroy(value); }
};

std::vector<uint8_t> render(Session& session, const sony2fuji_request& request, bool gpu) {
    sony2fuji_buffer output{};
    require(sony2fuji_process(session.value, &request, &output) == SONY2FUJI_STATUS_OK, "render");
    std::vector<uint8_t> pixels(static_cast<uint8_t*>(output.data), static_cast<uint8_t*>(output.data) + output.size_bytes);
    sony2fuji_release_buffer(&output);
    require(sony2fuji_session_get_last_backend(session.value) == (gpu ? SONY2FUJI_BACKEND_GLES : SONY2FUJI_BACKEND_CPU), "actual backend");
    return pixels;
}

void compare(const std::vector<uint8_t>& cpu, const std::vector<uint8_t>& gpu, const std::string& label) {
    require(!cpu.empty() && cpu.size() == gpu.size(), label + " dimensions");
    int maximum = 0; double square = 0;
    for (size_t i = 0; i < cpu.size(); ++i) {
        const int delta = std::abs(int(cpu[i]) - int(gpu[i]));
        maximum = std::max(maximum, delta); square += delta * delta;
    }
    std::cout << "DIFF " << label << " maxDN=" << maximum << " rms=" << std::sqrt(square / cpu.size()) << std::endl;
    require(maximum <= 2, label + " CPU/GLES tolerance");
}

double benchmark(Session& session, const sony2fuji_request& request, bool gpu) {
    render(session, request, gpu);
    std::vector<double> samples;
    for (int i = 0; i < 5; ++i) {
        const auto start = std::chrono::steady_clock::now();
        render(session, request, gpu);
        samples.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
    }
    std::sort(samples.begin(), samples.end());
    return samples[2];
}

int main(int argc, char** argv) {
    Session forced(SONY2FUJI_GPU_FORCE);
    Session cpu(SONY2FUJI_GPU_OFF), automatic(SONY2FUJI_GPU_AUTO);
    std::vector<uint8_t> pixels(53 * 41 * 3);
    for (size_t i = 0; i < pixels.size(); ++i) pixels[i] = uint8_t((i * 71 + i / 9) % 256);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER; request.input_pixels = pixels.data();
    request.input_width = 53; request.input_height = 41; request.input_is_linear = 1;
    request.brightness = request.contrast = request.saturation = 1;
    request.temperature = 6500;
    request.intent = SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge = 24;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGBA8;
    sony2fuji_buffer output{};
    require(sony2fuji_process(forced.value, &request, &output) == SONY2FUJI_STATUS_OK, "forced neutral render");
    sony2fuji_release_buffer(&output);
    require(static_cast<int>(sony2fuji_session_get_last_backend(forced.value)) == 2, "actual GLES backend, not CPU fallback");

    const std::string cube = "domain.cube";
    {
        std::ofstream file(cube);
        file << "#Gamma:F-Log2 to PROVIA\n#Gamut:F-Gamut to ITU-R BT.709\nLUT_3D_SIZE 3\nDOMAIN_MIN -0.1 0.1 0.2\nDOMAIN_MAX 0.8 0.9 1.1\n";
        for (int b = 0; b < 3; ++b) for (int g = 0; g < 3; ++g) for (int r = 0; r < 3; ++r)
            file << r / 2.f << ' ' << g / 2.f << ' ' << b / 2.f << '\n';
    }
    for (const char* lut : {static_cast<const char*>(nullptr), cube.c_str()}) {
        request.lut_path = lut;
        for (float exposure : {-2.f, 0.f, 2.f}) {
            request.exposure_ev = exposure;
            for (float strength : {0.f, .65f, 1.f}) {
                request.lut_strength = strength;
                compare(render(cpu, request, false), render(forced, request, true), "synthetic preview");
            }
        }
    }
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.size_mode = SONY2FUJI_SIZE_EXACT; request.target_width = 17; request.target_height = 11;
    request.contrast = 1.2; request.saturation = .7; request.highlights = -.4;
    request.shadows = .3; request.tone_curve = .25;
    compare(render(cpu, request, false), render(forced, request, true), "FINAL resize after pointwise tone");
    request.sharpening = .5;
    compare(render(cpu, request, false), render(automatic, request, true), "detail Auto GLES");
    compare(render(cpu, request, false), render(forced, request, true), "detail Force GLES");
    request.sharpening = 0;
    std::thread first([&] { compare(render(cpu, request, false), render(forced, request, true), "worker one"); });
    first.join();
    std::thread second([&] { render(forced, request, true); }); second.join();
    {
        Session other(SONY2FUJI_GPU_FORCE); render(other, request, true);
    }
    render(forced, request, true);
    {
        std::vector<uint8_t> widePixels(400000 * 8 * 3, 100);
        auto wide = request;
        wide.input_pixels = widePixels.data(); wide.input_width = 400000; wide.input_height = 8;
        wide.target_width = 1; wide.target_height = 3;
        require(sony2fuji_process(forced.value, &wide, &output) == SONY2FUJI_STATUS_PROCESSING_ERROR,
            "Force rejects a source halo exceeding the tile budget");
        compare(render(cpu, wide, false), render(automatic, wide, false), "oversized source halo Auto fallback");
    }
    for (const std::string input : {"FLog", "FLog2", "FLog2C"}) {
        for (const std::string transfer : {"Display", "FLog", "FLog2", "FLog2C"}) {
            const auto path = cube + "-" + input + "-" + transfer + ".cube";
            {
                std::ofstream file(path);
                file << "#Gamma:" << input << " to " << transfer << "\n#Gamut:"
                     << (input == "FLog2C" ? "F-GamutC" : "F-Gamut") << " to ITU-R BT.709\n"
                     << "LUT_3D_SIZE 3\nDOMAIN_MIN -0.1 0.1 0.2\nDOMAIN_MAX 0.8 0.9 1.1\n";
                for (int b=0; b<3; ++b) for (int g=0; g<3; ++g) for (int r=0; r<3; ++r)
                    file << r/2.f << ' ' << g/2.f << ' ' << b/2.f << '\n';
            }
            auto contract = request; contract.lut_path = path.c_str();
            for (auto intent : {SONY2FUJI_INTENT_PREVIEW, SONY2FUJI_INTENT_FINAL}) {
                contract.intent = intent;
                for (float strength : {0.f, .5f, 1.f, 2.f}) {
                    contract.lut_strength = strength;
                    contract.exposure_ev = strength == .5f ? -6.f : 2.f;
                    compare(render(cpu, contract, false), render(forced, contract, true),
                            input + " to " + transfer + " strength " + std::to_string(strength) + " intent " + std::to_string(intent));
                }
            }
            contract.sharpening = .5f;
            compare(render(cpu, contract, false), render(automatic, contract, true), "Fuji detail Auto GLES");
            compare(render(cpu, contract, false), render(forced, contract, true), "Fuji detail Force GLES");
            std::remove(path.c_str());
        }
    }
    std::remove(cube.c_str());

    sony2fuji_photo_effects_config effects{SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION, sizeof(effects),
        -65, 52, -35, 70, 75, 70, 60, 80};
    sony2fuji_wavelet_denoise_config wavelet{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION,
        sizeof(wavelet), 1, 40, 46, 50};
    for (Session* session : {&cpu, &forced, &automatic}) {
        require(sony2fuji_session_set_photo_effects(session->value, &effects) == SONY2FUJI_STATUS_OK, "effects setter");
        require(sony2fuji_session_set_chroma_denoise(session->value, 2) == SONY2FUJI_STATUS_OK, "chroma setter");
        require(sony2fuji_session_set_wavelet_denoise(session->value, &wavelet) == SONY2FUJI_STATUS_OK, "wavelet setter");
    }
    request.lut_path = nullptr;
    request.sharpening = .5f;
    const auto combinedCPU = render(cpu, request, false);
    const auto combinedGPU = render(forced, request, true);
    compare(combinedCPU, combinedGPU, "combined effects/wavelet/chroma/detail FINAL");
    require(combinedGPU == render(forced, request, true), "combined grain is deterministic");
    compare(combinedCPU, render(automatic, request, true), "combined Auto uses GLES");

    if (argc < 3) return 0;
    request = {};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = argv[1];
    request.brightness = request.contrast = request.saturation = 1; request.temperature = 6500;
    request.lut_path = argv[2]; request.lut_strength = .8;
    request.intent = SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge = 1600;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGBA8;
    compare(render(cpu, request, false), render(forced, request, true), "RAW preview");
    for (float exposure : {-1.f, .7f}) {
        request.exposure_ev = exposure;
        compare(render(cpu, request, false), render(forced, request, true), "cached RAW exposure");
    }
    request.exposure_ev = 0;
    const auto cpuMs = benchmark(cpu, request, false);
    const auto gpuMs = benchmark(forced, request, true);
    std::cout << "BENCH warm 1600px CPU_ms=" << cpuMs << " GLES_ms=" << gpuMs << " speedup=" << cpuMs / gpuMs << std::endl;
    request.wb_mode = SONY2FUJI_WB_TEMPERATURE; request.temperature = 4200; request.tint = 12;
    sony2fuji_session_set_interactive_preview(cpu.value, 1);
    sony2fuji_session_set_interactive_preview(forced.value, 1);
    const auto proxyCpu = render(cpu, request, false), proxyGpu = render(forced, request, true);
    compare(proxyCpu, proxyGpu, "WB interactive RAW");
    sony2fuji_session_set_interactive_preview(cpu.value, 0);
    sony2fuji_session_set_interactive_preview(forced.value, 0);
    const auto exactCpu = render(cpu, request, false), exactGpu = render(forced, request, true);
    compare(exactCpu, exactGpu, "WB exact RAW after proxy");
    require(proxyGpu != exactGpu, "proxy cache cannot supply exact render");
    request.wb_mode = SONY2FUJI_WB_CAMERA; request.temperature = 6500; request.tint = 0;
    request.intent = SONY2FUJI_INTENT_FINAL;
    compare(render(cpu, request, false), render(forced, request, true), "native full-resolution pixels");
    request.output_target = SONY2FUJI_TARGET_FILE; request.output_format = SONY2FUJI_OUTPUT_PNG;
    const std::string out = "full-gpu.png";
    request.output_path = out.c_str();
    const auto start = std::chrono::steady_clock::now();
    require(sony2fuji_process(forced.value, &request, nullptr) == SONY2FUJI_STATUS_OK, "full native 16-bit PNG GPU export");
    require(sony2fuji_session_get_last_backend(forced.value) == SONY2FUJI_BACKEND_GLES, "export actually used GLES");
    std::cout << "BENCH GPU native PNG_ms=" << std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() << std::endl;
    unsigned char header[26]{};
    std::ifstream file(out, std::ios::binary); file.read(reinterpret_cast<char*>(header), sizeof(header));
    auto dimension = [&](int offset) { return (uint32_t(header[offset]) << 24) | (uint32_t(header[offset + 1]) << 16) | (uint32_t(header[offset + 2]) << 8) | header[offset + 3]; };
    require(dimension(16) == 7008 && dimension(20) == 4672 && header[24] == 16, "native dimensions and bit depth");
    const std::string cpuOut = "full-cpu.png";
    request.output_path = cpuOut.c_str();
    const auto cpuStart = std::chrono::steady_clock::now();
    require(sony2fuji_process(cpu.value, &request, nullptr) == SONY2FUJI_STATUS_OK, "CPU native PNG export baseline");
    std::cout << "BENCH CPU native PNG_ms=" << std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - cpuStart).count() << std::endl;
}
