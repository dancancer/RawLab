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
#define SONY2FUJI_AI_DENOISE_CONFIG_VERSION 1u

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
    SONY2FUJI_STATUS_OUTPUT_IO_ERROR = 6,
    SONY2FUJI_STATUS_CANCELLED = 7,
    SONY2FUJI_STATUS_AI_NOT_READY = 8
} sony2fuji_status;

typedef enum sony2fuji_unsupported_reason {
    SONY2FUJI_UNSUPPORTED_NONE = 0,
    SONY2FUJI_UNSUPPORTED_FORCE_GPU = 1
} sony2fuji_unsupported_reason;

typedef enum sony2fuji_gpu_fallback_reason {
    SONY2FUJI_GPU_FALLBACK_NONE = 0,
    SONY2FUJI_GPU_FALLBACK_BASIC_V3_CONTROLS = 1,
    SONY2FUJI_GPU_FALLBACK_ATMOSPHERE = 2,
    SONY2FUJI_GPU_FALLBACK_CURVES = 3,
    SONY2FUJI_GPU_FALLBACK_C5_WAVELET = 4,
    SONY2FUJI_GPU_FALLBACK_DCP_LOOK = 5,
    SONY2FUJI_GPU_FALLBACK_LUT_CONTRACT = 6,
    SONY2FUJI_GPU_FALLBACK_GEOMETRY = 7,
    SONY2FUJI_GPU_FALLBACK_DISPLAY_INPUT = 8,
    SONY2FUJI_GPU_FALLBACK_GPU_DISABLED = 9,
    SONY2FUJI_GPU_FALLBACK_NO_ADAPTER = 10,
    SONY2FUJI_GPU_FALLBACK_COOLDOWN = 11,
    SONY2FUJI_GPU_FALLBACK_DEVICE_ERROR = 12,
    SONY2FUJI_GPU_FALLBACK_FILTER_ERROR = 13,
    SONY2FUJI_GPU_FALLBACK_UNSUPPORTED_CAPABILITY = 14
} sony2fuji_gpu_fallback_reason;

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
    SONY2FUJI_PIXEL_RGBA8 = 1,
    // Tightly packed little-endian 16-bit RGBA; input only, for DISPLAY_BUFFER.
    SONY2FUJI_PIXEL_RGBA16 = 2,
    // Display-order BGRA8 (e.g. WPF Pbgra32 with opaque alpha); supported by
    // HDR display encoding and sony2fuji_analyze_image / sony2fuji_compute_histogram.
    SONY2FUJI_PIXEL_BGRA8 = 3
} sony2fuji_pixel_format;

typedef enum sony2fuji_look_format {
    SONY2FUJI_LOOK_UNKNOWN = 0,
    SONY2FUJI_LOOK_CUBE = 1,
    SONY2FUJI_LOOK_RLOOK = 2,
    SONY2FUJI_LOOK_VLT = 3
} sony2fuji_look_format;

typedef enum sony2fuji_lut_color_state {
    SONY2FUJI_LUT_MISSING_COLOR = 0,
    SONY2FUJI_LUT_MISSING_REFERENCE = 1,
    SONY2FUJI_LUT_UNSUPPORTED_CONTRACT = 2,
    SONY2FUJI_LUT_INVALID_CONTRACT = 3,
    SONY2FUJI_LUT_DECLARED_UNVERIFIED = 4,
    SONY2FUJI_LUT_LEGACY_DECLARATION = 5,
    SONY2FUJI_LUT_UNREADABLE = 6,
    SONY2FUJI_LUT_COMPATIBILITY = 7,
    SONY2FUJI_LUT_APPROXIMATE_BASE = 8
} sony2fuji_lut_color_state;

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

typedef enum sony2fuji_processing_version {
    SONY2FUJI_PROCESSING_LEGACY = 1,
    SONY2FUJI_PROCESSING_C5_V2 = 2,
    SONY2FUJI_PROCESSING_BASIC_V3 = 3
} sony2fuji_processing_version;

typedef enum sony2fuji_x3f_mode {
    SONY2FUJI_X3F_LEGACY = 0,
    SONY2FUJI_X3F_NORMAL = 1
} sony2fuji_x3f_mode;

typedef enum sony2fuji_output_sharpening {
    SONY2FUJI_OUTPUT_SHARPENING_OFF = 0,
    SONY2FUJI_OUTPUT_SHARPENING_LOW = 1,
    SONY2FUJI_OUTPUT_SHARPENING_STANDARD = 2,
    SONY2FUJI_OUTPUT_SHARPENING_HIGH = 3
} sony2fuji_output_sharpening;


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

#define SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION 1u
typedef struct sony2fuji_tone_controls_config {
    uint32_t version;
    uint32_t struct_size;
    float black_point; // -1..1, default 0. Display black endpoint, not sensor metadata.
    float white_point; // -1..1, default 0. Display white endpoint.
    float vibrance;    // -1..1, default 0. Independent of legacy saturation.
} sony2fuji_tone_controls_config;

#define SONY2FUJI_ATMOSPHERE_CONFIG_VERSION 1u
typedef struct sony2fuji_atmosphere_config {
    uint32_t version;
    uint32_t struct_size;
    float clarity; // -1..1, default 0. Medium-scale local contrast.
    float dehaze;  // -1..1, default 0. Negative adds atmosphere.
} sony2fuji_atmosphere_config;

#define SONY2FUJI_COLOR_GRADING_CONFIG_VERSION 1u
typedef struct sony2fuji_color_grading_config {
    uint32_t version;
    uint32_t struct_size;
    float shadows_hue;         // [0,360), degrees; zero saturation retains dormant hue.
    float shadows_saturation;  // 0..100, default 0.
    float midtones_hue;
    float midtones_saturation;
    float highlights_hue;
    float highlights_saturation;
} sony2fuji_color_grading_config;

#define SONY2FUJI_COLOR_GRADING_V2_CONFIG_VERSION 2u
typedef struct sony2fuji_color_grading_v2_config {
    uint32_t version;
    uint32_t struct_size;
    float shadows_hue;          // [0, 360)
    float shadows_saturation;   // 0..100
    float shadows_luminance;    // -100..100, default 0
    float midtones_hue;         // [0, 360)
    float midtones_saturation;  // 0..100
    float midtones_luminance;   // -100..100, default 0
    float highlights_hue;       // [0, 360)
    float highlights_saturation;// 0..100
    float highlights_luminance; // -100..100, default 0
    float global_hue;           // [0, 360)
    float global_saturation;    // 0..100
    float global_luminance;     // -100..100, default 0
    float blending;             // 0..100, default 50
    float balance;              // -100..100, default 0
} sony2fuji_color_grading_v2_config;

#define SONY2FUJI_TONE_CURVE_CONFIG_VERSION 1u
#define SONY2FUJI_TONE_CURVE_MAX_POINTS 33u
typedef enum sony2fuji_curve_mode {
    SONY2FUJI_CURVE_LEGACY = 0,
    SONY2FUJI_CURVE_CUSTOM = 1
} sony2fuji_curve_mode;
typedef struct sony2fuji_curve_point { double x, y; } sony2fuji_curve_point;
typedef struct sony2fuji_tone_curve_config {
    uint32_t version;
    uint32_t struct_size;
    sony2fuji_curve_mode mode;
    uint32_t count;
    sony2fuji_curve_point points[SONY2FUJI_TONE_CURVE_MAX_POINTS];
} sony2fuji_tone_curve_config;

#define SONY2FUJI_TONE_CURVE_SET_CONFIG_VERSION 1u
typedef struct sony2fuji_tone_curve_set_config {
    uint32_t version, struct_size;
    // RGB master, red, green, blue. Each entry must be initialized, including legacy entries.
    sony2fuji_tone_curve_config curves[4];
} sony2fuji_tone_curve_set_config;

#define SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION 1u
typedef struct sony2fuji_tone_curve_parametric_config {
    uint32_t version;
    uint32_t struct_size;
    float highlights;      // -100..100, default 0
    float lights;          // -100..100, default 0
    float darks;           // -100..100, default 0
    float shadows;         // -100..100, default 0
    float split_shadow;    // [0.05, 0.45], default 0.25
    float split_midtone;   // [0.25, 0.75], default 0.50
    float split_highlight; // [0.55, 0.95], default 0.75
    uint32_t reserved;     // Must be 0
} sony2fuji_tone_curve_parametric_config;

#define SONY2FUJI_TONE_CURVE_SET_V2_CONFIG_VERSION 2u
typedef struct sony2fuji_tone_curve_set_v2_config {
    uint32_t version;
    uint32_t struct_size;
    int32_t apply_to_luminosity; // 0 = RGB (default), 1 = Luminosity
    uint32_t reserved;           // Must be 0
    sony2fuji_tone_curve_config curves[4]; // Master (may have free y0/y1 in [0,1]), R, G, B
    sony2fuji_tone_curve_parametric_config parametric;
} sony2fuji_tone_curve_set_v2_config;

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

#define SONY2FUJI_LENS_CORRECTION_CONFIG_V2_VERSION 2u
typedef struct sony2fuji_lens_correction_config_v2 {
    sony2fuji_lens_correction_config base; // version 2, struct_size sizeof(v2).
    int32_t vignetting;
} sony2fuji_lens_correction_config_v2;

#define SONY2FUJI_LENS_METADATA_VERSION 1u
typedef struct sony2fuji_lens_metadata {
    uint32_t version;
    uint32_t struct_size;
    const char* camera_make;
    const char* camera_model;
    const char* lens_make;
    const char* lens_model;
    float focal_length; // Millimeters; 0 means missing.
    float aperture;     // F-number; 0 means missing.
    float crop_factor;  // 0 uses the matched camera database entry, never an inferred model family.
    int32_t embedded_geometry;
    int32_t source_orientation; // Original EXIF 1..8. Display pixels are already oriented.
} sony2fuji_lens_metadata;

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

typedef struct sony2fuji_lens_profile_v2 {
    sony2fuji_lens_profile base;
    int32_t has_vignetting;
} sony2fuji_lens_profile_v2;

// Separate output type preserves the size of the original unversioned report ABI.
typedef struct sony2fuji_lens_report_v2 {
    sony2fuji_lens_report base;
    int32_t has_vignetting;
    int32_t applied_vignetting;
} sony2fuji_lens_report_v2;
// ============================================================================
// Opaque Session
// ============================================================================

typedef struct sony2fuji_session sony2fuji_session;

// Independent from processing version. New sessions preserve legacy pixels.
int32_t sony2fuji_x3f_available(void);
// Identifies a source and chooses the renderer for a new edit.
sony2fuji_status sony2fuji_x3f_default_mode(const char* input_path, sony2fuji_x3f_mode* mode);
// Returns 1 when mode is NORMAL and input_path begins with the X3F "FOVb" header, else 0.
int32_t sony2fuji_is_normal_x3f(const char* input_path, sony2fuji_x3f_mode mode);
sony2fuji_status sony2fuji_session_set_x3f_mode(sony2fuji_session* session, sony2fuji_x3f_mode mode);
// Last normal-X3F error on this session; owned by the session until its next render.
const char* sony2fuji_session_x3f_error(const sony2fuji_session* session);

typedef struct sony2fuji_hsl_probe sony2fuji_hsl_probe;
#define SONY2FUJI_HSL_PROBE_VERSION 1
typedef enum sony2fuji_hsl_probe_availability {
    SONY2FUJI_HSL_PROBE_AVAILABLE = 0,
    SONY2FUJI_HSL_PROBE_NEAR_GRAY = 1,
    SONY2FUJI_HSL_PROBE_OUTSIDE = 2,
    SONY2FUJI_HSL_PROBE_STALE = 3,
    SONY2FUJI_HSL_PROBE_NONFINITE = 4
} sony2fuji_hsl_probe_availability;
typedef enum sony2fuji_hsl_probe_quality {
    SONY2FUJI_HSL_PROBE_EXACT_CPU = 0,
    SONY2FUJI_HSL_PROBE_PREVIEW_CPU = 1
} sony2fuji_hsl_probe_quality;
typedef struct sony2fuji_hsl_probe_query {
    uint32_t version, struct_size;
    uint64_t source_revision, request_revision;
    float x, y;
} sony2fuji_hsl_probe_query;
typedef struct sony2fuji_hsl_probe_result {
    uint32_t version, struct_size;
    uint64_t source_revision, request_revision;
    uint32_t width, height;
    sony2fuji_hsl_probe_availability availability;
    sony2fuji_hsl_probe_quality quality;
    float rgb[3]; // Working sRGB outside [0,1] is allowed. HDR probes use linear values.
    float hsl[3]; // Hue degrees [0,360), saturation and lightness coordinate [0,1].
    float weights[8]; // Same channel order as hsl_config; available samples sum to 1.
} sony2fuji_hsl_probe_result;

typedef enum sony2fuji_ai_backend {
    SONY2FUJI_AI_CPU = 0, // Reserved ABI value; enabled CPU requests return UNSUPPORTED.
    SONY2FUJI_AI_COREML = 1,
    SONY2FUJI_AI_AUTO = 2,
    SONY2FUJI_AI_DIRECTML = 3
} sony2fuji_ai_backend;

typedef struct sony2fuji_ai_denoise_config {
    uint32_t version;
    uint32_t struct_size;
    int32_t enabled;
    sony2fuji_ai_backend backend;
    const char* model_directory;
    const char* cache_directory;
} sony2fuji_ai_denoise_config;

// Phase: 1 loading, 2 RAW network, 3 RGB network, 4 saving. Return 0 to cancel.
// Called synchronously on the prepare worker, never on a UI thread implicitly.
typedef int32_t (*sony2fuji_ai_progress_callback)(void* context, int32_t phase, uint64_t completed, uint64_t total);

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

// Atomically validates and replaces all session-level edit state from a canonical
// SDR edit-recipe JSON document (schema_version 1..5 or 7). Omitted edit groups
// reset to their canonical neutral defaults so prior photo or legacy setter state
// cannot bleed across renders. Invalid or unsupported payloads leave existing
// session state intact. Runtime configuration (GPU mode, lens database, display
// lens metadata, AI denoise, preview proxy hints, cancellation) is preserved.
sony2fuji_status sony2fuji_apply_params(
    sony2fuji_session* session,
    const char* recipe_json
);

// Legacy compatibility wrapper — frozen in W2-2. New callers must use sony2fuji_apply_params.
// New sessions use LEGACY. Unsupported versions leave the session unchanged.
sony2fuji_status sony2fuji_session_set_processing_version(
    sony2fuji_session* session, sony2fuji_processing_version version
);

// File adapters: one opaque SDR RGB image.
// macOS/iOS ImageIO accepts JPEG/PNG/TIFF/HEIF; Windows WIC accepts JPEG/PNG/TIFF.
// Apple 与 Windows 也接受 16 位整数 RGB PNG/TIFF，返回 RGBA16。
// Applies orientation and ICC -> sRGB once. Untagged RGB assumes sRGB.
// Rejects transparency, HDR and other unsupported encodings.
// Pass a zero-initialized or previously returned buffer; release with
// sony2fuji_release_buffer. Android clients decode validated files with the
// platform decoder and pass DISPLAY_BUFFER; this file API returns UNSUPPORTED.
sony2fuji_status sony2fuji_load_display_image(const char* path, sony2fuji_buffer* out_buffer);
// Decodes a bounded display-sRGB RGBA8 preview scaled to fit `edge` (> 0) along
// the oriented long edge, optionally reporting the oriented full-source size.
sony2fuji_status sony2fuji_load_display_preview(
    const char* path,
    uint32_t edge,
    sony2fuji_buffer* out_buffer,
    uint32_t* oriented_source_width,
    uint32_t* oriented_source_height
);
// Inspects a display file for JPEG MPF secondary images (image count > 1 for MPF, 0 for single-image/non-MPF, -1 = error).
int32_t sony2fuji_inspect_sdr_jpeg_mpf(const char* path);

sony2fuji_status sony2fuji_session_destroy(sony2fuji_session* session);

// Explicit offline XML file/directory; NULL loads the system database. Failed loads preserve state.
sony2fuji_status sony2fuji_session_set_lens_database(sony2fuji_session* session, const char* path);
sony2fuji_status sony2fuji_session_set_lens_correction(
    sony2fuji_session* session, const sony2fuji_lens_correction_config* config);
sony2fuji_status sony2fuji_session_set_lens_correction_v2(
    sony2fuji_session* session, const sony2fuji_lens_correction_config_v2* config);
sony2fuji_status sony2fuji_session_get_lens_report_v2(sony2fuji_session* session, sony2fuji_lens_report_v2* report);
sony2fuji_status sony2fuji_session_inspect_lens_v2(sony2fuji_session* session, const char* input_path,
    sony2fuji_lens_report_v2* report, sony2fuji_lens_profile_v2* profiles, uint32_t capacity, uint32_t* count);
sony2fuji_status sony2fuji_session_inspect_lens_metadata_v2(sony2fuji_session* session, const sony2fuji_lens_metadata* metadata,
    sony2fuji_lens_report_v2* report, sony2fuji_lens_profile_v2* profiles, uint32_t capacity, uint32_t* count);
// Metadata strings are copied. NULL clears display metadata; RAW input never consumes it.
sony2fuji_status sony2fuji_session_set_display_lens_metadata(
    sony2fuji_session* session, const sony2fuji_lens_metadata* metadata);
sony2fuji_status sony2fuji_session_inspect_lens_metadata(
    sony2fuji_session* session, const sony2fuji_lens_metadata* metadata,
    sony2fuji_lens_report* report, sony2fuji_lens_profile* profiles, uint32_t capacity, uint32_t* count);
// Metadata-only: does not unpack/develop RAW. count returns required capacity; NULL profiles queries size.
sony2fuji_status sony2fuji_session_inspect_lens(sony2fuji_session* session, const char* input_path,
    sony2fuji_lens_report* report, sony2fuji_lens_profile* profiles, uint32_t capacity, uint32_t* count);
sony2fuji_status sony2fuji_session_get_lens_report(sony2fuji_session* session, sony2fuji_lens_report* report);

// Validates a PHOTO look without a RAW, session or GPU. Optional outputs are
// cleared on failure; CUBE is unversioned (0), VLT is 1, RLOOK reports its header version.
sony2fuji_status sony2fuji_validate_look(
    const char* path, sony2fuji_look_format* format, uint32_t* format_version
);
// Read-only CUBE/VLT diagnosis; declared evidence never certifies author appearance.
sony2fuji_lut_color_state sony2fuji_inspect_lut_color(const char* path);

// Returns UTF-8 JSON with eligibility, suggested parameters and source SHA-256.
// Prepare requires the same hash, complete parameters and explicit confirmation;
// it returns original source bytes followed by a compatibility record, never writes
// the source. Blobs must be zero-initialized and released with sony2fuji_release_blob.
sony2fuji_status sony2fuji_inspect_lut_compatibility(const char* path, sony2fuji_blob* out_blob);
sony2fuji_status sony2fuji_prepare_lut_compatibility(const char* path, const char* request_json, sony2fuji_blob* out_blob);
// Transient PHOTO preview. request->lut_path identifies the original CUBE/VLT;
// JSON contains only source_sha256 and contract, with no import confirmation.
// Requires PREVIEW + BUFFER, a 1..1024 long edge and a caller-owned serial session.
// Does not create a prepared asset or install a look. Use an independent preview
// session; normal session caches/metadata may change as with sony2fuji_process.
sony2fuji_status sony2fuji_preview_lut_compatibility(sony2fuji_session* session,
    const sony2fuji_request* request, const char* configuration_json, sony2fuji_buffer* out_buffer);
// Compare oriented, opaque display-sRGB previews at equal dimensions <=1024.
// JSON requires same_source/same_geometry/same_processing/known_srgb=true and a
// nonempty reference_source note. These are user assertions, not authentication.
// Returns descriptive pixel errors only; appearance always remains unverified.
sony2fuji_status sony2fuji_compare_lut_previews(const sony2fuji_buffer* candidate,
    const sony2fuji_buffer* reference, const char* conditions_json, sony2fuji_blob* out_blob);

// Compile a bounded DCP byte buffer into the native RLOOK format. The output
// blob is owned by the caller and must be released with sony2fuji_release_blob.
// A zero-initialized or previously returned blob is accepted; failures clear it.
sony2fuji_status sony2fuji_compile_dcp(
    const void* data, size_t size_bytes, const char* source_name,
    sony2fuji_blob* out_blob, sony2fuji_dcp_error* out_reason
);

// A JSON array of x/y pairs may supply a missing ProfileToneCurve. Pass null
// and zero to use the profile's curve. A nonzero omit_automatic_black opts out
// of the profile's automatic black rendering.
sony2fuji_status sony2fuji_compile_dcp_with_options(
    const void* data, size_t size_bytes, const char* source_name,
    const void* tone_curve_json, size_t tone_curve_size, uint32_t omit_automatic_black,
    sony2fuji_blob* out_blob, sony2fuji_dcp_error* out_reason);

void sony2fuji_release_blob(sony2fuji_blob* blob);

// Reduced RAW processing is allowed only for PREVIEW + BUFFER requests.
// FINAL requests and every file export ignore this flag.
sony2fuji_status sony2fuji_session_set_interactive_preview(sony2fuji_session* session, int32_t enabled);
// Opt-in approximation: resize linear input before filtering, tone and effects.
// Only PREVIEW buffer requests use it; FINAL and file outputs remain exact.
// Disabled by default; the request layout and existing preview mode are unchanged.
sony2fuji_status sony2fuji_session_set_viewport_preview(sony2fuji_session* session, int32_t enabled);

// Optional normalized region-of-interest rendering in post-geometry native coordinates.
// Only PREVIEW + BUFFER requests apply this ROI; FINAL, file exports, and HSL probes ignore it.
typedef struct sony2fuji_viewport_roi {
    uint32_t struct_size;
    uint32_t enabled;
    double norm_x0;
    double norm_y0;
    double norm_x1;
    double norm_y1;
    uint32_t max_output_long_edge;
} sony2fuji_viewport_roi;

typedef struct sony2fuji_viewport_roi_result {
    uint32_t struct_size;
    uint32_t active;
    uint32_t native_x0;
    uint32_t native_y0;
    uint32_t native_x1;
    uint32_t native_y1;
    uint32_t full_native_width;
    uint32_t full_native_height;
} sony2fuji_viewport_roi_result;

sony2fuji_status sony2fuji_session_set_viewport_roi(
    sony2fuji_session* session,
    const sony2fuji_viewport_roi* roi
);

sony2fuji_status sony2fuji_session_get_viewport_roi_result(
    const sony2fuji_session* session,
    sony2fuji_viewport_roi_result* out_result
);
sony2fuji_render_backend sony2fuji_session_get_last_backend(const sony2fuji_session* session);
sony2fuji_unsupported_reason sony2fuji_session_get_unsupported_reason(const sony2fuji_session* session);
sony2fuji_gpu_fallback_reason sony2fuji_session_get_gpu_fallback_reason(const sony2fuji_session* session);
// UTF-8 diagnostic detail for the last GPU fallback or Force GPU failure on this session.
// Valid until the next getter call on the calling thread; always returns a non-null string.
const char* sony2fuji_session_get_gpu_error(const sony2fuji_session* session);
// RAW decodes stored into this session's cache, including half-size proxy and exposure-anchor decodes.
// A render that reuses the decoded cache does not increment it, so repeated previews and the export
// that follows can be checked for re-decoding.
uint64_t sony2fuji_session_get_raw_decode_count(const sony2fuji_session* session);

// Exact 256-bin channel-major RGB counts and an optional packed RGBA8 clipping mask.
// Auto prefers CPU for CPU-resident bytes to avoid upload/readback overhead.
// Force requires Metal and reports failure instead of falling back.
sony2fuji_status sony2fuji_analyze_image(
    const sony2fuji_buffer* image, sony2fuji_gpu_mode mode, uint32_t* rgb_bins,
    uint32_t* shadows, uint32_t* highlights, sony2fuji_buffer* clipping_mask
);

#define SONY2FUJI_BSH_DIAGNOSIS_VERSION 1u
#define SONY2FUJI_BSH_SAMPLE_VERSION 1u

typedef enum sony2fuji_bsh_cast_hint {
    SONY2FUJI_BSH_CAST_INSUFFICIENT_NEUTRALS = 0,
    SONY2FUJI_BSH_CAST_BALANCED = 1,
    SONY2FUJI_BSH_CAST_WARM_YELLOW_AMBER = 2,
    SONY2FUJI_BSH_CAST_COOL_BLUE = 3,
    SONY2FUJI_BSH_CAST_GREEN = 4,
    SONY2FUJI_BSH_CAST_MAGENTA = 5
} sony2fuji_bsh_cast_hint;

typedef enum sony2fuji_hsl_channel {
    SONY2FUJI_HSL_CHANNEL_RED = 0,
    SONY2FUJI_HSL_CHANNEL_ORANGE = 1,
    SONY2FUJI_HSL_CHANNEL_YELLOW = 2,
    SONY2FUJI_HSL_CHANNEL_GREEN = 3,
    SONY2FUJI_HSL_CHANNEL_AQUA = 4,
    SONY2FUJI_HSL_CHANNEL_BLUE = 5,
    SONY2FUJI_HSL_CHANNEL_PURPLE = 6,
    SONY2FUJI_HSL_CHANNEL_MAGENTA = 7
} sony2fuji_hsl_channel;

typedef struct sony2fuji_bsh_diagnose_options {
    uint32_t version;
    uint32_t struct_size;
    uint32_t sample_stride; // 0 = auto max(1, max(width, height) / 360)
    uint32_t reserved;      // Must be 0
} sony2fuji_bsh_diagnose_options;

typedef struct sony2fuji_bsh_hsl_channel_stats {
    float coverage_pct;
    float mean_hue_deg;
    float mean_sat_pct;
    float mean_brightness_pct;
    int32_t active; // 1 when coverage_pct >= 0.2%, else 0
} sony2fuji_bsh_hsl_channel_stats;

typedef struct sony2fuji_bsh_diagnosis {
    uint32_t version;
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
    uint32_t bit_depth;
    uint32_t channels;
    uint64_t sampled_pixels;

    float blacks_0_10_pct;
    float shadows_10_35_pct;
    float midtones_35_65_pct;
    float lights_65_90_pct;
    float highlights_90_100_pct;
    float mean_luma_0_1;
    float luma_p01;
    float luma_p05;
    float luma_p25;
    float luma_p50;
    float luma_p75;
    float luma_p95;
    float luma_p99;
    float dynamic_spread_p95_minus_p05;

    float shadow_crush_pct;
    float white_blowout_pct;
    float channel_clip_high_any_pct;
    float channel_clip_high_r_pct;
    float channel_clip_high_g_pct;
    float channel_clip_high_b_pct;

    float neutral_midtone_coverage_pct;
    float r_over_g;
    float b_over_g;
    sony2fuji_bsh_cast_hint cast_hint;

    float mean_s_pct;
    float p95_s_pct;
    float low_sat_pct;
    float melting_saturation_pct;
    int32_t melting_warning;
    uint32_t reserved;

    sony2fuji_bsh_hsl_channel_stats hsl_channels[SONY2FUJI_HSL_CHANNELS];
} sony2fuji_bsh_diagnosis;

typedef struct sony2fuji_bsh_sample_query {
    uint32_t version;
    uint32_t struct_size;
    float norm_x;      // [0, 1]
    float norm_y;      // [0, 1]
    float radius_norm; // >= 0; 0 = 1x1 pixel; >0 = box half-extent round(radius_norm * max(w, h))
    uint32_t reserved; // Must be 0
} sony2fuji_bsh_sample_query;

typedef struct sony2fuji_bsh_sample_result {
    uint32_t version;
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
    uint32_t pixel_x;
    uint32_t pixel_y;
    uint32_t sample_count;
    sony2fuji_hsl_channel nearest_hsl_channel;
    float linear_rgb[3];
    float srgb_rgb[3];
    float hsb[3]; // [0]=hue [0,360), [1]=sat % [0,100], [2]=brightness % [0,100]
    uint32_t rgb_8bit[3];
} sony2fuji_bsh_sample_result;

// Computes full B->S->H quantitative diagnostics from an in-memory sRGB RGB8/RGBA8/RGBA16 buffer.
// options may be NULL (uses default auto stride). Preserves existing sony2fuji_analyze_image untouched.
sony2fuji_status sony2fuji_diagnose_image(
    const sony2fuji_buffer* image,
    const sony2fuji_bsh_diagnose_options* options,
    sony2fuji_bsh_diagnosis* out_diagnosis
);

// Samples a normalized region on an sRGB RGB8/RGBA8/RGBA16 buffer and returns mean linear RGB,
// sRGB RGB, HSB, 8-bit RGB, and nearest HSL channel (red..magenta).
sony2fuji_status sony2fuji_sample_region_bsh(
    const sony2fuji_buffer* image,
    const sony2fuji_bsh_sample_query* query,
    sony2fuji_bsh_sample_result* out_result
);

// Does not change request v2 layout. The mode participates in the RAW cache key.
sony2fuji_status sony2fuji_session_set_raw_exposure_mode(
    sony2fuji_session* session, sony2fuji_raw_exposure_mode mode
);

// FBDD before demosaic: 0 off (default), 1 light, 2 full. Keeps request v2 ABI.
// Enabled FBDD requires a three-color Bayer RAW and disables half-size decoding.
// Unsupported inputs return UNSUPPORTED at processing time, never a silent no-op.
sony2fuji_status sony2fuji_session_set_raw_noise_reduction(sony2fuji_session* session, int32_t level);

// Additive desktop experiment; old requests and clients remain AI-off by default.
// Copies the directory strings. Configuration does not start inference.
// Active AI bypasses FBDD, wavelet and display chroma denoising while preserving their settings.
int32_t sony2fuji_ai_available(void);
// Read-only native GPU probe. Does not load models or start inference; 0 means no supported hardware.
int32_t sony2fuji_ai_hardware_available(void);
// DirectML hardware inventory as UTF-8 JSON (version 1). Does not load models or run inference.
// The calling thread owns the returned snapshot until its next inventory call; other platforms return an empty list.
const char* sony2fuji_ai_get_devices(void);
// Additive selector: null/empty means Auto (prefer a high-performance discrete GPU).
// Copies a device ID returned by the inventory, not an adapter index. Missing explicit devices fail without rerouting.
// This is a worker-session setting; it does not change the v1 AI config layout or ordinary rendering GPU selection.
sony2fuji_status sony2fuji_session_set_ai_device(sony2fuji_session* session, const char* device_id);
// Bounded native runtime context and warning/error log as UTF-8 JSON. No image data or source paths are added.
// Runtime messages can contain paths: clients must redact them before exporting. Valid until the next getter call.
const char* sony2fuji_session_get_ai_diagnostics(const sony2fuji_session* session);
sony2fuji_status sony2fuji_session_set_ai_denoise(sony2fuji_session* session, const sony2fuji_ai_denoise_config* config);
// Sets DualDn AI denoise blend strength in [0.0, 1.0] (default 1.0 = full AI denoise).
// Does not invalidate prepared AI disk caches or trigger re-inference.
sony2fuji_status sony2fuji_session_set_ai_denoise_blend(sony2fuji_session* session, float strength);
// Explicit full-resolution preparation. Use a separate worker-owned session so previews remain responsive.
// Cache keys exclude exposure/LUT/geometry, include WB and processing version for RGB, and retain reusable RAW output.
// Missing/corrupt results make process/export return AI_NOT_READY; process never starts inference or silently disables AI.
// Cancellation: the AI progress callback returning 0 and the session cancellation callback
// (sony2fuji_session_set_cancellation_callback) are equivalent channels; with progress==nullptr the session
// callback is the only one. A cancelled prepare returns CANCELLED without publishing the final renderable
// AI cache (.scenecache/.rgbcache stay unpublished, so process/export still return AI_NOT_READY); the
// reusable Bayer first-stage .rawcache may remain on disk. Every publish-time check runs in beforePublish,
// strictly before the rename commit point.
sony2fuji_status sony2fuji_session_prepare_ai(sony2fuji_session* session, const sony2fuji_request* request,
    sony2fuji_ai_progress_callback progress, void* context);
// Valid until the next AI operation on this session. Always returns a non-null string.
const char* sony2fuji_session_get_ai_error(const sony2fuji_session* session);
// Actual producers of the last prepared/loaded result, including cache hits; empty before completion.
// CoreML describes the native CPU/GPU runtime, not exclusive GPU execution. ISP remains CPU.
const char* sony2fuji_session_get_ai_backend(const sony2fuji_session* session);

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
// Version 1 retains tiled SWT acceleration on Metal/GLES/D3D11 and CPU fallback.
// Version 2 (C5) filters on CPU; Auto may retain GPU display rendering.
// Force rejects active C5 filtering; it never substitutes CPU for a required GPU.
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

// Immutable CPU reference after tone/vibrance, before HSL, with the same geometry
// and requested sizing. Only BUFFER requests are accepted; this never exports.
// PREVIEW retains the caller's proxy policy and is not exact-source/GPU parity.
// Serialize capture with session rendering. GPU policy and last render metadata
// are preserved. The snapshot owns its pixels and out_probe is null on failure.
sony2fuji_status sony2fuji_session_create_hsl_probe(sony2fuji_session* session,
    const sony2fuji_request* request, uint64_t source_revision, uint64_t request_revision,
    sony2fuji_hsl_probe** out_probe);
// Coordinates [0,1] address first/last pixel centers of the geometry result.
// Revision labels must match the snapshot. The caller must additionally match
// them to its current displayed photo/frame before applying an asynchronous result.
// Gray (<1/255 channel spread), outside, stale and nonfinite pixels return no weights.
// Nonfinite query coordinates are OUTSIDE; NONFINITE describes sampled pixels.
// Errors clear result; an OK call may still report an unavailable sample.
sony2fuji_status sony2fuji_hsl_probe_sample(const sony2fuji_hsl_probe* probe,
    const sony2fuji_hsl_probe_query* query, sony2fuji_hsl_probe_result* result);
void sony2fuji_hsl_probe_destroy(sony2fuji_hsl_probe* probe);

// Additive API; request v2 stays unchanged. All zero is an exact bypass.
// Display-encoded sRGB: black/white precede legacy tone, vibrance precedes HSL.
// Invalid values preserve the previous state; reused sessions must explicitly
// set the complete configuration, including zero for an unadjusted next photo.
sony2fuji_status sony2fuji_session_set_tone_controls(
    sony2fuji_session* session, const sony2fuji_tone_controls_config* config
);

// Additive CPU v1 stages; request v2 and photo_effects v1 stay unchanged.
// Dehaze runs after the look, clarity after denoising and before sharpening.
// FINAL/export use the complete source; viewport PREVIEW+BUFFER may reduce
// working pixels at the full-source analysis scale. GPU Auto uses CPU for the
// whole render; Force returns UNSUPPORTED. Invalid configs
// retain previous state. Reused sessions must set both fields, including zero.
sony2fuji_status sony2fuji_session_set_atmosphere(
    sony2fuji_session* session, const sony2fuji_atmosphere_config* config
);

// Display-linear grading after HSL, before chroma denoise. All saturation zero
// bypasses exactly. Invalid values retain prior state. Set all zones on each
// request, including identity when reusing a session for an ungraded photo.
sony2fuji_status sony2fuji_session_set_color_grading(
    sony2fuji_session* session, const sony2fuji_color_grading_config* config
);

// Additive v2 color grading setter (per-zone luminance, global wheel, blending, balance).
sony2fuji_status sony2fuji_session_set_color_grading_v2(
    sony2fuji_session* session, const sony2fuji_color_grading_v2_config* config
);

// Legacy mode has count=0 and uses request.tone_curve unchanged. Custom mode
// requires 2..33 finite normalized points, fixed (0,0)/(1,1), increasing x and
// nondecreasing y; request.tone_curve must be zero. Identity is an exact bypass.
// PCHIP runs after highlights/shadows, before contrast/saturation. Invalid
// setters retain state; configure every reused session, including legacy reset.
// Precision-limited custom curves use CPU Auto; Force returns UNSUPPORTED.
sony2fuji_status sony2fuji_session_set_tone_curve(
    sony2fuji_session* session, const sony2fuji_tone_curve_config* config
);
// Atomically replaces all four curves. The single-curve setter clears R/G/B.
// Independent channels follow the master and currently require CPU rendering.
sony2fuji_status sony2fuji_session_set_tone_curves(
    sony2fuji_session* session, const sony2fuji_tone_curve_set_config* config);
// Stateless custom-curve samples for editor canvases; same evaluator as render.
// Custom mode, nonzero count and finite x are required. Invalid input leaves y
// untouched. x and y may be the same array; no session/render lock is needed.
sony2fuji_status sony2fuji_sample_tone_curve(const sony2fuji_tone_curve_config* config,
    const double* x, double* y, uint32_t count);

// Additive v2 tone curve setter (free endpoints y0/y1 in [0,1], luminosity mode, parametric bands).
sony2fuji_status sony2fuji_session_set_tone_curves_v2(
    sony2fuji_session* session, const sony2fuji_tone_curve_set_v2_config* config
);

// Stateless evaluator supporting free-endpoint custom curves + optional parametric curve (NULL = none).
sony2fuji_status sony2fuji_sample_tone_curve_v2(
    const sony2fuji_tone_curve_config* config,
    const sony2fuji_tone_curve_parametric_config* parametric,
    const double* x,
    double* y,
    uint32_t count
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
// output resizing. Viewport previews and active geometry report the full-source
// canvas. With viewport preview disabled, identity reports the decoded input size.
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

// Effective as-shot RAW white balance rounded half-away-from-zero for UI display
// (returns fixed 6500/0 for normal X3F; UNSUPPORTED for raster or uncalibrated files).
sony2fuji_status sony2fuji_session_get_effective_raw_white_balance(
    const sony2fuji_session* session, float* temperature, float* tint
);

#define SONY2FUJI_RECIPE_WB_REQUEST_VERSION 1u
typedef struct sony2fuji_recipe_wb_request {
    uint32_t version;
    uint32_t struct_size;
    const char* input_path;
    sony2fuji_processing_version processing_version;
    sony2fuji_x3f_mode x3f_mode;
    sony2fuji_raw_exposure_mode exposure_mode;
    int32_t recipe_active;
    float recipe_strength;
    int32_t custom_wb;
    float temperature;
    float tint;
} sony2fuji_recipe_wb_request;

#define SONY2FUJI_RECIPE_WB_RESULT_VERSION 1u
typedef struct sony2fuji_recipe_wb_result {
    uint32_t version;
    uint32_t struct_size;
    sony2fuji_wb_mode wb_mode;
    float temperature;
    float tint;
    float camera_temperature;
    float camera_tint;
    int32_t camera_calibrated;
} sony2fuji_recipe_wb_result;

// Resolves recipe white balance for a RAW file, using session file-identity cache and
// a temporary 32px neutral RAW probe when calibration has not been read yet.
// Normal X3F files resolve directly to calibrated 6500/0 without probing.
// Uncalibrated RAW files return SONY2FUJI_STATUS_UNSUPPORTED (with camera_calibrated = 0).
sony2fuji_status sony2fuji_session_resolve_recipe_wb(
    sony2fuji_session* session,
    const sony2fuji_recipe_wb_request* request,
    sony2fuji_recipe_wb_result* result
);

#define SONY2FUJI_WB_PROBE_VERSION 1u

typedef enum sony2fuji_wb_probe_availability {
    SONY2FUJI_WB_PROBE_AVAILABLE = 0,
    SONY2FUJI_WB_PROBE_OVEREXPOSED = 1, // All pixels in window had a channel >= 0.98
    SONY2FUJI_WB_PROBE_OUTSIDE = 2,     // norm_x / norm_y outside [0, 1] or nonfinite
    SONY2FUJI_WB_PROBE_UNAVAILABLE = 3  // Uncalibrated RAW or unsupported input
} sony2fuji_wb_probe_availability;

typedef struct sony2fuji_wb_probe_query {
    uint32_t version;
    uint32_t struct_size;
    float norm_x;          // [0, 1] in post-geometry canvas coordinates
    float norm_y;          // [0, 1] in post-geometry canvas coordinates
    uint32_t window_size;  // 0 = default 3; allowed values: 0, 1, 3, 5
    uint32_t reserved;     // Must be 0
} sony2fuji_wb_probe_query;

typedef struct sony2fuji_wb_probe_result {
    uint32_t version;
    uint32_t struct_size;
    sony2fuji_wb_probe_availability availability;
    uint32_t valid_pixel_count;
    uint32_t rejected_overexposed_count;
    float temperature;    // [2000, 50000] K (relative around 6500 K for raster/X3F)
    float tint;           // [-150, 150]
    float sampled_rgb[3]; // Mean linear RGB of accepted pixels
    float wb_mul[3];      // Normalized multipliers (wb_mul[1] == 1.0)
    uint32_t reserved;
} sony2fuji_wb_probe_result;

sony2fuji_status sony2fuji_session_sample_wb_probe(
    sony2fuji_session* session,
    const sony2fuji_request* request,
    const sony2fuji_wb_probe_query* query,
    sony2fuji_wb_probe_result* out_result
);

sony2fuji_status sony2fuji_session_set_gpu_config(
    sony2fuji_session* session,
    const sony2fuji_gpu_config* config
);

// Optional cooperative cancellation for sony2fuji_process calls that render into a
// buffer (preview or final) and for every FINAL call, including file exports.
// sony2fuji_session_create_hsl_probe always honours it. Compatibility previews are
// independent. Return nonzero to cancel. Set/clear only on the session's serialized
// worker; the callback may read an atomic signal updated by another thread. During
// a single operation, the callback may be invoked concurrently on multiple internal
// worker threads (for example OpenCV/OpenMP parallel pixel loops or decoder monitor
// threads), so its implementation must be lock-free or synchronize itself. It must
// not throw, reenter the session, or outlive its context. Null disables cancellation. Streamed HDR export
// checks it before publishing. sony2fuji_session_prepare_ai honours it on every tile, source-identity and
// cache-publish checkpoint even when its AI progress callback is null. A cancelled call returns CANCELLED
// without publishing partial output: a buffer stays empty, and a FINAL file export
// keeps the destination byte-identical because every encoder writes a staging file,
// checks cancellation during encoding and at the pre-publish commit point, and never
// rolls back or alters status after the atomic replace succeeds. The session can
// render another request.
typedef int32_t (*sony2fuji_cancel_callback)(void* context);
sony2fuji_status sony2fuji_session_set_cancellation_callback(
    sony2fuji_session* session, sony2fuji_cancel_callback callback, void* context);

sony2fuji_status sony2fuji_process(
    sony2fuji_session* session,
    const sony2fuji_request* request,
    sony2fuji_buffer* out_buffer
);

// Renders `request` on `session` and returns a display-sRGB RGBA16 buffer in
// `out_rgba16` for diagnostics. When `request->output_target == SONY2FUJI_TARGET_FILE`,
// the output file is also written in the same pass. When `output_target == SONY2FUJI_TARGET_BUFFER`,
// `out_rgba16` receives RGBA16 directly without 8-bit quantization.
// Pass a zero-initialized or previously released buffer; release with `sony2fuji_release_buffer`.
sony2fuji_status sony2fuji_session_render_rgba16(
    sony2fuji_session* session,
    const sony2fuji_request* request,
    sony2fuji_buffer* out_rgba16
);

#define SONY2FUJI_PROCESSING_MIGRATION_VERSION 1u
typedef enum sony2fuji_migration_disposition {
    SONY2FUJI_MIGRATION_UNCHANGED = 0,
    SONY2FUJI_MIGRATION_ACCEPTED = 1,
    SONY2FUJI_MIGRATION_REJECTED = 2
} sony2fuji_migration_disposition;

typedef struct sony2fuji_processing_migration_result {
    uint32_t version;
    uint32_t struct_size;
    int32_t source_version;
    int32_t target_version;
    int32_t disposition;
    uint32_t evaluation_count;
    // Canonical core values, including the core's reversed highlight sign.
    float exposure_ev;
    float contrast;
    float highlights;
    float shadows;
    float saturation;
    float black_point;
    float white_point;
    float vibrance;
    float clarity;
    float dehaze;
    // Normalized display-sRGB errors over all full-source pixels (16-bit snapshots).
    // Worst tile uses native 64x64 regions; detail uses all horizontal/vertical gradients.
    float rgb_rmse;
    float p99_error;
    float worst_tile_rmse;
    float detail_rmse;
} sony2fuji_processing_migration_result;

// Fits supported v1/v2 SDR edits to v3 in a private session. No source/session/file
// is changed and no output file is created. All configured edits and the request's
// input/look are retained; only the ten result scalars are fitted. ACCEPTED requires
// full-source validation after the bounded proxy search. Failure or REJECTED must
// retain the saved source identity/settings. AI sessions and Force are unsupported.
// The session cancellation callback applies throughout this operation, including
// validation. The caller keeps input/look bytes stable and commits with its own CAS.
sony2fuji_status sony2fuji_session_migrate_processing(
    const sony2fuji_session* session,
    const sony2fuji_request* request,
    sony2fuji_processing_migration_result* result
);

#define SONY2FUJI_RENDER_OPTIONS_V1_VERSION 1u
typedef struct sony2fuji_render_options_v1 {
    uint32_t version;
    uint32_t struct_size;
    sony2fuji_input_type input_type;
    sony2fuji_pixel_format input_pixel_format;
    const char* input_path;
    const void* input_pixels;
    uint32_t input_width;
    uint32_t input_height;
    sony2fuji_color_space input_color_space;
    int32_t input_is_linear;
    sony2fuji_intent intent;
    sony2fuji_size_mode size_mode;
    uint32_t target_width;
    uint32_t target_height;
    uint32_t long_edge;
    uint32_t short_edge;
    uint32_t preview_long_edge;
    int32_t interactive_preview;
    int32_t viewport_preview;
    uint32_t reserved;
    const sony2fuji_viewport_roi* viewport_roi;
    sony2fuji_output_target output_target;
    sony2fuji_output_format output_format;
    const char* output_path;
    uint32_t jpeg_quality;
    uint32_t reserved2;
} sony2fuji_render_options_v1;

// Stateless SDR execution entries with optional atomic CanonicalEditState JSON.
// When edit_state_json is non-NULL, it is parsed and committed atomically before
// running; when NULL, the session's current committed CanonicalEditState is used.
// Transient options (intent, interactive_preview, viewport_preview, viewport_roi)
// apply only to the current call and never leak across calls.
sony2fuji_status sony2fuji_session_render(
    sony2fuji_session* session,
    const sony2fuji_render_options_v1* options,
    const char* edit_state_json,
    sony2fuji_buffer* out_buffer,
    sony2fuji_viewport_roi_result* out_roi
);

sony2fuji_status sony2fuji_session_render_rgba16_with_options(
    sony2fuji_session* session,
    const sony2fuji_render_options_v1* options,
    const char* edit_state_json,
    sony2fuji_buffer* out_rgba16
);

sony2fuji_status sony2fuji_session_create_hsl_probe_json(
    sony2fuji_session* session,
    const sony2fuji_render_options_v1* options,
    const char* edit_state_json,
    uint64_t source_revision,
    uint64_t request_revision,
    sony2fuji_hsl_probe** out_probe
);

sony2fuji_status sony2fuji_session_estimate_auto_exposure_json(
    sony2fuji_session* session,
    const sony2fuji_render_options_v1* options,
    const char* edit_state_json,
    float* exposure_ev
);

sony2fuji_status sony2fuji_session_sample_wb_probe_json(
    sony2fuji_session* session,
    const sony2fuji_render_options_v1* options,
    const char* edit_state_json,
    const sony2fuji_wb_probe_query* query,
    sony2fuji_wb_probe_result* out_result
);

sony2fuji_status sony2fuji_session_prepare_ai_json(
    sony2fuji_session* session,
    const sony2fuji_render_options_v1* options,
    const char* edit_state_json,
    sony2fuji_ai_progress_callback progress,
    void* context
);

sony2fuji_status sony2fuji_preview_lut_compatibility_json(
    sony2fuji_session* session,
    const sony2fuji_render_options_v1* options,
    const char* edit_state_json,
    const char* configuration_json,
    sony2fuji_buffer* out_buffer
);

sony2fuji_status sony2fuji_session_migrate_processing_json(
    sony2fuji_session* session,
    const sony2fuji_render_options_v1* options,
    const char* edit_state_json,
    sony2fuji_processing_migration_result* result
);

sony2fuji_status sony2fuji_compute_histogram(
    const sony2fuji_buffer* buffer,
    uint32_t bins,
    float* out_bins
);

/* === Wave W-E: Fast Full-Res GPU & Pyramid Grid === */
#define SONY2FUJI_FAST_GPU_QUERY_V1_VERSION 1u
typedef struct sony2fuji_fast_gpu_query_v1 {
    uint32_t version;
    uint32_t struct_size;
    sony2fuji_input_type input_type;
    uint32_t input_width;
    uint32_t input_height;
    uint32_t max_pixels;
    const char* input_path;
} sony2fuji_fast_gpu_query_v1;

// Evaluates whether the current/given CanonicalEditState and query can run on the
// fast full-resolution SDR GPU path without mutating any session state.
sony2fuji_status sony2fuji_session_supports_fast_full_res_gpu(
    sony2fuji_session* session,
    const sony2fuji_fast_gpu_query_v1* query,
    const char* edit_state_json,
    int32_t* out_supported
);

#define SONY2FUJI_PYRAMID_CONFIG_V1_VERSION 1u
typedef struct sony2fuji_pyramid_config_v1 {
    uint32_t version;
    uint32_t struct_size;
    uint32_t full_width;
    uint32_t full_height;
    uint32_t tile_size;
    uint32_t overscan_ring;
    double zoom_scale;
    double base_scale;
    double visible_x0;
    double visible_y0;
    double visible_x1;
    double visible_y1;
} sony2fuji_pyramid_config_v1;

typedef struct sony2fuji_pyramid_tile_v1 {
    int32_t level;
    int32_t col;
    int32_t row;
    uint32_t max_output_long_edge;
    double norm_x0;
    double norm_y0;
    double norm_x1;
    double norm_y1;
} sony2fuji_pyramid_tile_v1;

#define SONY2FUJI_DETAIL_COVERAGE_QUERY_V1_VERSION 1u
typedef struct sony2fuji_detail_coverage_query_v1 {
    uint32_t version;
    uint32_t struct_size;
    uint32_t tile_pixel_width;
    uint32_t tile_pixel_height;
    uint32_t full_width;
    uint32_t full_height;
    uint32_t max_output_long_edge;
    uint32_t reserved;
    double tile_norm_x0;
    double tile_norm_y0;
    double tile_norm_x1;
    double tile_norm_y1;
    double visible_norm_x0;
    double visible_norm_y0;
    double visible_norm_x1;
    double visible_norm_y1;
    double required_zoom_scale;
} sony2fuji_detail_coverage_query_v1;

sony2fuji_status sony2fuji_pyramid_level(
    double zoom_scale,
    double base_scale,
    int32_t* out_level
);

sony2fuji_status sony2fuji_pyramid_tiles(
    const sony2fuji_pyramid_config_v1* config,
    sony2fuji_pyramid_tile_v1* out_tiles,
    uint32_t capacity,
    uint32_t* out_count
);

sony2fuji_status sony2fuji_pyramid_level0_grid(
    uint32_t full_width,
    uint32_t full_height,
    uint32_t tile_size,
    sony2fuji_pyramid_tile_v1* out_tiles,
    uint32_t capacity,
    uint32_t* out_count
);

sony2fuji_status sony2fuji_detail_overlay_covers(
    const sony2fuji_detail_coverage_query_v1* query,
    int32_t* out_covers
);

void sony2fuji_release_buffer(sony2fuji_buffer* buffer);

const char* sony2fuji_status_message(sony2fuji_status status);

// Inspection & Geometry Projection

typedef enum sony2fuji_inspection_overlay_mode {
    SONY2FUJI_INSPECTION_OVERLAY_NONE = 0,
    SONY2FUJI_INSPECTION_OVERLAY_SKETCH_LUMINANCE = 1,
    SONY2FUJI_INSPECTION_OVERLAY_WARM_COOL_BW = 2,
    SONY2FUJI_INSPECTION_OVERLAY_OVERSATURATION_HEATMAP = 3,
    SONY2FUJI_INSPECTION_OVERLAY_SKIN_HUE_AMPLIFICATION = 4,
    SONY2FUJI_INSPECTION_OVERLAY_NEUTRAL_GRAY_50 = 5
} sony2fuji_inspection_overlay_mode;

#define SONY2FUJI_INSPECTION_SAMPLE_VERSION 1u
typedef struct sony2fuji_inspection_sample {
    uint32_t version;
    uint32_t struct_size;
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t reserved0;
    uint32_t reserved1;
    double hue_deg;
    double saturation_pct;
    double brightness_pct;
    double luminance;
} sony2fuji_inspection_sample;

sony2fuji_status sony2fuji_geometry_output_size(
    uint32_t source_width,
    uint32_t source_height,
    const sony2fuji_geometry_config* geometry,
    const sony2fuji_perspective_config* perspective,
    uint32_t* out_width,
    uint32_t* out_height
);

sony2fuji_status sony2fuji_geometry_infer_source_size(
    uint32_t output_width,
    uint32_t output_height,
    const sony2fuji_geometry_config* geometry,
    const sony2fuji_perspective_config* perspective,
    uint32_t* out_source_width,
    uint32_t* out_source_height
);

sony2fuji_status sony2fuji_geometry_output_norm_to_source_norm(
    uint32_t source_width,
    uint32_t source_height,
    const sony2fuji_geometry_config* geometry,
    const sony2fuji_perspective_config* perspective,
    double out_x,
    double out_y,
    double* out_source_x,
    double* out_source_y,
    int32_t* out_valid
);

sony2fuji_status sony2fuji_geometry_source_norm_to_output_norm(
    uint32_t source_width,
    uint32_t source_height,
    const sony2fuji_geometry_config* geometry,
    const sony2fuji_perspective_config* perspective,
    double source_x,
    double source_y,
    double* out_output_x,
    double* out_output_y,
    int32_t* out_valid
);

sony2fuji_status sony2fuji_inspection_color_from_rgb(
    uint8_t r,
    uint8_t g,
    uint8_t b,
    sony2fuji_inspection_sample* out_sample
);

sony2fuji_status sony2fuji_inspection_sample_patch(
    const sony2fuji_buffer* image,
    double norm_x,
    double norm_y,
    uint32_t radius_px,
    sony2fuji_inspection_sample* out_sample
);

sony2fuji_status sony2fuji_inspection_overlay_pixel(
    uint8_t r,
    uint8_t g,
    uint8_t b,
    sony2fuji_inspection_overlay_mode mode,
    uint8_t* out_r,
    uint8_t* out_g,
    uint8_t* out_b
);

sony2fuji_status sony2fuji_inspection_render_overlay(
    const sony2fuji_buffer* src,
    sony2fuji_inspection_overlay_mode mode,
    sony2fuji_buffer* dst
);

/* === Wave W-F3: Sony PTP/IP, Live-View Focus & Focus State Machine === */

#define SONY2FUJI_SONY_PTPIP_DATA_LIMIT (8u << 20)
#define SONY2FUJI_SONY_SLOT_DATES_LIMIT (256u << 10)
#define SONY2FUJI_SONY_TAP_FOCUS_TIMEOUT_MS 1800ULL
#define SONY2FUJI_SONY_FOCUS_STATE_VERSION 1u

typedef struct sony2fuji_sony_device_info sony2fuji_sony_device_info;
typedef struct sony2fuji_sony_remote_descriptor sony2fuji_sony_remote_descriptor;
typedef struct sony2fuji_sony_property_table sony2fuji_sony_property_table;
typedef struct sony2fuji_sony_mobile_page sony2fuji_sony_mobile_page;
typedef struct sony2fuji_sony_legacy_object sony2fuji_sony_legacy_object;

typedef enum sony2fuji_sony_live_view_frame_kind {
    SONY2FUJI_SONY_LIVE_FRAME_FOCUS = 0,
    SONY2FUJI_SONY_LIVE_FRAME_FACE = 1,
    SONY2FUJI_SONY_LIVE_FRAME_TRACKING = 2
} sony2fuji_sony_live_view_frame_kind;

typedef enum sony2fuji_sony_property_value_kind {
    SONY2FUJI_SONY_PROP_NUMBER = 0,
    SONY2FUJI_SONY_PROP_TEXT = 1,
    SONY2FUJI_SONY_PROP_OPAQUE = 2
} sony2fuji_sony_property_value_kind;

typedef enum sony2fuji_sony_focus_target {
    SONY2FUJI_SONY_FOCUS_TARGET_NONE = 0,
    SONY2FUJI_SONY_FOCUS_TARGET_REMOTE_TOUCH = 1,
    SONY2FUJI_SONY_FOCUS_TARGET_AF_AREA_POSITION = 2
} sony2fuji_sony_focus_target;

typedef enum sony2fuji_sony_focus_unavailable_reason {
    SONY2FUJI_SONY_FOCUS_AVAILABLE = 0,
    SONY2FUJI_SONY_FOCUS_UNAVAILABLE_MANUAL_FOCUS = 1,
    SONY2FUJI_SONY_FOCUS_UNAVAILABLE_AREA_FIXED = 2,
    SONY2FUJI_SONY_FOCUS_UNAVAILABLE_UNSUPPORTED = 3
} sony2fuji_sony_focus_unavailable_reason;

typedef enum sony2fuji_sony_focus_render_mode {
    SONY2FUJI_SONY_FOCUS_RENDER_NONE = 0,
    SONY2FUJI_SONY_FOCUS_RENDER_LIVE_FRAMES = 1,
    SONY2FUJI_SONY_FOCUS_RENDER_TAP_RETICLE = 2
} sony2fuji_sony_focus_render_mode;

typedef struct sony2fuji_sony_ptpip_header {
    uint32_t packet_type;
    uint32_t payload_size;
} sony2fuji_sony_ptpip_header;

typedef struct sony2fuji_sony_ptpip_start_data {
    uint32_t transaction_id;
    uint32_t reserved0;
    uint64_t total_bytes;
} sony2fuji_sony_ptpip_start_data;

typedef struct sony2fuji_sony_ptpip_response {
    uint16_t response_code;
    uint16_t reserved0;
    uint32_t transaction_id;
    uint32_t param_count;
    uint32_t params[5];
} sony2fuji_sony_ptpip_response;

typedef struct sony2fuji_sony_ptpip_event {
    uint16_t event_code;
    uint16_t reserved0;
    uint32_t transaction_id;
    uint32_t param_count;
    uint32_t params[3];
} sony2fuji_sony_ptpip_event;

typedef struct sony2fuji_sony_property_info {
    uint16_t code;
    uint16_t type;
    int32_t writable;
    uint8_t enabled;
    uint8_t form;
    uint16_t reserved0;
    sony2fuji_sony_property_value_kind value_kind;
    int64_t number_value;
    int32_t has_range;
    uint32_t choice_count;
    int64_t minimum;
    int64_t maximum;
    int64_t step;
} sony2fuji_sony_property_info;

typedef struct sony2fuji_sony_mobile_asset_info {
    uint32_t content;
    uint32_t file;
    uint64_t size;
    uint64_t created;
} sony2fuji_sony_mobile_asset_info;

typedef struct sony2fuji_sony_legacy_object_info {
    uint32_t storage;
    uint16_t format;
    uint16_t reserved0;
    uint64_t size;
} sony2fuji_sony_legacy_object_info;

typedef struct sony2fuji_sony_live_frame_bounds {
    uint32_t body_size;
    uint32_t image_offset;
    uint32_t image_length;
    uint32_t metadata_offset;
    uint32_t metadata_length;
    int32_t has_metadata;
} sony2fuji_sony_live_frame_bounds;

typedef struct sony2fuji_sony_live_view_frame {
    sony2fuji_sony_live_view_frame_kind kind;
    int32_t focused;
    double cx;
    double cy;
    double width;
    double height;
} sony2fuji_sony_live_view_frame;

typedef struct sony2fuji_sony_focus_tap_point {
    double u;
    double v;
    int32_t x;
    int32_t y;
    uint32_t packed;
    uint32_t reserved0;
} sony2fuji_sony_focus_tap_point;

typedef struct sony2fuji_sony_focus_overlay_box {
    double x;
    double y;
    double width;
    double height;
    int32_t is_normalized_square;
    int32_t focused;
} sony2fuji_sony_focus_overlay_box;

typedef struct sony2fuji_sony_focus_state {
    uint32_t version;
    uint32_t struct_size;
    int32_t focus_busy;
    int32_t tap_active;
    uint64_t tap_generation;
    double tap_u;
    double tap_v;
    int32_t tap_x;
    int32_t tap_y;
    uint64_t tap_deadline_ms;
    int32_t tap_focus_locked;
    int32_t props_focus_locked;
    int32_t can_cancel_touch_focus;
    int32_t has_live_frames;
    int32_t has_last_square_ratio;
    int32_t has_pending_deadline;
    double last_square_ratio;
} sony2fuji_sony_focus_state;

typedef struct sony2fuji_sony_focus_render_decision {
    sony2fuji_sony_focus_render_mode mode;
    int32_t effective_focus_locked;
    sony2fuji_sony_focus_overlay_box tap_box;
} sony2fuji_sony_focus_render_decision;

/* PTP/IP framing */

sony2fuji_status sony2fuji_sony_ptpip_build_init_cmd(
    const uint8_t* guid16,
    const char* client_name,
    uint32_t protocol_version,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
);

sony2fuji_status sony2fuji_sony_ptpip_build_init_evt(
    uint32_t connection_number,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
);

sony2fuji_status sony2fuji_sony_ptpip_build_op_req(
    uint32_t data_phase,
    uint16_t op_code,
    uint32_t transaction_id,
    const uint32_t* params,
    uint32_t param_count,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
);

sony2fuji_status sony2fuji_sony_ptpip_build_start_data(
    uint32_t transaction_id,
    uint64_t total_bytes,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
);

sony2fuji_status sony2fuji_sony_ptpip_build_end_data(
    uint32_t transaction_id,
    const uint8_t* payload,
    size_t payload_len,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
);

sony2fuji_status sony2fuji_sony_ptpip_build_probe_resp(
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
);

sony2fuji_status sony2fuji_sony_ptpip_parse_header(
    const uint8_t* header8,
    size_t len,
    uint64_t max_payload_bytes,
    sony2fuji_sony_ptpip_header* out_header
);

sony2fuji_status sony2fuji_sony_ptpip_parse_init_cmd_ack(
    const uint8_t* payload,
    size_t len,
    uint32_t* out_connection_number
);

sony2fuji_status sony2fuji_sony_ptpip_parse_start_data(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_start_data* out_start
);

sony2fuji_status sony2fuji_sony_ptpip_parse_response(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_response* out_resp
);

sony2fuji_status sony2fuji_sony_ptpip_parse_event(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_event* out_evt
);

/* Validation & Wi-Fi credentials */

sony2fuji_status sony2fuji_sony_parse_wifi_credential(
    const uint8_t* data,
    size_t len,
    int32_t is_password,
    char* out_buf,
    size_t capacity,
    size_t* out_len
);

int32_t sony2fuji_sony_is_valid_photo_filename(const char* name);
int32_t sony2fuji_sony_is_photo_filename(const char* name);
int32_t sony2fuji_sony_validate_photo_header(
    const char* name,
    const uint8_t* prefix,
    size_t prefix_len
);

/* 0x1001 Device Info */

sony2fuji_status sony2fuji_sony_parse_device_info(
    const uint8_t* data,
    size_t len,
    sony2fuji_sony_device_info** out_info
);

void sony2fuji_sony_device_info_free(sony2fuji_sony_device_info* info);
const char* sony2fuji_sony_device_info_manufacturer(const sony2fuji_sony_device_info* info);
const char* sony2fuji_sony_device_info_model(const sony2fuji_sony_device_info* info);
const char* sony2fuji_sony_device_info_firmware(const sony2fuji_sony_device_info* info);
const char* sony2fuji_sony_device_info_serial(const sony2fuji_sony_device_info* info);

sony2fuji_status sony2fuji_sony_device_info_operations(
    const sony2fuji_sony_device_info* info,
    uint16_t* out_ops,
    uint32_t capacity,
    uint32_t* out_count
);

/* 0x9202 Remote Descriptor */

sony2fuji_status sony2fuji_sony_parse_remote_descriptor(
    const uint8_t* data,
    size_t len,
    uint16_t* out_version,
    int32_t* out_enum_tables,
    sony2fuji_sony_remote_descriptor** out_desc
);

void sony2fuji_sony_remote_descriptor_free(sony2fuji_sony_remote_descriptor* desc);

sony2fuji_status sony2fuji_sony_remote_descriptor_properties(
    const sony2fuji_sony_remote_descriptor* desc,
    uint16_t* out_props,
    uint32_t capacity,
    uint32_t* out_count
);

sony2fuji_status sony2fuji_sony_remote_descriptor_controls(
    const sony2fuji_sony_remote_descriptor* desc,
    uint16_t* out_controls,
    uint32_t capacity,
    uint32_t* out_count
);

/* 0x9209 Property Table, Focus Policy & Options */

sony2fuji_status sony2fuji_sony_parse_properties(
    const uint8_t* data,
    size_t len,
    int32_t enum_tables,
    sony2fuji_sony_property_table** out_table
);

void sony2fuji_sony_property_table_free(sony2fuji_sony_property_table* table);
uint32_t sony2fuji_sony_property_table_count(const sony2fuji_sony_property_table* table);

sony2fuji_status sony2fuji_sony_property_table_get_at(
    const sony2fuji_sony_property_table* table,
    uint32_t index,
    sony2fuji_sony_property_info* out_info
);

sony2fuji_status sony2fuji_sony_property_table_find(
    const sony2fuji_sony_property_table* table,
    uint16_t code,
    sony2fuji_sony_property_info* out_info
);

const char* sony2fuji_sony_property_table_text_at(
    const sony2fuji_sony_property_table* table,
    uint32_t index
);

sony2fuji_status sony2fuji_sony_property_table_choices_at(
    const sony2fuji_sony_property_table* table,
    uint32_t index,
    int64_t* out_choices,
    uint32_t capacity,
    uint32_t* out_count
);

int32_t sony2fuji_sony_property_accepts(
    const sony2fuji_sony_property_info* info,
    const int64_t* choices,
    uint32_t choice_count,
    int64_t value
);

sony2fuji_status sony2fuji_sony_property_options(
    const sony2fuji_sony_property_info* info,
    const int64_t* choices,
    uint32_t choice_count,
    int32_t only_settable,
    int32_t sort_unique,
    uint32_t max_range_count,
    int64_t* out_values,
    uint32_t capacity,
    uint32_t* out_count
);

void sony2fuji_sony_property_table_focus_indication(
    const sony2fuji_sony_property_table* table,
    int32_t* out_locked,
    int32_t* out_failed
);

int32_t sony2fuji_sony_property_table_can_cancel_touch_focus(
    const sony2fuji_sony_property_table* table,
    const uint16_t* controls,
    uint32_t control_count,
    const uint16_t* operations,
    uint32_t operation_count,
    int32_t remote_ready
);

sony2fuji_status sony2fuji_sony_property_table_resolve_focus_target(
    const sony2fuji_sony_property_table* table,
    const uint16_t* controls,
    uint32_t control_count,
    const uint16_t* operations,
    uint32_t operation_count,
    int32_t remote_ready,
    sony2fuji_sony_focus_target* out_target,
    sony2fuji_sony_focus_unavailable_reason* out_reason
);

/* 0x923b / 0x923c / 0x1008 Contents */

sony2fuji_status sony2fuji_sony_parse_slot_photo_count(
    const uint8_t* data,
    size_t len,
    uint32_t* out_count
);

sony2fuji_status sony2fuji_sony_parse_mobile_page(
    const uint8_t* data,
    size_t len,
    sony2fuji_sony_mobile_page** out_page
);

void sony2fuji_sony_mobile_page_free(sony2fuji_sony_mobile_page* page);
uint32_t sony2fuji_sony_mobile_page_entry_count(const sony2fuji_sony_mobile_page* page);
uint64_t sony2fuji_sony_mobile_page_cursor(const sony2fuji_sony_mobile_page* page);
uint32_t sony2fuji_sony_mobile_page_asset_count(const sony2fuji_sony_mobile_page* page);

sony2fuji_status sony2fuji_sony_mobile_page_asset_at(
    const sony2fuji_sony_mobile_page* page,
    uint32_t index,
    sony2fuji_sony_mobile_asset_info* out_info,
    const char** out_name
);

sony2fuji_status sony2fuji_sony_parse_legacy_object(
    const uint8_t* data,
    size_t len,
    sony2fuji_sony_legacy_object** out_obj
);

void sony2fuji_sony_legacy_object_free(sony2fuji_sony_legacy_object* obj);

sony2fuji_status sony2fuji_sony_legacy_object_get(
    const sony2fuji_sony_legacy_object* obj,
    sony2fuji_sony_legacy_object_info* out_info,
    const char** out_name,
    const char** out_created,
    const char** out_modified
);

/* Live-View Bounds, Metadata & 640x480 Projection */

sony2fuji_status sony2fuji_sony_parse_live_frame_bounds(
    const uint32_t fields4[4],
    uint64_t max_total_bytes,
    sony2fuji_sony_live_frame_bounds* out_bounds
);

sony2fuji_status sony2fuji_sony_parse_live_view_frames(
    const uint8_t* metadata,
    size_t len,
    sony2fuji_sony_live_view_frame* out_frames,
    uint32_t capacity,
    uint32_t* out_count
);

sony2fuji_status sony2fuji_sony_focus_point_from_tap(
    double tap_x,
    double tap_y,
    double container_width,
    double container_height,
    double image_width,
    double image_height,
    int32_t* out_valid,
    sony2fuji_sony_focus_tap_point* out_tap
);

sony2fuji_status sony2fuji_sony_compute_focus_overlay_box(
    const sony2fuji_sony_live_view_frame* frame,
    double left,
    double top,
    double fitted_width,
    double fitted_height,
    sony2fuji_sony_focus_overlay_box* out_box
);

sony2fuji_status sony2fuji_sony_normalized_focus_square_ratio(
    const sony2fuji_sony_live_view_frame* frame,
    double image_width,
    double image_height,
    int32_t* out_valid,
    double* out_ratio
);

sony2fuji_status sony2fuji_sony_tap_focus_side(
    double fitted_width,
    double fitted_height,
    double min_default_px,
    double max_default_px,
    double min_learned_px,
    int32_t has_last_ratio,
    double last_ratio,
    double* out_side
);

/* Virtual-Clock Focus State Machine */

sony2fuji_status sony2fuji_sony_focus_state_init(sony2fuji_sony_focus_state* state);

sony2fuji_status sony2fuji_sony_focus_state_reset(
    sony2fuji_sony_focus_state* state,
    int32_t preserve_last_ratio
);

sony2fuji_status sony2fuji_sony_focus_state_on_tap(
    sony2fuji_sony_focus_state* state,
    double u,
    double v,
    int32_t x,
    int32_t y,
    uint64_t now_ms
);

sony2fuji_status sony2fuji_sony_focus_state_on_cancel_start(sony2fuji_sony_focus_state* state);

sony2fuji_status sony2fuji_sony_focus_state_on_focus_finished(
    sony2fuji_sony_focus_state* state,
    int32_t succeeded,
    int32_t focus_locked,
    uint64_t now_ms
);

sony2fuji_status sony2fuji_sony_focus_state_on_live_frame(
    sony2fuji_sony_focus_state* state,
    const sony2fuji_sony_live_view_frame* frames,
    uint32_t frame_count,
    double image_width,
    double image_height
);

sony2fuji_status sony2fuji_sony_focus_state_on_properties(
    sony2fuji_sony_focus_state* state,
    int32_t can_cancel_touch_focus,
    int32_t props_focus_locked,
    int32_t props_focus_failed
);

sony2fuji_status sony2fuji_sony_focus_state_on_capture_or_param_start(sony2fuji_sony_focus_state* state);

sony2fuji_status sony2fuji_sony_focus_state_on_live_changed(
    sony2fuji_sony_focus_state* state,
    int32_t live_active
);

sony2fuji_status sony2fuji_sony_focus_state_on_tick(
    sony2fuji_sony_focus_state* state,
    uint64_t now_ms
);

sony2fuji_status sony2fuji_sony_focus_state_on_timeout(
    sony2fuji_sony_focus_state* state,
    uint64_t generation,
    uint64_t now_ms
);

sony2fuji_status sony2fuji_sony_focus_state_resolve_render(
    const sony2fuji_sony_focus_state* state,
    double left,
    double top,
    double fitted_width,
    double fitted_height,
    double min_default_px,
    double max_default_px,
    double min_learned_px,
    sony2fuji_sony_focus_render_decision* out_decision
);

#ifdef __cplusplus
} // extern "C"
#endif
