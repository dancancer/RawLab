#include "core/photo_effects.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "native_gpu_test_support.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <vector>

using namespace sony2fuji;

static ImageData flat(float value = 0.5f) {
    ImageData image(513, 385);
    std::fill(image.pixels.begin(), image.pixels.end(), RGB(value, value, value));
    return image;
}

static double energy(const ImageData& image, float baseline = 0.5f) {
    double sum = 0;
    for (const auto& p : image.pixels) sum += (p.r - baseline) * (p.r - baseline);
    return sum / image.pixels.size();
}

static void algorithmTests() {
    PhotoEffectsOptions options;
    auto image = flat();
    applyPhotoEffects(image, options);
    assert(energy(image) == 0);
    options.vignetteAmount = -70;
    applyPhotoEffects(image, options);
    assert(image.pixels[0].r < 0.3f);
    assert(image.pixels[192 * 513 + 256].r == 0.5f);
    assert(std::abs(image.pixels[0].r - image.pixels.back().r) < 1e-6f);
    const auto dark = image;
    options.vignetteAmount = 70;
    image = flat(); applyPhotoEffects(image, options);
    assert(image.pixels[0].r > 0.7f);
    options.vignetteAmount = -70;
    options.vignetteMidpoint = 0;
    image = flat(); applyPhotoEffects(image, options);
    const double wide = energy(image);
    options.vignetteMidpoint = 100;
    image = flat(); applyPhotoEffects(image, options);
    assert(energy(image) < wide);
    options.vignetteMidpoint = 50;
    options.vignetteHighlights = 100;
    image = flat(0.95f); applyPhotoEffects(image, options);
    const float protectedHighlight = image.pixels[0].r;
    options.vignetteHighlights = 0;
    image = flat(0.95f); applyPhotoEffects(image, options);
    assert(protectedHighlight > image.pixels[0].r + 0.1f);
    options.vignetteRoundness = -100;
    image = flat(); applyPhotoEffects(image, options);
    assert(energy(image) != energy(dark));
    options.vignetteRoundness = 100;
    auto circular = flat(); applyPhotoEffects(circular, options);
    assert(energy(image) != energy(circular));
    options.vignetteFeather = 0;
    auto hard = flat(); applyPhotoEffects(hard, options);
    options.vignetteFeather = 100;
    auto soft = flat(); applyPhotoEffects(soft, options);
    assert(energy(hard) != energy(soft));

    options = PhotoEffectsOptions();
    options.grainAmount = 30;
    image = flat(); applyPhotoEffects(image, options);
    auto repeat = flat(); applyPhotoEffects(repeat, options);
    double mean = 0;
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        const auto p = image.pixels[i];
        assert(p.r == repeat.pixels[i].r && p.r == p.g && p.g == p.b);
        mean += p.r;
    }
    assert(std::abs(mean / image.pixels.size() - 0.5) < 0.002);
    const double lowEnergy = energy(image);
    assert(lowEnergy > 1e-5);
    options.grainAmount = 60;
    image = flat(); applyPhotoEffects(image, options);
    assert(std::abs(energy(image) / lowEnergy - 4) < 0.02);
    options.grainSize = 100;
    repeat = flat(); applyPhotoEffects(repeat, options);
    bool sizeChanged = false;
    for (size_t i = 0; i < image.pixels.size(); ++i)
        sizeChanged |= image.pixels[i].r != repeat.pixels[i].r;
    assert(sizeChanged);
    options.grainRoughness = 100;
    image = flat(); applyPhotoEffects(image, options);
    assert(image.pixels[0].r != repeat.pixels[0].r);
    for (float level : {0.f, 0.02f, 0.98f, 1.f}) {
        image = flat(level); applyPhotoEffects(image, options);
        for (const auto& p : image.pixels) assert(std::isfinite(p.r) && p.r >= 0 && p.r <= 1);
        assert(energy(image, level) < energy(repeat));
    }
}

static void apiTests() {
    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    sony2fuji_photo_effects_config options{SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION,
        sizeof(options), 0, 50, 0, 50, 0, 0, 25, 50};
    assert(sony2fuji_session_set_photo_effects(nullptr, &options) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    assert(sony2fuji_session_set_photo_effects(session, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    assert(sony2fuji_session_set_photo_effects(session, &options) == SONY2FUJI_STATUS_OK);
    auto invalid = options; invalid.grain_amount = 101;
    assert(sony2fuji_session_set_photo_effects(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    invalid = options; invalid.vignette_amount = std::numeric_limits<float>::quiet_NaN();
    assert(sony2fuji_session_set_photo_effects(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    invalid = options; invalid.struct_size = 0;
    assert(sony2fuji_session_set_photo_effects(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    invalid = options; invalid.version = 99;
    assert(sony2fuji_session_set_photo_effects(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    using Config = sony2fuji_photo_effects_config;
    const std::vector<std::pair<float Config::*, float>> fields{
        {&Config::vignette_amount, -100}, {&Config::vignette_midpoint, 0},
        {&Config::vignette_roundness, -100}, {&Config::vignette_feather, 0},
        {&Config::vignette_highlights, 0}, {&Config::grain_amount, 0},
        {&Config::grain_size, 0}, {&Config::grain_roughness, 0}};
    for (const auto& field : fields) {
        for (float bad : {field.second - 1, 101.f, std::numeric_limits<float>::quiet_NaN(),
                          std::numeric_limits<float>::infinity()}) {
            invalid = options; invalid.*field.first = bad;
            assert(sony2fuji_session_set_photo_effects(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
        }
    }

    std::vector<unsigned char> input(513 * 385 * 3, 80);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER; request.input_pixels = input.data();
    request.input_width = 513; request.input_height = 385;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB; request.input_is_linear = 1;
    request.brightness = request.contrast = request.saturation = 1; request.temperature = 6500;
    request.wb_mode = SONY2FUJI_WB_CAMERA; request.intent = SONY2FUJI_INTENT_FINAL;
    request.size_mode = SONY2FUJI_SIZE_EXACT; request.target_width = 128; request.target_height = 96;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    auto render = [&]() {
        sony2fuji_buffer buffer{};
        assert(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_OK);
        const auto* bytes = static_cast<const unsigned char*>(buffer.data);
        std::vector<unsigned char> result(bytes, bytes + buffer.size_bytes);
        sony2fuji_release_buffer(&buffer);
        return result;
    };
    const auto off = render();
    gpu.mode = SONY2FUJI_GPU_AUTO;
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    const auto autoOff = render();
    const auto autoBackend = sony2fuji_session_get_last_backend(session);
    gpu.mode = SONY2FUJI_GPU_OFF;
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    options.vignette_amount = -45; options.grain_amount = 65;
    assert(sony2fuji_session_set_photo_effects(session, &options) == SONY2FUJI_STATUS_OK);
    const auto final = render();
    assert(final != off && render() == final);
    invalid = options; invalid.grain_size = -1;
    assert(sony2fuji_session_set_photo_effects(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    assert(render() == final);
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    const auto native = render();
    request.size_mode = SONY2FUJI_SIZE_EXACT;
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    for (const auto& size : {std::pair<uint32_t, uint32_t>{64, 48}, {256, 192}}) {
        request.target_width = size.first; request.target_height = size.second;
        const auto preview = render();
        for (uint32_t y = 0; y < size.second; ++y) for (uint32_t x = 0; x < size.first; ++x) {
            const float sx = x * (512.f / (size.first - 1)), sy = y * (384.f / (size.second - 1));
            const int x0 = int(sx), y0 = int(sy), x1 = std::min(512, x0 + 1), y1 = std::min(384, y0 + 1);
            for (int c = 0; c < 3; ++c) {
                const auto sample = [&](int px, int py) { return native[(py * 513 + px) * 3 + c]; };
                const float top = sample(x0, y0) * (1 - sx + x0) + sample(x1, y0) * (sx - x0);
                const float bottom = sample(x0, y1) * (1 - sx + x0) + sample(x1, y1) * (sx - x0);
                const float expected = top * (1 - sy + y0) + bottom * (sy - y0);
                assert(std::abs(int(preview[(y * size.first + x) * 3 + c]) - expected) <= 1.01f);
            }
        }
    }
    request.target_width = 128; request.target_height = 96;
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    assert(render() == final);
    assert(sony2fuji_session_set_interactive_preview(session, 1) == SONY2FUJI_STATUS_OK);
    assert(render() == final);
    gpu.mode = SONY2FUJI_GPU_AUTO;
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    const auto accelerated = render();
    const bool nativeGpu = autoBackend == rawlabtest::nativeBackend && autoBackend != SONY2FUJI_BACKEND_CPU;
    if (nativeGpu) {
        assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
        for (size_t i = 0; i < final.size(); ++i) assert(std::abs(int(accelerated[i]) - int(final[i])) <= 2);
    } else assert(accelerated == final && sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_CPU);
    gpu.mode = SONY2FUJI_GPU_FORCE;
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    sony2fuji_buffer rejected{};
    if (nativeGpu) {
        assert(sony2fuji_process(session, &request, &rejected) == SONY2FUJI_STATUS_OK);
        assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
        sony2fuji_release_buffer(&rejected);
        assert(render() == accelerated);
    } else assert(sony2fuji_process(session, &request, &rejected) == SONY2FUJI_STATUS_PROCESSING_ERROR);
    gpu.mode = SONY2FUJI_GPU_OFF;
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    options.vignette_amount = options.grain_amount = 0;
    assert(sony2fuji_session_set_photo_effects(session, &options) == SONY2FUJI_STATUS_OK);
    request.intent = SONY2FUJI_INTENT_FINAL;
    assert(render() == off);
    gpu.mode = SONY2FUJI_GPU_AUTO;
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    assert(render() == autoOff && sony2fuji_session_get_last_backend(session) == autoBackend);
    sony2fuji_session_destroy(session);
}

int main() {
    algorithmTests();
    apiTests();
    std::cout << "PASS: vignette geometry, highlights, deterministic neutral grain, intensity, API validation, preview/export and GPU policy\n";
}
