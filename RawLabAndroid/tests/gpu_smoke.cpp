#include "sony2fuji/ffi/sony2fuji_c.h"
#include "gpu/gles_photo.h"
#include "hsl_gpu_boundary.h"
#include "tone_gpu_boundary.h"
#include "grading_gpu_boundary.h"
#include "curve_gpu_boundary.h"
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

std::vector<uint8_t> render(Session& session, const sony2fuji_request& request, bool gpu,
    uint32_t* width = nullptr, uint32_t* height = nullptr) {
    sony2fuji_buffer output{};
    require(sony2fuji_process(session.value, &request, &output) == SONY2FUJI_STATUS_OK, "render");
    std::vector<uint8_t> pixels(static_cast<uint8_t*>(output.data), static_cast<uint8_t*>(output.data) + output.size_bytes);
    if (width) *width = output.width;
    if (height) *height = output.height;
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
    require(rawlabtest::hslGpuBoundary([](const sony2fuji::ImageData& input, const sony2fuji_request& request,
        const sony2fuji::HslOptions& hsl, sony2fuji::ImageData& output) {
        sony2fuji::GlesPhotoRenderer renderer;
        return renderer.render(input, sony2fuji::ColorSpace::sRGB, request, {}, {1,1,1},
            input.width, input.height, 0, output, {}, 0, false, hsl);
    }), "HSL out-of-range boundary and active adjustment");
    require(rawlabtest::toneGpuBoundary([](const sony2fuji::ImageData& input, const sony2fuji_request& request,
        const sony2fuji::ToneControlsOptions& controls, sony2fuji::ImageData& output) {
        sony2fuji::GlesPhotoRenderer renderer;
        return renderer.render(input,sony2fuji::ColorSpace::sRGB,request,{}, {1,1,1},
            input.width,input.height,0,output,{},0,false,{},controls);
    }), "Tone endpoints/vibrance match CPU float reference");
    require(rawlabtest::gradingGpuBoundary([](const sony2fuji::ImageData& input,const sony2fuji_request& request,
        const sony2fuji::ColorGradingOptions& grading,sony2fuji::ImageData& output) {
        sony2fuji::GlesPhotoRenderer renderer;
        return renderer.render(input,sony2fuji::ColorSpace::sRGB,request,{}, {1,1,1},
            input.width,input.height,0,output,{},0,false,{}, {},grading);
    }),"Color grading matches CPU float reference across regions and gamut boundaries");
    require(rawlabtest::curveGpuBoundary([](const sony2fuji::ImageData& input,const sony2fuji_request& request,
        const sony2fuji::ToneCurve& curve,sony2fuji::ImageData& output) {
        sony2fuji::GlesPhotoRenderer renderer;
        return renderer.render(input,sony2fuji::ColorSpace::sRGB,request,{}, {1,1,1},
            input.width,input.height,0,output,{},0,false,{}, {},{},curve);
    }),"PCHIP curve matches CPU float reference including 33 points and plateaus");
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
    sony2fuji_hsl_config hsl{SONY2FUJI_HSL_CONFIG_VERSION, sizeof(hsl), {}, {}, {}};
    for (int axis = 0; axis < 3; ++axis) for (int channel = 0; channel < 8; ++channel) {
        hsl = {SONY2FUJI_HSL_CONFIG_VERSION, sizeof(hsl), {}, {}, {}};
        auto* values = axis == 0 ? hsl.hue : axis == 1 ? hsl.saturation : hsl.lightness;
        values[channel] = axis == 0 ? 100 : axis == 1 ? -100 : 25;
        for (Session* session : {&cpu, &forced, &automatic})
            require(sony2fuji_session_set_hsl(session->value, &hsl) == SONY2FUJI_STATUS_OK, "HSL setter");
        auto single = request;
        single.lut_path = nullptr; single.sharpening = 0;
        single.contrast = single.saturation = 1; single.highlights = single.shadows = single.tone_curve = 0;
        compare(render(cpu, single, false), render(forced, single, true), "HSL-only axis " + std::to_string(axis) + " channel " + std::to_string(channel));
    }
    for (int channel = 0; channel < 8; ++channel) {
        hsl.hue[channel] = channel % 2 == 0 ? -40 : 70;
        hsl.saturation[channel] = channel % 2 == 0 ? 35 : -60;
        hsl.lightness[channel] = channel % 2 == 0 ? -15 : 20;
    }
    for (Session* session : {&cpu, &forced, &automatic})
        sony2fuji_session_set_hsl(session->value, &hsl);
    const std::vector<uint8_t> wrapPixels{230,20,21, 230,21,20, 220,20,20,
        20,220,220, 20,20,220, 180,20,220, 0,0,0, 128,128,128, 255,255,255};
    auto wrap = request;
    wrap.input_pixels = wrapPixels.data(); wrap.input_width = wrap.target_width = 9;
    wrap.input_height = wrap.target_height = 1;
    wrap.lut_path = nullptr; wrap.contrast = wrap.saturation = 1;
    wrap.highlights = wrap.shadows = wrap.tone_curve = 0;
    compare(render(cpu, wrap, false), render(forced, wrap, true), "HSL red wrap and achromatic pixels");
    const std::vector<uint8_t> nearGrayPixels{230,229,229, 229,230,229,
        229,229,230, 225,224,225};
    auto nearGray = wrap;
    nearGray.input_pixels = nearGrayPixels.data();
    nearGray.input_width = nearGray.target_width = 4;
    nearGray.sharpening = 0; nearGray.exposure_ev = 4;
    compare(render(cpu, nearGray, false), render(forced, nearGray, true), "HSL near-gray lightness remains stable");
    compare(render(cpu, request, false), render(forced, request, true), "HSL tone/LUT FINAL");
    sony2fuji_tone_controls_config tone{1,sizeof(tone),.6f,-.4f,.8f};
    for (Session* session : {&cpu,&forced,&automatic})
        require(sony2fuji_session_set_tone_controls(session->value,&tone)==SONY2FUJI_STATUS_OK,"tone controls setter");
    compare(render(cpu,request,false),render(forced,request,true),"Black/white/vibrance with HSL/LUT FINAL");
    sony2fuji_color_grading_config grading{1,sizeof(grading),220,75,110,35,35,60};
    for (Session* session : {&cpu,&forced,&automatic})
        require(sony2fuji_session_set_color_grading(session->value,&grading)==SONY2FUJI_STATUS_OK,"grading setter");
    compare(render(cpu,request,false),render(forced,request,true),"Grading with black/white/vibrance and HSL/LUT FINAL");
    sony2fuji_tone_curve_config curve{1,sizeof(curve),SONY2FUJI_CURVE_CUSTOM,4,{{0,0},{.25,.12},{.75,.88},{1,1}}};
    for (Session* session : {&cpu,&forced,&automatic}) sony2fuji_session_set_tone_curve(session->value,&curve);
    const float legacyCurve=request.tone_curve;request.tone_curve=0;
    compare(render(cpu,request,false),render(forced,request,true),"Custom curve with grading, tone and HSL/LUT FINAL");
    curve={1,sizeof(curve),SONY2FUJI_CURVE_LEGACY,0,{}};
    for (Session* session : {&cpu,&forced,&automatic}) sony2fuji_session_set_tone_curve(session->value,&curve);
    request.tone_curve=legacyCurve;
    auto hslPreview = request;
    hslPreview.intent = SONY2FUJI_INTENT_PREVIEW;
    compare(render(cpu, hslPreview, false), render(automatic, hslPreview, true), "HSL tone/LUT Auto preview");
    tone.black_point=tone.white_point=tone.vibrance=0;
    for (Session* session : {&cpu,&forced,&automatic}) sony2fuji_session_set_tone_controls(session->value,&tone);
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
    compare(render(cpu, request, false), render(forced, request, true), "RAW combined HSL/effects/wavelet/chroma preview");
    // 基础 RAW/代理测试不继承上面的持久化滤镜状态。
    for (Session* completed : {&cpu, &forced}) {
        sony2fuji_session_destroy(completed->value);
        completed->value = nullptr;
    }
    Session rawCPU(SONY2FUJI_GPU_OFF), rawGPU(SONY2FUJI_GPU_FORCE);
    compare(render(rawCPU, request, false), render(rawGPU, request, true), "RAW preview");
    for (float exposure : {-1.f, .7f}) {
        request.exposure_ev = exposure;
        compare(render(rawCPU, request, false), render(rawGPU, request, true), "cached RAW exposure");
    }
    request.exposure_ev = 0;
    const auto cpuMs = benchmark(rawCPU, request, false);
    const auto gpuMs = benchmark(rawGPU, request, true);
    std::cout << "BENCH warm 1600px CPU_ms=" << cpuMs << " GLES_ms=" << gpuMs << " speedup=" << cpuMs / gpuMs << std::endl;
    request.wb_mode = SONY2FUJI_WB_TEMPERATURE; request.temperature = 4200; request.tint = 12;
    sony2fuji_session_set_interactive_preview(rawCPU.value, 1);
    sony2fuji_session_set_interactive_preview(rawGPU.value, 1);
    const auto proxyCpu = render(rawCPU, request, false), proxyGpu = render(rawGPU, request, true);
    compare(proxyCpu, proxyGpu, "WB interactive RAW");
    sony2fuji_session_set_interactive_preview(rawCPU.value, 0);
    sony2fuji_session_set_interactive_preview(rawGPU.value, 0);
    const auto exactCpu = render(rawCPU, request, false), exactGpu = render(rawGPU, request, true);
    compare(exactCpu, exactGpu, "WB exact RAW after proxy");
    require(proxyGpu != exactGpu, "proxy cache cannot supply exact render");
    request.wb_mode = SONY2FUJI_WB_CAMERA; request.temperature = 6500; request.tint = 0;
    request.intent = SONY2FUJI_INTENT_FINAL;
    uint32_t nativeWidth = 0, nativeHeight = 0;
    const auto nativeGPU = render(rawGPU, request, true, &nativeWidth, &nativeHeight);
    compare(render(rawCPU, request, false), nativeGPU, "native full-resolution pixels");
    request.output_target = SONY2FUJI_TARGET_FILE; request.output_format = SONY2FUJI_OUTPUT_PNG;
    const std::string out = "full-gpu.png";
    request.output_path = out.c_str();
    const auto start = std::chrono::steady_clock::now();
    require(sony2fuji_process(rawGPU.value, &request, nullptr) == SONY2FUJI_STATUS_OK, "full native 16-bit PNG GPU export");
    require(sony2fuji_session_get_last_backend(rawGPU.value) == SONY2FUJI_BACKEND_GLES, "export actually used GLES");
    std::cout << "BENCH GPU native PNG_ms=" << std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() << std::endl;
    unsigned char header[26]{};
    std::ifstream file(out, std::ios::binary); file.read(reinterpret_cast<char*>(header), sizeof(header));
    auto dimension = [&](int offset) { return (uint32_t(header[offset]) << 24) | (uint32_t(header[offset + 1]) << 16) | (uint32_t(header[offset + 2]) << 8) | header[offset + 3]; };
    require(dimension(16) == nativeWidth && dimension(20) == nativeHeight && header[24] == 16,
        "native dimensions and bit depth");
    const std::string cpuOut = "full-cpu.png";
    request.output_path = cpuOut.c_str();
    const auto cpuStart = std::chrono::steady_clock::now();
    require(sony2fuji_process(rawCPU.value, &request, nullptr) == SONY2FUJI_STATUS_OK, "CPU native PNG export baseline");
    std::cout << "BENCH CPU native PNG_ms=" << std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - cpuStart).count() << std::endl;
}
