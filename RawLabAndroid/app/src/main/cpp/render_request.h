#pragma once
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <cmath>
#include <stdexcept>
#include <limits>
#include <new>

namespace rawlab {
inline void checkStatus(sony2fuji_status status) {
    if (status == SONY2FUJI_STATUS_OUT_OF_MEMORY) throw std::bad_alloc();
    if (status == SONY2FUJI_STATUS_INVALID_ARGUMENT)
        throw std::invalid_argument(sony2fuji_status_message(status));
    if (status != SONY2FUJI_STATUS_OK) throw std::runtime_error(sony2fuji_status_message(status));
}

inline size_t previewByteCount(const sony2fuji_buffer& buffer) {
    const uint64_t row = static_cast<uint64_t>(buffer.width) * 4;
    if (!buffer.data || buffer.width == 0 || buffer.height == 0 ||
        buffer.pixel_format != SONY2FUJI_PIXEL_RGBA8 || buffer.stride_bytes < row ||
        buffer.height > std::numeric_limits<size_t>::max() / buffer.stride_bytes ||
        buffer.size_bytes < static_cast<size_t>(buffer.height - 1) * buffer.stride_bytes + row)
        throw std::runtime_error("Invalid preview buffer");
    return static_cast<size_t>(row) * buffer.height;
}

inline sony2fuji_request makeRequest(const char* input, const char* lut, const char* output,
    float strength, float exposure, bool customWb, float temperature, float tint,
    float highlights, float shadows, float contrast, float toneCurve, float saturation,
    float sharpening, int edge, bool png) {
    if (!input || !*input || !std::isfinite(strength) || strength < 0 || strength > 2 ||
        !std::isfinite(exposure) || exposure < -4 || exposure > 4 ||
        !std::isfinite(highlights) || highlights < -1 || highlights > 1 ||
        !std::isfinite(shadows) || shadows < -1 || shadows > 1 ||
        !std::isfinite(contrast) || contrast < -1 || contrast > 1 ||
        !std::isfinite(toneCurve) || toneCurve < -1 || toneCurve > 1 ||
        !std::isfinite(saturation) || saturation < -1 || saturation > 1 ||
        !std::isfinite(sharpening) || sharpening < 0 || sharpening > 2 ||
        !std::isfinite(temperature) || temperature < 2000 || temperature > 50000 ||
        !std::isfinite(tint) || tint < -150 || tint > 150 || (!output && (edge < 1 || edge > 1600))) {
        throw std::invalid_argument("Invalid render settings");
    }
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_path = input;
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.lut_path = lut;
    request.lut_strength = lut && *lut ? strength : 0;
    request.brightness = 1;
    request.contrast = 1 + contrast;
    request.saturation = 1 + saturation;
    for (auto& value : request.wb_mul) value = 1;
    request.wb_mode = customWb ? SONY2FUJI_WB_TEMPERATURE : SONY2FUJI_WB_CAMERA;
    request.temperature = customWb ? temperature : 6500;
    request.tint = customWb ? tint : 0;
    request.exposure_ev = exposure;
    // Android's positive highlight control brightens; the core's signed
    // parameter uses the opposite direction.
    request.highlights = -highlights;
    request.shadows = shadows;
    request.tone_curve = toneCurve;
    request.sharpening = sharpening;
    request.intent = output ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.preview_long_edge = output ? 0 : static_cast<uint32_t>(edge);
    request.output_target = output ? SONY2FUJI_TARGET_FILE : SONY2FUJI_TARGET_BUFFER;
    request.output_path = output;
    request.output_format = output ? (png ? SONY2FUJI_OUTPUT_PNG : SONY2FUJI_OUTPUT_JPEG) : SONY2FUJI_OUTPUT_RGBA8;
    request.jpeg_quality = 95;
    return request;
}

inline sony2fuji_request makeRequest(const char* input, const char* lut, const char* output,
    float strength, float exposure, bool customWb, float temperature, float tint,
    int edge, bool png) {
    return makeRequest(input, lut, output, strength, exposure, customWb, temperature, tint,
        0, 0, 0, 0, 0, 0, edge, png);
}
}
