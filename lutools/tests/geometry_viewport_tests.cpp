#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/wavelet_cache.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {

void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

struct Session {
    sony2fuji_session* value = nullptr;
    Session() { check(sony2fuji_session_create(&value) == SONY2FUJI_STATUS_OK, "create"); }
    ~Session() { sony2fuji_session_destroy(value); }
};

struct Frame {
    uint32_t width, height, native_width, native_height;
    std::vector<unsigned char> pixels;
};

Frame render(Session& session, const sony2fuji_request& request, bool viewport) {
    check(sony2fuji_session_set_viewport_preview(session.value, viewport) == SONY2FUJI_STATUS_OK, "viewport");
    sony2fuji_buffer buffer{};
    check(sony2fuji_process(session.value, &request, &buffer) == SONY2FUJI_STATUS_OK, "render");
    Frame result{buffer.width, buffer.height, 0, 0, {}};
    check(sony2fuji_session_get_geometry_size(session.value, &result.native_width,
        &result.native_height) == SONY2FUJI_STATUS_OK, "native size");
    const auto* bytes = static_cast<const unsigned char*>(buffer.data);
    result.pixels.assign(bytes, bytes + buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);
    return result;
}

sony2fuji_request requestFor(const std::vector<unsigned char>& pixels, int width, int height) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER;
    request.input_pixels = pixels.data(); request.input_width = width; request.input_height = height;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB; request.input_is_linear = 1;
    request.temperature = 6500; request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.brightness = request.contrast = request.saturation = 1;
    request.sharpening = .7f;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.intent = SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge = 31;
    return request;
}

void approximationTest() {
    const int width = 257, height = 193;
    std::vector<unsigned char> pixels(width * height * 3);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        const auto i = (y * width + x) * 3;
        pixels[i] = 30 + x * 150 / width;
        pixels[i + 1] = 30 + y * 150 / height;
        pixels[i + 2] = 80 + int(30 * std::sin(x * .07) * std::cos(y * .05));
    }
    auto request = requestFor(pixels, width, height);
    Session session;
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    check(sony2fuji_session_set_gpu_config(session.value, &gpu) == SONY2FUJI_STATUS_OK, "GPU");
    sony2fuji_geometry_config geometry{SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(geometry),
        .125f, .25f, .75f, .5f, 1, 1, 0, 7};
    check(sony2fuji_session_set_geometry(session.value, &geometry) == SONY2FUJI_STATUS_OK, "geometry");
    const auto exact = render(session, request, false), reduced = render(session, request, true);
    check(exact.width == reduced.width && exact.height == reduced.height, "preview dimensions changed");
    check(exact.native_width == reduced.native_width && exact.native_height == reduced.native_height,
        "full geometry dimensions changed");
    check(exact.pixels != reduced.pixels, "active geometry must honor reduced viewport processing");
    request.intent = SONY2FUJI_INTENT_FINAL; request.preview_long_edge = 0;
    const auto final = render(session, request, false), after = render(session, request, true);
    check(final.pixels == after.pixels, "FINAL must ignore viewport");
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    const auto native = render(session, request, true);
    check(final.pixels == native.pixels, "100 percent geometry must remain exact");
}

void rawWaveletTest(const char* path) {
    Session session;
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    check(sony2fuji_session_set_gpu_config(session.value, &gpu) == SONY2FUJI_STATUS_OK, "RAW CPU");
    sony2fuji_geometry_config geometry{SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(geometry),
        .125f, .25f, .75f, .5f, 1, 0, 0, 3};
    check(sony2fuji_session_set_geometry(session.value, &geometry) == SONY2FUJI_STATUS_OK, "RAW geometry");
    sony2fuji_wavelet_denoise_config wavelet{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION,
        sizeof(wavelet), 1, 40, 30, 20};
    check(sony2fuji_session_set_wavelet_denoise(session.value, &wavelet) == SONY2FUJI_STATUS_OK, "wavelet");
    const std::vector<unsigned char> pixels(3);
    auto request = requestFor(pixels, 1, 1);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = path;
    request.input_pixels = nullptr; request.preview_long_edge = 64; request.sharpening = 0;
    const auto reduced = render(session, request, true);
    const auto first = sony2fuji::waveletCacheDiagnostics(session.value);
    check(render(session, request, true).pixels == reduced.pixels, "repeated RAW geometry proxy changed");
    const auto hit = sony2fuji::waveletCacheDiagnostics(session.value);
    check(hit.outputHits == first.outputHits + 1 && hit.filterRuns == first.filterRuns,
        "RAW geometry proxy did not reuse reduced wavelet output");
    request.intent = SONY2FUJI_INTENT_FINAL; request.preview_long_edge = 0;
    request.size_mode = SONY2FUJI_SIZE_EXACT; request.target_width = 64; request.target_height = 48;
    const auto exact = render(session, request, true);
    const auto final = sony2fuji::waveletCacheDiagnostics(session.value);
    check(final.filterRuns == hit.filterRuns + 1, "reduced wavelet output served an exact request");
    check(render(session, request, false).pixels == exact.pixels, "exact wavelet cache depends on viewport flag");
    Session fresh;
    check(sony2fuji_session_set_gpu_config(fresh.value, &gpu) == SONY2FUJI_STATUS_OK, "fresh CPU");
    check(sony2fuji_session_set_geometry(fresh.value, &geometry) == SONY2FUJI_STATUS_OK, "fresh geometry");
    check(sony2fuji_session_set_wavelet_denoise(fresh.value, &wavelet) == SONY2FUJI_STATUS_OK, "fresh wavelet");
    check(render(fresh, request, false).pixels == exact.pixels, "proxy history changed exact RAW wavelet pixels");
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.target_width = exact.native_width; request.target_height = exact.native_height;
    const auto native = render(session, request, false);
    check(render(session, request, true).pixels == native.pixels,
        "100 percent geometry wavelet viewport must remain byte-identical to exact processing");
    std::cout << "PASS RAW geometry reduced wavelet cache cannot serve exact requests\n";
}

} // namespace

int main(int argc, char** argv) {
    try {
        approximationTest();
        if (argc == 2) rawWaveletTest(argv[1]);
        std::cout << "PASS geometry viewport approximation and exact requests\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
