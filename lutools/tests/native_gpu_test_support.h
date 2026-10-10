#pragma once

#include "sony2fuji/ffi/sony2fuji_c.h"

namespace rawlabtest {
#if defined(SONY2FUJI_ENABLE_METAL)
constexpr auto nativeBackend = SONY2FUJI_BACKEND_METAL;
#elif defined(SONY2FUJI_ENABLE_GLES)
constexpr auto nativeBackend = SONY2FUJI_BACKEND_GLES;
#elif defined(SONY2FUJI_ENABLE_D3D11)
constexpr auto nativeBackend = SONY2FUJI_BACKEND_D3D11;
#else
constexpr auto nativeBackend = SONY2FUJI_BACKEND_CPU;
#endif

inline bool nativeGpuAvailable() {
    if (nativeBackend == SONY2FUJI_BACKEND_CPU) return false;
    sony2fuji_session* session = nullptr;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return false;
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_FORCE};
    sony2fuji_request request{};
    const unsigned char pixel[] = {96, 104, 112};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER; request.input_pixels = pixel;
    request.input_width = request.input_height = 1; request.input_is_linear = 1;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8; request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.brightness = request.contrast = request.saturation = 1; request.temperature = 6500;
    request.size_mode = SONY2FUJI_SIZE_NATIVE; request.intent = SONY2FUJI_INTENT_FINAL;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
    sony2fuji_buffer output{};
    const bool available = sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK &&
        sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_OK &&
        sony2fuji_session_get_last_backend(session) == nativeBackend;
    sony2fuji_release_buffer(&output); sony2fuji_session_destroy(session);
    return available;
}
} // namespace rawlabtest
