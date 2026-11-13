#include "core/photo_color.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "native_gpu_test_support.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <limits>
#include <vector>

using namespace sony2fuji;

static sony2fuji_request requestFor(const std::vector<uint8_t>& pixels) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER;
    request.input_pixels = pixels.data();
    request.input_width = static_cast<uint32_t>(pixels.size() / 3);
    request.input_height = 1;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.temperature = 6500;
    request.brightness = request.contrast = request.saturation = 1;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.intent = SONY2FUJI_INTENT_FINAL;
    return request;
}

static std::vector<uint8_t> render(sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    assert(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_OK);
    const auto* data = static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> result(data, data + buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);
    return result;
}

static void hslAlgorithm() {
    HslOptions options;
    const RGB red(.8f, .2f, .2f), green(.2f, .8f, .2f), gray(.4f, .4f, .4f);
    auto identity = applyHsl(red, options);
    assert(identity.r == red.r && identity.g == red.g && identity.b == red.b);
    options.saturation[0] = -100;
    const auto desaturated = applyHsl(red, options);
    assert(std::abs(desaturated.r - .5f) < 1e-6f && desaturated.r == desaturated.g);
    const auto isolated = applyHsl(green, options);
    assert(std::abs(isolated.r - green.r) < 1e-6f && std::abs(isolated.g - green.g) < 1e-6f);
    options.hue[0] = 100;
    options.lightness[0] = 60;
    const auto unchangedGray = applyHsl(gray, options);
    assert(unchangedGray.r == gray.r && unchangedGray.g == gray.g && unchangedGray.b == gray.b);
    options.saturation[0] = 0;
    const auto warm = applyHsl(red, options);
    assert(warm.g > warm.b && warm.r > red.r);
    const auto left = applyHsl(RGB(.8f,.2f,.20001f), options);
    const auto right = applyHsl(RGB(.8f,.20001f,.2f), options);
    assert(std::abs(left.r-right.r) + std::abs(left.g-right.g) + std::abs(left.b-right.b) < 1e-4f);
    options.hue[0] = std::numeric_limits<float>::quiet_NaN();
    assert(!options.valid());
}

static void hslSession() {
    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    auto pixels = std::vector<uint8_t>{220,60,60, 60,220,60, 100,100,100};
    sony2fuji_gpu_config off{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(off), SONY2FUJI_GPU_OFF};
    assert(sony2fuji_session_set_gpu_config(session, &off) == SONY2FUJI_STATUS_OK);
    const auto request = requestFor(pixels);
    const auto original = render(session, request);
    sony2fuji_hsl_config config{};
    config.version = SONY2FUJI_HSL_CONFIG_VERSION;
    config.struct_size = sizeof(config);
    assert(sony2fuji_session_set_hsl(session, &config) == SONY2FUJI_STATUS_OK);
    assert(render(session, request) == original);
    config.saturation[0] = -100;
    assert(sony2fuji_session_set_hsl(session, &config) == SONY2FUJI_STATUS_OK);
    const auto changed = render(session, request);
    assert(changed != original && changed[0] == changed[1] && changed[1] == changed[2]);
    assert(std::equal(changed.begin()+3, changed.end(), original.begin()+3));
    config.lightness[1] = 101;
    assert(sony2fuji_session_set_hsl(session, &config) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    assert(render(session, request) == changed);
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_FORCE};
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    sony2fuji_buffer buffer{};
    const bool available = rawlabtest::nativeGpuAvailable();
    const auto status = sony2fuji_process(session, &request, &buffer);
    if (available) {
        assert(status == SONY2FUJI_STATUS_OK);
        assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
    // Without a compiled GPU backend a Force request must say "unsupported",
    // never fake a CPU result and never report a processing failure.
    } else assert(status == SONY2FUJI_STATUS_UNSUPPORTED);
    sony2fuji_release_buffer(&buffer);
    gpu.mode = SONY2FUJI_GPU_AUTO;
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    const auto automatic = render(session, request);
    assert(automatic.size() == changed.size());
    for (size_t i = 0; i < changed.size(); ++i) assert(std::abs(int(automatic[i])-int(changed[i])) <= 2);
    assert(sony2fuji_session_get_last_backend(session) == (available ? rawlabtest::nativeBackend : SONY2FUJI_BACKEND_CPU));
    config = {};
    config.version = SONY2FUJI_HSL_CONFIG_VERSION;
    config.struct_size = sizeof(config);
    assert(sony2fuji_session_set_hsl(session, &config) == SONY2FUJI_STATUS_OK);
    gpu.mode = SONY2FUJI_GPU_OFF;
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    assert(render(session, request) == original);
    sony2fuji_session_destroy(session);
}

static void hslNearGrayContinuity() {
    HslOptions options;
    for (size_t channel = 0; channel < 8; ++channel) {
        options.hue[channel] = channel % 2 == 0 ? -100 : 100;
        options.saturation[channel] = channel % 2 == 0 ? 100 : -100;
        options.lightness[channel] = channel % 2 == 0 ? -100 : 100;
    }
    for (float level : {.02f, .25f, .5f, .98f}) {
        for (float epsilon : {0.f, 5e-7f, 2e-6f, 1e-5f, 1e-4f}) {
            for (const RGB pixel : {RGB(level + epsilon, level, level),
                     RGB(level, level + epsilon, level), RGB(level, level, level + epsilon)}) {
                const auto adjusted = applyHsl(pixel, options);
                assert(std::abs(adjusted.r - pixel.r) < 1.f / 255);
                assert(std::abs(adjusted.g - pixel.g) < 1.f / 255);
                assert(std::abs(adjusted.b - pixel.b) < 1.f / 255);
            }
        }
    }
    options = {};
    options.lightness[0] = 40;
    for (float spread : {.5f / 255, 1.f / 255, 2.f / 255}) {
        const RGB pixel(.2f + spread, .2f, .2f);
        const auto adjusted = applyHsl(pixel, options);
        const float sourceLightness = .2f + spread * .5f;
        const float weight = spread < 1.f / 255 ? .5f : 1.f;
        const float lightness = (std::max({adjusted.r, adjusted.g, adjusted.b}) +
            std::min({adjusted.r, adjusted.g, adjusted.b})) * .5f;
        assert(std::abs(lightness - (sourceLightness + .2f * weight)) < 1e-5f);
    }
    options.lightness[0] = 60;
    const float boundary = 1.f / 255;
    const auto below = applyHsl(RGB(.4f + boundary - 1e-7f, .4f, .4f), options);
    const auto above = applyHsl(RGB(.4f + boundary + 1e-7f, .4f, .4f), options);
    assert(std::abs(below.r - above.r) < 1e-5f);
    assert(std::abs(below.g - above.g) < 1e-5f);
    assert(std::abs(below.b - above.b) < 1e-5f);
}

static void autoExposure() {
    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    std::vector<uint8_t> pixels(300, 32);
    auto request = requestFor(pixels);
    request.input_is_linear = 1;
    float ev = 0;
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &ev) == SONY2FUJI_STATUS_OK);
    assert(std::abs(ev - std::log2(.1845f / (32.0f/255))) < 1e-5f && ev > 0);
    const float original = ev;
    request.exposure_ev = 3;
    request.contrast = 2;
    request.saturation = .3f;
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &ev) == SONY2FUJI_STATUS_OK);
    assert(ev == original);
    std::fill(pixels.begin(), pixels.end(), 200);
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &ev) == SONY2FUJI_STATUS_OK && ev < 0);
    std::fill(pixels.begin(), pixels.end(), 1);
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &ev) == SONY2FUJI_STATUS_OK && ev == 4);
    std::fill(pixels.begin(), pixels.end(), 0);
    ev = 123;
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &ev) == SONY2FUJI_STATUS_UNSUPPORTED && ev == 123);
    request.version = 0;
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &ev) == SONY2FUJI_STATUS_INVALID_ARGUMENT && ev == 123);
    assert(sony2fuji_session_estimate_auto_exposure(nullptr, &request, &ev) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    request.version = SONY2FUJI_REQUEST_VERSION;
    std::fill(pixels.begin(), pixels.end(), 128);
    request.wb_mode = static_cast<sony2fuji_wb_mode>(99);
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &ev) == SONY2FUJI_STATUS_INVALID_ARGUMENT && ev == 123);
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.input_color_space = static_cast<sony2fuji_color_space>(99);
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &ev) == SONY2FUJI_STATUS_INVALID_ARGUMENT && ev == 123);
    ImageData sample(100, 100);
    std::fill(sample.pixels.begin(), sample.pixels.end(), RGB(.01f,.01f,.01f));
    std::fill(sample.pixels.begin(), sample.pixels.begin()+100, RGB(8,8,8));
    assert(estimateAutoExposure(sample, ColorSpace::sRGB, RGB(1,1,1), ev));
    assert(ev <= .001f);
    sony2fuji_session_destroy(session);
}

static void rawExposure(const char* path) {
    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    const std::vector<uint8_t> placeholder{128,128,128};
    auto request = requestFor(placeholder);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = path;
    assert(sony2fuji_session_set_raw_exposure_mode(session, SONY2FUJI_EXPOSURE_PREVIEW) == SONY2FUJI_STATUS_OK);
    float ev = 0, repeated = 0;
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &ev) == SONY2FUJI_STATUS_OK);
    request.exposure_ev = 2;
    assert(sony2fuji_session_estimate_auto_exposure(session, &request, &repeated) == SONY2FUJI_STATUS_OK);
    assert(ev == repeated && std::isfinite(ev) && ev >= -4 && ev <= 4);
    request.preview_long_edge = 64;
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    const auto original = render(session, request);
    sony2fuji_hsl_config config{};
    config.version = SONY2FUJI_HSL_CONFIG_VERSION;
    config.struct_size = sizeof(config);
    std::fill(std::begin(config.saturation), std::end(config.saturation), -100);
    assert(sony2fuji_session_set_hsl(session, &config) == SONY2FUJI_STATUS_OK);
    assert(render(session, request) != original);
    sony2fuji_session_destroy(session);
}

int main(int argc, char** argv) {
    hslAlgorithm(); hslNearGrayContinuity(); hslSession(); autoExposure();
    if (argc > 1) {
        const char* argRaw = *argv[1] ? argv[1] : nullptr;
        const char* envRaw = std::getenv("RAWLAB_TEST_RAW");
        if (envRaw && !*envRaw) envRaw = nullptr;
        const char* rawPath = argRaw ? argRaw : envRaw;
        if (!rawPath) {
            std::cout << "SKIP photo_color_raw: supply SONY2FUJI_TEST_RAW or RAWLAB_TEST_RAW\n";
            return 77;
        }
        if (!std::filesystem::is_regular_file(std::filesystem::u8path(rawPath))) {
            std::cerr << "FAIL photo_color_raw: RAW sample does not exist: " << rawPath << '\n';
            return 1;
        }
        rawExposure(rawPath);
    } else std::cout << "Real RAW fixture not supplied; RAW coverage skipped\n";
    std::cout << "HSL and automatic exposure tests passed\n";
}
