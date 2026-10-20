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
    SONY2FUJI_STATUS_OUT_OF_MEMORY = 5,
    SONY2FUJI_STATUS_OUTPUT_IO_ERROR = 6
} sony2fuji_status;

// ============================================================================
// Types
// ============================================================================

typedef enum sony2fuji_input_type {
    SONY2FUJI_INPUT_RAW = 0,
    SONY2FUJI_INPUT_BUFFER = 1,
    // Opaque SDR display-sRGB pixels. Unlike legacy scene buffers, neutral
    // rendering only re-encodes sRGB; no RAW baseline or scene view curve.
    SONY2FUJI_INPUT_DISPLAY_BUFFER = 2
} sony2fuji_input_type;

typedef enum sony2fuji_pixel_format {
    SONY2FUJI_PIXEL_RGB8 = 0,
    SONY2FUJI_PIXEL_RGBA8 = 1
} sony2fuji_pixel_format;

typedef enum sony2fuji_look_format {
    SONY2FUJI_LOOK_UNKNOWN = 0,
    SONY2FUJI_LOOK_CUBE = 1,
    SONY2FUJI_LOOK_RLOOK = 2
} sony2fuji_look_format;

typedef struct sony2fuji_blob {
    void* data;
    size_t size_bytes;
} sony2fuji_blob;

typedef enum sony2fuji_dcp_error {
    SONY2FUJI_DCP_ERROR_NONE = 0,
    SONY2FUJI_DCP_ERROR_MALFORMED = 1,
    SONY2FUJI_DCP_ERROR_TOO_LARGE = 2,
    SONY2FUJI_DCP_ERROR_INVALID_CALIBRATION = 3,
    SONY2FUJI_DCP_ERROR_MISSING_TONE_CURVE = 4,
    SONY2FUJI_DCP_ERROR_AUTOMATIC_BLACK = 5,
    SONY2FUJI_DCP_ERROR_TRIPLE_ILLUMINANT = 6,
    SONY2FUJI_DCP_ERROR_UNSUPPORTED_STAGES = 7,
    SONY2FUJI_DCP_ERROR_INVALID_TABLE = 8,
    SONY2FUJI_DCP_ERROR_INVALID_TONE_CURVE = 9,
    SONY2FUJI_DCP_ERROR_INVALID_EXPOSURE = 10
} sony2fuji_dcp_error;

typedef enum sony2fuji_output_format {
    SONY2FUJI_OUTPUT_JPEG = 0,
    SONY2FUJI_OUTPUT_PNG = 1,
    SONY2FUJI_OUTPUT_RGB8 = 2,
    SONY2FUJI_OUTPUT_RGBA8 = 3,
    // Output-referred LinearRaw with baked edits, not original sensor data. FILE only.
    SONY2FUJI_OUTPUT_DNG = 4
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
    SONY2FUJI_SIZE_NATIVE = 3,
    // Final-size pixel ceiling: preserve aspect ratio and never enlarge.
    // As with other size modes, PREVIEW's preview_long_edge takes priority.
    SONY2FUJI_SIZE_LIMIT_LONG_EDGE = 4
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

#define SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION 1
typedef struct sony2fuji_wavelet_denoise_config {
    uint32_t version;
    uint32_t struct_size;
    int32_t enabled;
    float luma;   // 0..100, independent normalized-luminance strength.
    float chroma; // 0..100, normalized-color strength.
    float coarse; // 0..100, coarse color-band fraction of chroma strength.
} sony2fuji_wavelet_denoise_config;

#define SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION 1
typedef struct sony2fuji_photo_effects_config {
    uint32_t version;
    uint32_t struct_size;
    float vignette_amount;     // -100..100; negative darkens, positive lightens.
    float vignette_midpoint;   // 0..100; default 50.
    float vignette_roundness;  // -100..100; default 0.
    float vignette_feather;    // 0..100; default 50.
    float vignette_highlights; // 0..100; protects highlights with negative amount.
    float grain_amount;        // 0..100; default 0 (off).
    float grain_size;          // 0..100; default 25.
    float grain_roughness;     // 0..100; default 50.
} sony2fuji_photo_effects_config;

#define SONY2FUJI_HSL_CONFIG_VERSION 1
#define SONY2FUJI_HSL_CHANNELS 8
typedef struct sony2fuji_hsl_config {
    uint32_t version;
    uint32_t struct_size;
    // Red, orange, yellow, green, aqua, blue, purple, magenta; -100..100.
    float hue[SONY2FUJI_HSL_CHANNELS];        // +/-30 degrees at full scale.
    float saturation[SONY2FUJI_HSL_CHANNELS]; // Relative saturation percent.
    float lightness[SONY2FUJI_HSL_CHANNELS];  // +/-0.5 display-HSL lightness.
} sony2fuji_hsl_config;

#define SONY2FUJI_GEOMETRY_CONFIG_VERSION 1u
typedef struct sony2fuji_geometry_config {
    uint32_t version;
    uint32_t struct_size;
    float crop_x;                // Normalized left; default 0.
    float crop_y;                // Normalized top; default 0.
    float crop_width;            // Positive normalized width; default 1.
    float crop_height;           // Positive normalized height; default 1.
    int32_t quarter_turns;       // 0..3 clockwise turns; default 0.
    int32_t flip_horizontal;     // 0 or 1 in the rotated canvas; default 0.
    int32_t flip_vertical;       // 0 or 1 in the rotated canvas; default 0.
    float straighten_degrees;   // -45..45 clockwise; default 0.
} sony2fuji_geometry_config;

#define SONY2FUJI_PERSPECTIVE_CONFIG_VERSION 1u
typedef struct sony2fuji_perspective_config {
    uint32_t version;
    uint32_t struct_size;
    float horizontal; // -1..1 in the rotated/flipped canvas; default 0.
    float vertical;   // -1..1 in the rotated/flipped canvas; default 0.
} sony2fuji_perspective_config;

#define SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION 1u
typedef struct sony2fuji_lens_correction_config {
    uint32_t version;
    uint32_t struct_size;
    int32_t distortion;
    int32_t tca;
    int32_t auto_crop;
    const char* profile_id; // NULL/empty: automatic; otherwise a catalog ID. Copied by setter.
} sony2fuji_lens_correction_config;

typedef enum sony2fuji_lens_state {
    SONY2FUJI_LENS_OFF = 0,
    SONY2FUJI_LENS_MATCHED = 1,
    SONY2FUJI_LENS_NO_DATABASE = 2,
    SONY2FUJI_LENS_NO_CAMERA = 3,
    SONY2FUJI_LENS_NO_LENS = 4,
    SONY2FUJI_LENS_AMBIGUOUS = 5,
    SONY2FUJI_LENS_NO_CALIBRATION = 6,
    SONY2FUJI_LENS_MISSING_FOCAL_LENGTH = 7,
    SONY2FUJI_LENS_EMBEDDED_GEOMETRY = 8,
    SONY2FUJI_LENS_UNSUPPORTED_INPUT = 9
} sony2fuji_lens_state;

typedef struct sony2fuji_lens_profile {
    char id[512];
    char maker[128];
    char model[256];
    int32_t has_distortion;
    int32_t has_tca;
    int32_t is_match;
} sony2fuji_lens_profile;

typedef struct sony2fuji_lens_report {
    sony2fuji_lens_state state;
    char camera_make[128];
    char camera_model[128];
    char lens_model[256];
    float focal_length;
    sony2fuji_lens_profile profile;
    int32_t applied_distortion;
    int32_t applied_tca;
    float crop_scale; // Inscribed zoom; source dimensions/aspect are unchanged.
} sony2fuji_lens_report;
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

// File adapters: single-frame opaque 8-bit SDR RGB.
// macOS/iOS ImageIO accepts JPEG/PNG/TIFF/HEIF; Windows WIC accepts JPEG/PNG/TIFF.
// Applies orientation and ICC -> sRGB once. Untagged RGB assumes sRGB.
// Rejects transparency, high-bit-depth/HDR and unsupported encodings.
// Pass a zero-initialized or previously returned buffer; release with
// sony2fuji_release_buffer. Android clients decode validated files with the
// platform decoder and pass DISPLAY_BUFFER; this file API returns UNSUPPORTED.
sony2fuji_status sony2fuji_load_display_image(const char* path, sony2fuji_buffer* out_buffer);

sony2fuji_status sony2fuji_session_destroy(sony2fuji_session* session);

// Explicit offline XML file/directory; NULL loads the system database. Failed loads preserve state.
sony2fuji_status sony2fuji_session_set_lens_database(sony2fuji_session* session, const char* path);
sony2fuji_status sony2fuji_session_set_lens_correction(
    sony2fuji_session* session, const sony2fuji_lens_correction_config* config);
// Metadata-only: does not unpack/develop RAW. count returns required capacity; NULL profiles queries size.
sony2fuji_status sony2fuji_session_inspect_lens(sony2fuji_session* session, const char* input_path,
    sony2fuji_lens_report* report, sony2fuji_lens_profile* profiles, uint32_t capacity, uint32_t* count);
sony2fuji_status sony2fuji_session_get_lens_report(sony2fuji_session* session, sony2fuji_lens_report* report);

// Validates a PHOTO look without a RAW, session or GPU. Optional outputs are
// cleared on failure; CUBE is unversioned (0), RLOOK reports its header version.
sony2fuji_status sony2fuji_validate_look(
    const char* path, sony2fuji_look_format* format, uint32_t* format_version
);

// Compile a bounded DCP byte buffer into the native RLOOK format. The output
// blob is owned by the caller and must be released with sony2fuji_release_blob.
// A zero-initialized or previously returned blob is accepted; failures clear it.
sony2fuji_status sony2fuji_compile_dcp(
    const void* data, size_t size_bytes, const char* source_name,
    sony2fuji_blob* out_blob, sony2fuji_dcp_error* out_reason
);

void sony2fuji_release_blob(sony2fuji_blob* blob);

// Reduced RAW processing is allowed only for PREVIEW + BUFFER requests.
// FINAL requests and every file export ignore this flag.
sony2fuji_status sony2fuji_session_set_interactive_preview(sony2fuji_session* session, int32_t enabled);
// Opt-in approximation: resize linear input before filtering, tone and effects.
// Only PREVIEW buffer requests use it; FINAL and file outputs remain exact.
// Disabled by default; the request layout and existing preview mode are unchanged.
sony2fuji_status sony2fuji_session_set_viewport_preview(sony2fuji_session* session, int32_t enabled);
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

// FBDD before demosaic: 0 off (default), 1 light, 2 full. Keeps request v2 ABI.
// Enabled FBDD requires a three-color Bayer RAW and disables half-size decoding.
// Unsupported inputs return UNSUPPORTED at processing time, never a silent no-op.
sony2fuji_status sony2fuji_session_set_raw_noise_reduction(sony2fuji_session* session, int32_t level);

// Display-sRGB chroma denoising after tone/LUT, before sharpening and resizing.
// 0 off (default), 1 detail priority, 2 noise priority. Does not change request v2.
// Requires a core built with SONY2FUJI_ENABLE_CHROMA_DENOISE; otherwise nonzero
// modes return UNSUPPORTED. Metal/GLES/D3D11 accelerate guided filters at source
// resolution; sampled estimation and OpenCV Lab conversion remain on CPU.
// Auto falls back to CPU; Force requires the platform GPU to succeed.
sony2fuji_status sony2fuji_session_set_chroma_denoise(sony2fuji_session* session, int32_t mode);

// Linear-sRGB wavelets before user exposure, tone/LUT and sharpening. Additive ABI.
// Exact previews and exports filter at source resolution. Explicit interactive
// buffer previews may use a reduced image; final/file output is never downgraded.
// Metal/GLES/D3D11 accelerate tiled SWT; estimation/calibration remain on CPU.
// Auto falls back to CPU; Force requires the platform GPU to succeed.
// Old FBDD/display-chroma settings are independent; clients choose whether to stack.
sony2fuji_status sony2fuji_session_set_wavelet_denoise(
    sony2fuji_session* session, const sony2fuji_wavelet_denoise_config* config
);

// Additive API; request v2 is unchanged. Both amounts zero is an exact bypass.
// Source-resolution display effects run before output resize on CPU/Metal/GLES/D3D11.
// Auto retains CPU fallback; Force requires the platform GPU to succeed.
// Fixed grain is reproducible. Wavelet/chroma denoising can precede effects.
sony2fuji_status sony2fuji_session_set_photo_effects(
    sony2fuji_session* session, const sony2fuji_photo_effects_config* config
);

// Display-sRGB mixer after tone/color and before denoise/detail/effects.
// Additive API: request v2 is unchanged. Zero is an exact bypass. Active HSL
// uses the platform photo GPU when available. Auto falls back on GPU failure;
// Force requires GPU success, as with the other photo adjustments.
sony2fuji_status sony2fuji_session_set_hsl(
    sony2fuji_session* session, const sony2fuji_hsl_config* config
);

// Additive API; request v2 is unchanged. Identity is an exact bypass.
// Already-oriented pixels rotate, flip, apply perspective, straighten within a
// centered inscribed canvas, then crop (floor start/ceil end) before output resizing.
// Crop coordinates refer to that transformed canvas. Invalid values preserve
// the previous configuration. Normalized ends tolerate at most 1e-6 beyond
// one for Float UI rounding and clamp to the canvas. Active geometry disables
// half-size RAW; a viewport preview may reduce the source, while FINAL and file
// outputs keep the exact source. Geometry is CPU-only: GPU Auto may render
// color on GPU, but the mixed result reports CPU; Force returns UNSUPPORTED.
sony2fuji_status sony2fuji_session_set_geometry(
    sony2fuji_session* session, const sony2fuji_geometry_config* config
);

// Additive API; request v2 and geometry config v1 are unchanged. Changes only
// perspective, preserving crop/turns/flips/straightening. The geometry setter
// likewise preserves perspective. Finite -1..1 controls default to zero.
// Inverse centered offsets are divided by 1 + .25*horizontal*u + .25*vertical*v,
// where u/v are normalized using the original rotated width/height. The safe
// centered canvas is scaled by 1/(1 + .25*abs(horizontal) + .25*abs(vertical))
// before straightening and crop. Perspective and straightening sample once
// bilinearly; zero perspective retains the exact existing geometry path.
// Invalid values preserve all state. Success clears the last geometry size.
// Active perspective has the same viewport and GPU semantics as geometry.
sony2fuji_status sony2fuji_session_set_perspective(
    sony2fuji_session* session, const sony2fuji_perspective_config* config
);

// Native canvas from the last successful process, after geometry and before
// output resizing. Identity records the decoded input dimensions even when
// its preview is reduced later. Active geometry reports the full-source canvas
// even when a viewport preview reduced its source.
// Successful geometry/perspective setters and every new process clear the size.
// Failed processes, including output I/O failures, leave the size unavailable.
// Returns UNSUPPORTED when unset; all errors zero any supplied output pointers.
sony2fuji_status sony2fuji_session_get_geometry_size(
    const sony2fuji_session* session, uint32_t* width, uint32_t* height
);

// One-shot absolute user EV in [-4,4], not a delta from current exposure.
// Meters exact RAW/current WB and exposure mode, or a tagged raster buffer,
// before user EV/LUT/display controls. Errors leave exposure_ev unchanged.
sony2fuji_status sony2fuji_session_estimate_auto_exposure(
    sony2fuji_session* session, const sony2fuji_request* request, float* exposure_ev
);

// Capability of the last successfully decoded RAW: 0 unsupported, 1 supported.
sony2fuji_status sony2fuji_session_get_raw_noise_reduction_support(
    const sony2fuji_session* session, int32_t* supported
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
