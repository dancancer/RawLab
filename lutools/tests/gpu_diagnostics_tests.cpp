#include "sony2fuji/ffi/sony2fuji_c.h"
#include "native_gpu_test_support.h"
#include <cassert>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

namespace {

sony2fuji_request makeBufferRequest(const std::vector<uint8_t>& pixels, uint32_t width, uint32_t height,
                                    sony2fuji_input_type inputType = SONY2FUJI_INPUT_BUFFER) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = inputType;
    request.input_pixels = pixels.data();
    request.input_width = width;
    request.input_height = height;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGBA8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.temperature = 6500.f;
    request.brightness = 1.f;
    request.contrast = 1.f;
    request.saturation = 1.f;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGBA8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.intent = SONY2FUJI_INTENT_FINAL;
    return request;
}

void setGpuMode(sony2fuji_session* session, sony2fuji_gpu_mode mode) {
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), mode};
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
}

void resetAllSessionControls(sony2fuji_session* session) {
    sony2fuji_tone_controls_config tc{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(tc), 0, 0, 0};
    assert(sony2fuji_session_set_tone_controls(session, &tc) == SONY2FUJI_STATUS_OK);
    sony2fuji_atmosphere_config atmo{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION, sizeof(atmo), 0, 0};
    assert(sony2fuji_session_set_atmosphere(session, &atmo) == SONY2FUJI_STATUS_OK);
    sony2fuji_tone_curve_set_config curves{};
    curves.version = SONY2FUJI_TONE_CURVE_SET_CONFIG_VERSION;
    curves.struct_size = sizeof(curves);
    for (auto& c : curves.curves) {
        c.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
        c.struct_size = sizeof(c);
        c.mode = SONY2FUJI_CURVE_LEGACY;
    }
    assert(sony2fuji_session_set_tone_curves(session, &curves) == SONY2FUJI_STATUS_OK);
    sony2fuji_wavelet_denoise_config wavelet{};
    wavelet.version = SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION;
    wavelet.struct_size = sizeof(wavelet);
    assert(sony2fuji_session_set_wavelet_denoise(session, &wavelet) == SONY2FUJI_STATUS_OK);
    sony2fuji_geometry_config geom{};
    geom.version = SONY2FUJI_GEOMETRY_CONFIG_VERSION;
    geom.struct_size = sizeof(geom);
    geom.crop_width = 1.f;
    geom.crop_height = 1.f;
    assert(sony2fuji_session_set_geometry(session, &geom) == SONY2FUJI_STATUS_OK);
}

void expectFallback(sony2fuji_session* session, const sony2fuji_request& req,
                    sony2fuji_gpu_fallback_reason expectedAutoReason,
                    sony2fuji_gpu_fallback_reason expectedForceReason,
                    const char* label) {
    setGpuMode(session, SONY2FUJI_GPU_AUTO);
    sony2fuji_buffer out{};
    assert(sony2fuji_process(session, &req, &out) == SONY2FUJI_STATUS_OK);
    sony2fuji_release_buffer(&out);
    assert(sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_CPU);
    assert(sony2fuji_session_get_gpu_fallback_reason(session) == expectedAutoReason);
    assert(sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_NONE);

    setGpuMode(session, SONY2FUJI_GPU_FORCE);
    const auto forceStatus = sony2fuji_process(session, &req, &out);
    sony2fuji_release_buffer(&out);
    if (forceStatus != SONY2FUJI_STATUS_UNSUPPORTED) {
        std::cerr << label << ": expected UNSUPPORTED, got " << forceStatus << "\n";
        assert(false);
    }
    assert(sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_FORCE_GPU);
    assert(sony2fuji_session_get_gpu_fallback_reason(session) == expectedForceReason);
}

} // namespace

int main() {
    assert(sony2fuji_session_get_gpu_fallback_reason(nullptr) == SONY2FUJI_GPU_FALLBACK_NONE);
    assert(std::strcmp(sony2fuji_session_get_gpu_error(nullptr), "") == 0);

    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_processing_version(session, SONY2FUJI_PROCESSING_BASIC_V3) == SONY2FUJI_STATUS_OK);

    std::vector<uint8_t> pixels(16 * 16 * 4, 255);
    for (size_t i = 0; i < 16 * 16; ++i) {
        pixels[i * 4 + 0] = 128;
        pixels[i * 4 + 1] = 128;
        pixels[i * 4 + 2] = 128;
    }
    const auto bufferReq = makeBufferRequest(pixels, 16, 16, SONY2FUJI_INPUT_BUFFER);
    const auto displayReq = makeBufferRequest(pixels, 16, 16, SONY2FUJI_INPUT_DISPLAY_BUFFER);

    // 1. Display buffer falls back to CPU with DISPLAY_INPUT.
    expectFallback(session, displayReq,
                   SONY2FUJI_GPU_FALLBACK_DISPLAY_INPUT,
                   SONY2FUJI_GPU_FALLBACK_DISPLAY_INPUT,
                   "display_input");

    // 2. BasicV3 tone controls.
    resetAllSessionControls(session);
    {
        sony2fuji_tone_controls_config tc{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(tc), 0.4f, 0.f, 0.f};
        assert(sony2fuji_session_set_tone_controls(session, &tc) == SONY2FUJI_STATUS_OK);
        expectFallback(session, bufferReq,
                       SONY2FUJI_GPU_FALLBACK_BASIC_V3_CONTROLS,
                       SONY2FUJI_GPU_FALLBACK_BASIC_V3_CONTROLS,
                       "basic_v3_controls");
    }

    // 3. Atmosphere (clarity/dehaze).
    resetAllSessionControls(session);
    {
        sony2fuji_atmosphere_config atmo{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION, sizeof(atmo), 0.4f, 0.f};
        assert(sony2fuji_session_set_atmosphere(session, &atmo) == SONY2FUJI_STATUS_OK);
        expectFallback(session, bufferReq,
                       SONY2FUJI_GPU_FALLBACK_ATMOSPHERE,
                       SONY2FUJI_GPU_FALLBACK_ATMOSPHERE,
                       "atmosphere");
    }

    // 4. GPU-supported channel curves run on native GPU; precision-limited channel curve falls back with CURVES.
    resetAllSessionControls(session);
    {
        sony2fuji_tone_curve_set_config curves{};
        curves.version = SONY2FUJI_TONE_CURVE_SET_CONFIG_VERSION;
        curves.struct_size = sizeof(curves);
        for (auto& c : curves.curves) {
            c.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
            c.struct_size = sizeof(c);
            c.mode = SONY2FUJI_CURVE_LEGACY;
        }
        curves.curves[1].mode = SONY2FUJI_CURVE_CUSTOM;
        curves.curves[1].count = 3;
        curves.curves[1].points[0] = {0.0, 0.0};
        curves.curves[1].points[1] = {0.5, 0.6};
        curves.curves[1].points[2] = {1.0, 1.0};
        assert(sony2fuji_session_set_tone_curves(session, &curves) == SONY2FUJI_STATUS_OK);
        if (rawlabtest::nativeGpuAvailable()) {
            setGpuMode(session, SONY2FUJI_GPU_FORCE);
            sony2fuji_buffer out{};
            assert(sony2fuji_process(session, &bufferReq, &out) == SONY2FUJI_STATUS_OK);
            sony2fuji_release_buffer(&out);
            assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
            assert(sony2fuji_session_get_gpu_fallback_reason(session) == SONY2FUJI_GPU_FALLBACK_NONE);
        }

        curves.curves[1].count = 4;
        curves.curves[1].points[0] = {0.0, 0.0};
        curves.curves[1].points[1] = {0.5, 0.1};
        curves.curves[1].points[2] = {std::nextafter(0.5, 1.0), 0.9};
        curves.curves[1].points[3] = {1.0, 1.0};
        assert(sony2fuji_session_set_tone_curves(session, &curves) == SONY2FUJI_STATUS_OK);
        expectFallback(session, bufferReq,
                       SONY2FUJI_GPU_FALLBACK_CURVES,
                       SONY2FUJI_GPU_FALLBACK_CURVES,
                       "curves");
    }

    // 5. C5 wavelet denoise: Force rejects with C5_WAVELET; Auto runs C5 on CPU and photo stage on GPU if available.
    resetAllSessionControls(session);
    {
        sony2fuji_wavelet_denoise_config wavelet{};
        wavelet.version = SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION;
        wavelet.struct_size = sizeof(wavelet);
        wavelet.enabled = 1;
        wavelet.luma = 12.f;
        wavelet.chroma = 50.f;
        wavelet.coarse = 50.f;
        assert(sony2fuji_session_set_wavelet_denoise(session, &wavelet) == SONY2FUJI_STATUS_OK);

        setGpuMode(session, SONY2FUJI_GPU_FORCE);
        sony2fuji_buffer out{};
        assert(sony2fuji_process(session, &bufferReq, &out) == SONY2FUJI_STATUS_UNSUPPORTED);
        sony2fuji_release_buffer(&out);
        assert(sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_FORCE_GPU);
        assert(sony2fuji_session_get_gpu_fallback_reason(session) == SONY2FUJI_GPU_FALLBACK_C5_WAVELET);

        setGpuMode(session, SONY2FUJI_GPU_AUTO);
        assert(sony2fuji_process(session, &bufferReq, &out) == SONY2FUJI_STATUS_OK);
        sony2fuji_release_buffer(&out);
        assert(sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_NONE);
        if (rawlabtest::nativeGpuAvailable()) {
            assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
            assert(sony2fuji_session_get_gpu_fallback_reason(session) == SONY2FUJI_GPU_FALLBACK_NONE);
        } else {
            assert(sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_CPU);
        }
    }

    // 6. Active geometry rejects Force GPU with GEOMETRY.
    resetAllSessionControls(session);
    {
        sony2fuji_geometry_config geom{};
        geom.version = SONY2FUJI_GEOMETRY_CONFIG_VERSION;
        geom.struct_size = sizeof(geom);
        geom.crop_width = 1.f;
        geom.crop_height = 1.f;
        geom.straighten_degrees = 12.f;
        assert(sony2fuji_session_set_geometry(session, &geom) == SONY2FUJI_STATUS_OK);
        setGpuMode(session, SONY2FUJI_GPU_FORCE);
        sony2fuji_buffer out{};
        assert(sony2fuji_process(session, &bufferReq, &out) == SONY2FUJI_STATUS_UNSUPPORTED);
        sony2fuji_release_buffer(&out);
        assert(sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_FORCE_GPU);
        assert(sony2fuji_session_get_gpu_fallback_reason(session) == SONY2FUJI_GPU_FALLBACK_GEOMETRY);
    }

    // 7. Resetting back to GPU-capable controls clears Force GPU / fallback state.
    resetAllSessionControls(session);
    setGpuMode(session, SONY2FUJI_GPU_AUTO);
    {
        sony2fuji_buffer out{};
        assert(sony2fuji_process(session, &bufferReq, &out) == SONY2FUJI_STATUS_OK);
        sony2fuji_release_buffer(&out);
        assert(sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_NONE);
        if (rawlabtest::nativeGpuAvailable()) {
            assert(sony2fuji_session_get_last_backend(session) == rawlabtest::nativeBackend);
            assert(sony2fuji_session_get_gpu_fallback_reason(session) == SONY2FUJI_GPU_FALLBACK_NONE);
            assert(std::strcmp(sony2fuji_session_get_gpu_error(session), "") == 0);
        } else {
            assert(sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_CPU);
            const auto reason = sony2fuji_session_get_gpu_fallback_reason(session);
            assert(reason == SONY2FUJI_GPU_FALLBACK_GPU_DISABLED ||
                   reason == SONY2FUJI_GPU_FALLBACK_NO_ADAPTER);
        }
    }

    // 8. Non-GPU control diagnostics survive an HSL probe without clearing or leaking errors.
    {
        sony2fuji_tone_controls_config tc{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(tc), 0.3f, 0.f, 0.f};
        assert(sony2fuji_session_set_tone_controls(session, &tc) == SONY2FUJI_STATUS_OK);
        setGpuMode(session, SONY2FUJI_GPU_AUTO);
        sony2fuji_buffer out{};
        assert(sony2fuji_process(session, &bufferReq, &out) == SONY2FUJI_STATUS_OK);
        sony2fuji_release_buffer(&out);
        assert(sony2fuji_session_get_gpu_fallback_reason(session) == SONY2FUJI_GPU_FALLBACK_BASIC_V3_CONTROLS);

        sony2fuji_hsl_probe* probe = nullptr;
        assert(sony2fuji_session_create_hsl_probe(session, &bufferReq, 1, 1, &probe) == SONY2FUJI_STATUS_OK);
        sony2fuji_hsl_probe_destroy(probe);
        assert(sony2fuji_session_get_gpu_fallback_reason(session) == SONY2FUJI_GPU_FALLBACK_BASIC_V3_CONTROLS);
        assert(sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_NONE);
    }

    sony2fuji_session_destroy(session);
    std::cout << "PASS: gpu_diagnostics\n";
    return 0;
}
