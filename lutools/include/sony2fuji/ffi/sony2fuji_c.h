#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Version
// ============================================================================

#define SONY2FUJI_REQUEST_VERSION 2u
#define SONY2FUJI_GPU_CONFIG_VERSION 1u

// ============================================================================
// Status
// ============================================================================

typedef enum sony2fuji_status {
    SONY2FUJI_STATUS_OK = 0,
    SONY2FUJI_STATUS_INVALID_ARGUMENT = 1,
    SONY2FUJI_STATUS_UNSUPPORTED = 2,
    SONY2FUJI_STATUS_IO_ERROR = 3,
    SONY2FUJI_STATUS_PROCESSING_ERROR = 4,
    SONY2FUJI_STATUS_OUT_OF_MEMORY = 5
} sony2fuji_status;

// ============================================================================
// Types
// ============================================================================

typedef enum sony2fuji_input_type {
    SONY2FUJI_INPUT_RAW = 0,
    SONY2FUJI_INPUT_BUFFER = 1
} sony2fuji_input_type;

typedef enum sony2fuji_pixel_format {
    SONY2FUJI_PIXEL_RGB8 = 0,
    SONY2FUJI_PIXEL_RGBA8 = 1
} sony2fuji_pixel_format;

typedef enum sony2fuji_output_format {
    SONY2FUJI_OUTPUT_JPEG = 0,
    SONY2FUJI_OUTPUT_PNG = 1,
    SONY2FUJI_OUTPUT_RGB8 = 2,
    SONY2FUJI_OUTPUT_RGBA8 = 3
} sony2fuji_output_format;

typedef enum sony2fuji_output_target {
    SONY2FUJI_TARGET_FILE = 0,
    SONY2FUJI_TARGET_BUFFER = 1
} sony2fuji_output_target;

typedef enum sony2fuji_wb_mode {
    SONY2FUJI_WB_CAMERA = 0,
    SONY2FUJI_WB_AUTO = 1,
    SONY2FUJI_WB_CUSTOM = 2,
    // RAW-only absolute Kelvin/tint, applied in camera space before demosaic.
    SONY2FUJI_WB_TEMPERATURE = 3
} sony2fuji_wb_mode;

typedef enum sony2fuji_size_mode {
    SONY2FUJI_SIZE_EXACT = 0,
    SONY2FUJI_SIZE_FIT_LONG_EDGE = 1,
    SONY2FUJI_SIZE_FIT_SHORT_EDGE = 2,
    SONY2FUJI_SIZE_NATIVE = 3
} sony2fuji_size_mode;

typedef enum sony2fuji_intent {
    SONY2FUJI_INTENT_PREVIEW = 0,
    SONY2FUJI_INTENT_FINAL = 1
} sony2fuji_intent;

typedef enum sony2fuji_color_space {
    SONY2FUJI_COLOR_SRGB = 0,
    SONY2FUJI_COLOR_FGAMUT = 1,
    SONY2FUJI_COLOR_SONY_NATIVE = 2,
    SONY2FUJI_COLOR_ACESCG = 3,
    SONY2FUJI_COLOR_ADOBE_RGB = 4
} sony2fuji_color_space;

typedef enum sony2fuji_gpu_mode {
    SONY2FUJI_GPU_OFF = 0,
    SONY2FUJI_GPU_AUTO = 1,
    SONY2FUJI_GPU_FORCE = 2
} sony2fuji_gpu_mode;

typedef enum sony2fuji_raw_exposure_mode {
    SONY2FUJI_EXPOSURE_SCENE = 0,
    SONY2FUJI_EXPOSURE_PREVIEW = 1,
    SONY2FUJI_EXPOSURE_SENSOR = 2
} sony2fuji_raw_exposure_mode;

// ============================================================================
// Request/Buffer
// ============================================================================

typedef struct sony2fuji_request {
    uint32_t version;
    uint32_t struct_size;

    const char* input_path;
    sony2fuji_input_type input_type;
    const void* input_pixels;
    uint32_t input_width;
    uint32_t input_height;
    sony2fuji_pixel_format input_pixel_format;
    sony2fuji_color_space input_color_space;
    int32_t input_is_linear;

    // Canonical display CUBE or compiled DCP .rlook (CPU/Metal; other GPUs use Auto fallback).
    const char* lut_path;
    float lut_strength;

    sony2fuji_wb_mode wb_mode;
    float wb_mul[4];
    float exposure_ev;
    float brightness;
    float contrast;
    float saturation;
    float temperature;
    float tint;
    float highlights;
    float shadows;
    float tone_curve;
    float noise_reduction;
    float sharpening;

    sony2fuji_size_mode size_mode;
    uint32_t target_width;
    uint32_t target_height;
    uint32_t long_edge;
    uint32_t short_edge;

    sony2fuji_output_target output_target;
    const char* output_path;
    sony2fuji_output_format output_format;
    uint32_t jpeg_quality;

    sony2fuji_intent intent;
    uint32_t preview_long_edge;
} sony2fuji_request;

typedef struct sony2fuji_buffer {
    void* data;
    size_t size_bytes;
    uint32_t width;
    uint32_t height;
    uint32_t stride_bytes;
    sony2fuji_pixel_format pixel_format;
} sony2fuji_buffer;

typedef struct sony2fuji_gpu_config {
    uint32_t version;
    uint32_t struct_size;
    sony2fuji_gpu_mode mode;
} sony2fuji_gpu_config;

// ============================================================================
// Opaque Session
// ============================================================================

typedef struct sony2fuji_session sony2fuji_session;

typedef enum sony2fuji_render_backend {
    SONY2FUJI_BACKEND_CPU = 0,
    SONY2FUJI_BACKEND_METAL = 1,
    SONY2FUJI_BACKEND_GLES = 2,
    SONY2FUJI_BACKEND_D3D11 = 3
} sony2fuji_render_backend;

// ============================================================================
// API
// ============================================================================

sony2fuji_status sony2fuji_session_create(sony2fuji_session** out_session);

sony2fuji_status sony2fuji_session_destroy(sony2fuji_session* session);

// Reduced RAW processing is allowed only for PREVIEW + BUFFER requests.
// FINAL requests and every file export ignore this flag.
sony2fuji_status sony2fuji_session_set_interactive_preview(sony2fuji_session* session, int32_t enabled);
sony2fuji_render_backend sony2fuji_session_get_last_backend(const sony2fuji_session* session);

// Exact 256-bin channel-major RGB counts and an optional packed RGBA8 clipping mask.
// Auto prefers CPU for CPU-resident bytes to avoid upload/readback overhead.
// Force requires Metal and reports failure instead of falling back.
sony2fuji_status sony2fuji_analyze_image(
    const sony2fuji_buffer* image, sony2fuji_gpu_mode mode, uint32_t* rgb_bins,
    uint32_t* shadows, uint32_t* highlights, sony2fuji_buffer* clipping_mask
);

// Does not change request v2 layout. The mode participates in the RAW cache key.
sony2fuji_status sony2fuji_session_set_raw_exposure_mode(
    sony2fuji_session* session, sony2fuji_raw_exposure_mode mode
);

// Offsets of the last successfully decoded RAW, excluding user exposure.
sony2fuji_status sony2fuji_session_get_raw_exposure(
    const sony2fuji_session* session, float* baseline_ev, float* metadata_ev
);

// Estimated from as-shot camera gains and the camera calibration, not fixed 6500 K.
// UNSUPPORTED means the file lacks usable calibration; camera WB remains usable.
sony2fuji_status sony2fuji_session_get_raw_white_balance(
    const sony2fuji_session* session, float* temperature, float* tint
);

sony2fuji_status sony2fuji_session_set_gpu_config(
    sony2fuji_session* session,
    const sony2fuji_gpu_config* config
);

sony2fuji_status sony2fuji_process(
    sony2fuji_session* session,
    const sony2fuji_request* request,
    sony2fuji_buffer* out_buffer
);

sony2fuji_status sony2fuji_compute_histogram(
    const sony2fuji_buffer* buffer,
    uint32_t bins,
    float* out_bins
);

void sony2fuji_release_buffer(sony2fuji_buffer* buffer);

const char* sony2fuji_status_message(sony2fuji_status status);

#ifdef __cplusplus
} // extern "C"
#endif
