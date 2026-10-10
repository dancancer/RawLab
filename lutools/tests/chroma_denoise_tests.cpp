#include "core/chroma_denoise.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "native_gpu_test_support.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <random>
#include <fstream>
#include <vector>

int main(int argc, char** argv) {
    const bool nativeGpu = rawlabtest::nativeGpuAvailable();
    if (argc == 4) {
        std::ifstream input(argv[1],std::ios::binary);
        uint32_t dimensions[2];
        input.read(reinterpret_cast<char*>(dimensions),sizeof(dimensions));
        assert(input && dimensions[0] > 0 && dimensions[1] > 0);
        sony2fuji::ImageData fixture;
        fixture.width = dimensions[0]; fixture.height = dimensions[1];
        fixture.pixels.resize(static_cast<size_t>(fixture.width)*fixture.height);
        input.read(reinterpret_cast<char*>(fixture.pixels.data()),fixture.pixels.size()*sizeof(sony2fuji::RGB));
        assert(input);
        sony2fuji::ChromaDenoiseDiagnostics diagnostics;
        assert(sony2fuji::applyChromaDenoise(fixture,std::stoi(argv[3]),&diagnostics) == sony2fuji::ErrorCode::Success);
        std::ofstream output(argv[2],std::ios::binary);
        output.write(reinterpret_cast<const char*>(dimensions),sizeof(dimensions));
        output.write(reinterpret_cast<const char*>(fixture.pixels.data()),fixture.pixels.size()*sizeof(sony2fuji::RGB));
        assert(output);
        std::cout << diagnostics.flatTiles << ' ' << diagnostics.confidence << ' ' << diagnostics.applied << '\n';
        return 0;
    }
    sony2fuji::ImageData image;
    image.width = image.height = 256;
    image.pixels.resize(256 * 256);
    std::mt19937 rng(8421);
    std::normal_distribution<float> noise(0, .025f);
    for (auto& p : image.pixels) p = {.45f + noise(rng), .45f + noise(rng), .45f + noise(rng)};
    const auto original = image;
    assert(sony2fuji::applyChromaDenoise(image, 0) == sony2fuji::ErrorCode::Success);
    for (size_t i = 0; i < image.pixels.size(); ++i) assert(image.pixels[i].r == original.pixels[i].r);
    assert(sony2fuji::applyChromaDenoise(image, 3) == sony2fuji::ErrorCode::InvalidFormat);
    assert(sony2fuji::applyChromaDenoise(image, 1) == sony2fuji::ErrorCode::Success);
    double before = 0, after = 0;
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        const auto a = original.pixels[i], b = image.pixels[i];
        before += (a.r-a.g)*(a.r-a.g) + (a.b-a.g)*(a.b-a.g);
        after += (b.r-b.g)*(b.r-b.g) + (b.b-b.g)*(b.b-b.g);
        assert(std::isfinite(b.r) && std::isfinite(b.g) && std::isfinite(b.b));
    }
    assert(after < before * .5);
    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_chroma_denoise(session, 1) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_chroma_denoise(session, -1) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER;
    std::vector<unsigned char> pixels(256*256*3);
    for (size_t i = 0; i < original.pixels.size(); ++i) {
        pixels[i*3] = static_cast<unsigned char>(original.pixels[i].r*255);
        pixels[i*3+1] = static_cast<unsigned char>(original.pixels[i].g*255);
        pixels[i*3+2] = static_cast<unsigned char>(original.pixels[i].b*255);
    }
    request.input_pixels = pixels.data();
    request.input_width = request.input_height = 256;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.input_is_linear = 1;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_EXACT;
    request.target_width = request.target_height = 100;
    request.brightness = request.contrast = request.saturation = 1;
    request.temperature = 6500;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    auto render = [&]() {
        sony2fuji_buffer buffer{};
        assert(sony2fuji_process(session,&request,&buffer) == SONY2FUJI_STATUS_OK);
        const auto* bytes = static_cast<const unsigned char*>(buffer.data);
        std::vector<unsigned char> result(bytes,bytes+buffer.size_bytes);
        sony2fuji_release_buffer(&buffer);
        return result;
    };
    sony2fuji_gpu_config config{};
    config.version = SONY2FUJI_GPU_CONFIG_VERSION; config.struct_size = sizeof(config);
    config.mode = SONY2FUJI_GPU_AUTO;
    assert(sony2fuji_session_set_gpu_config(session,&config) == SONY2FUJI_STATUS_OK);
    for (int mode : {1,2}) {
        assert(sony2fuji_session_set_chroma_denoise(session,mode) == SONY2FUJI_STATUS_OK);
        request.intent = SONY2FUJI_INTENT_PREVIEW;
        const auto preview = render();
        assert(sony2fuji_session_get_last_backend(session) ==
            (nativeGpu ? rawlabtest::nativeBackend : SONY2FUJI_BACKEND_CPU));
        request.intent = SONY2FUJI_INTENT_FINAL;
        assert(render() == preview);
    }
    config.mode = SONY2FUJI_GPU_FORCE;
    assert(sony2fuji_session_set_gpu_config(session,&config) == SONY2FUJI_STATUS_OK);
    sony2fuji_buffer rejected{};
    if (nativeGpu) {
        assert(sony2fuji_process(session,&request,&rejected) == SONY2FUJI_STATUS_OK);
        assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
        sony2fuji_release_buffer(&rejected);
    } else assert(sony2fuji_process(session,&request,&rejected) == SONY2FUJI_STATUS_PROCESSING_ERROR);
    sony2fuji_session_destroy(session);
    std::cout << "PASS: chroma defaults, validation, denoising, preview/final parity and explicit GPU fallback\n";
}
