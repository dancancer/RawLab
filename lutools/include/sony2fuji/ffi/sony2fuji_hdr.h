#pragma once

#include "sony2fuji_c.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SONY2FUJI_HDR_VERSION 1u
#define SONY2FUJI_HDR_PROCESSING_VERSION 1u
#define SONY2FUJI_HDR_PROCESSING_TONE_VERSION 2u
#define SONY2FUJI_HDR_PROCESSING_COLOR_VERSION 3u
#define SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION 4u
#define SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION 5u
#define SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION 6u
#define SONY2FUJI_HDR_PROCESSING_LOOK_VERSION 7u
#define SONY2FUJI_HDR_PROCESSING_CHANNEL_CURVES_VERSION 8u

// 独立枚举；不重解释旧 request v2 的 pixel_format/input_type。
enum {
    SONY2FUJI_HDR_RGB32F_LINEAR = 1,
    SONY2FUJI_HDR_RGB8_SRGB = 2,
    SONY2FUJI_HDR_LINEAR_SRGB = 1,
    SONY2FUJI_HDR_DISPLAY_SRGB = 2,
    SONY2FUJI_HDR_HEADROOM_UNKNOWN = 0,
    SONY2FUJI_HDR_HEADROOM_DECLARED = 1,
    SONY2FUJI_HDR_HEADROOM_MEASURED = 2
};
enum {
    SONY2FUJI_HDR_CONTAINER_UNKNOWN = 0, SONY2FUJI_HDR_CONTAINER_JPEG = 1, SONY2FUJI_HDR_CONTAINER_HEIF = 2,
    SONY2FUJI_HDR_CONTAINER_CAMERA_RAW = 3, SONY2FUJI_HDR_CONTAINER_PRORAW = 4,
    SONY2FUJI_HDR_PROTOCOL_UNKNOWN = 0, SONY2FUJI_HDR_PROTOCOL_APPLE = 1,
    SONY2FUJI_HDR_PROTOCOL_ISO = 2, SONY2FUJI_HDR_PROTOCOL_XMP = 3, SONY2FUJI_HDR_PROTOCOL_ISO_XMP = 4,
    SONY2FUJI_HDR_COLOR_UNKNOWN = 0, SONY2FUJI_HDR_COLOR_SRGB = 1,
    SONY2FUJI_HDR_COLOR_DISPLAY_P3 = 2, SONY2FUJI_HDR_COLOR_BT2020 = 3
};
enum {
    SONY2FUJI_HDR_REASON_NONE = 0, SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM = 1,
    SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL = 2, SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR = 3,
    SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION = 4, SONY2FUJI_HDR_REASON_MALFORMED_AUX = 5,
    SONY2FUJI_HDR_REASON_NONFINITE = 6, SONY2FUJI_HDR_REASON_INVALID_BUFFER = 7,
    SONY2FUJI_HDR_REASON_PREVIEW_SOURCE = 8, SONY2FUJI_HDR_REASON_SOURCE_CHANGED = 9,
    SONY2FUJI_HDR_REASON_OUT_OF_MEMORY = 10, SONY2FUJI_HDR_REASON_OUTPUT_IO = 11,
    SONY2FUJI_HDR_REASON_INVALID_ARGUMENT = 12, SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU = 13,
    SONY2FUJI_HDR_REASON_INPUT_IO = 14, SONY2FUJI_HDR_REASON_SAME_FILE = 15,
    SONY2FUJI_HDR_REASON_NOT_HDR = 16, SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW = 17,
    SONY2FUJI_HDR_REASON_LOOK_RESOURCE = 18, SONY2FUJI_HDR_REASON_CAMERA_DEVELOPMENT = 19,
    SONY2FUJI_HDR_REASON_CAMERA_AI = 20, SONY2FUJI_HDR_REASON_CAMERA_PROFILE = 21
};
enum {
    SONY2FUJI_HDR_FIELD_NONE = 0, SONY2FUJI_HDR_FIELD_SOURCE = 1,
    SONY2FUJI_HDR_FIELD_HDR_BUFFER = 2, SONY2FUJI_HDR_FIELD_SDR_BUFFER = 3,
    SONY2FUJI_HDR_FIELD_REQUEST = 4, SONY2FUJI_HDR_FIELD_RESULT = 5,
    SONY2FUJI_HDR_FIELD_SESSION = 6, SONY2FUJI_HDR_FIELD_PATH = 7,
    SONY2FUJI_HDR_FIELD_EXPORT = 8, SONY2FUJI_HDR_FIELD_DIAGNOSTIC = 9, SONY2FUJI_HDR_FIELD_LOOK = 10,
    SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT = 11
};

typedef struct sony2fuji_hdr_diagnostic_v1 {
    uint32_t version, struct_size;
    uint32_t reason, field;
} sony2fuji_hdr_diagnostic_v1;

typedef struct sony2fuji_hdr_source_info_v1 {
    uint32_t version, struct_size;
    uint32_t width, height, orientation, container, protocol, color_description;
    float content_headroom;
    uint32_t headroom_kind;
    uint8_t source_sha256[32];
} sony2fuji_hdr_source_info_v1;

enum { SONY2FUJI_HDR_CAMERA_SOURCE_BAYER = 1 };
// Optional camera probe result tail. Set base.struct_size to sizeof this struct.
typedef struct sony2fuji_hdr_camera_source_info_v1 {
    sony2fuji_hdr_source_info_v1 base;
    uint32_t capabilities;
} sony2fuji_hdr_camera_source_info_v1;

typedef struct sony2fuji_hdr_decode_options_v1 {
    uint32_t version, struct_size;
    uint32_t intent, long_edge;
} sony2fuji_hdr_decode_options_v1;

enum {
    SONY2FUJI_HDR_CAMERA_WB_AS_SHOT = 0, SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE = 1,
    SONY2FUJI_HDR_CAMERA_EXPOSURE_METADATA = 0, SONY2FUJI_HDR_CAMERA_EXPOSURE_SENSOR = 1,
    SONY2FUJI_HDR_CAMERA_LENS_DISTORTION = 1, SONY2FUJI_HDR_CAMERA_LENS_TCA = 2,
    SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP = 4, SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING = 8
};

// Applies only to the ordinary camera RAW decoder. A zero tail keeps the
// established as-shot WB and metadata-adjusted exposure. Custom WB is evaluated
// in camera channels before demosaic; lens correction uses the session database.
typedef struct sony2fuji_hdr_camera_development_v1 {
    uint32_t version, struct_size;
    uint32_t white_balance, exposure_reference;
    float temperature, tint; // both zero for as-shot; otherwise 2000..50000 K and -150..150
    uint32_t fbdd_level, lens_flags; // FBDD 0..2; lens flags are combined with bitwise OR
    const char* lens_profile_id; // optional UTF-8 id with active lens correction
} sony2fuji_hdr_camera_development_v1;

// Set base.version to 2 and base.struct_size to sizeof this structure. The
// required resource is a D65 camera-matrix DCP or RLOOKHDR with a pinned SHA-256.
typedef struct sony2fuji_hdr_camera_development_v2 {
    sony2fuji_hdr_camera_development_v1 base;
    const char* profile_path;
    char profile_sha256[65]; // lowercase hexadecimal and NUL
} sony2fuji_hdr_camera_development_v2;

typedef struct sony2fuji_hdr_camera_profile_info_v1 {
    uint32_t version, struct_size;
    char camera_model[64];
    char sha256[65];
} sony2fuji_hdr_camera_profile_info_v1;

typedef struct sony2fuji_hdr_buffer_v1 {
    uint32_t version, struct_size;
    void* data;
    uint64_t size_bytes;
    uint32_t width, height;
    uint64_t stride_bytes;
    uint32_t pixel_format, color_encoding;
    float content_headroom;
    uint32_t headroom_kind;
} sony2fuji_hdr_buffer_v1;

typedef struct sony2fuji_hdr_image_pair_v1 {
    uint32_t version, struct_size;
    sony2fuji_hdr_buffer_v1 hdr, sdr;
    uint32_t native_width, native_height, orientation_applied;
    uint32_t source_intent, render_intent, is_proxy;
    uint64_t decode_revision;
    float source_headroom;
    uint32_t source_headroom_kind;
    uint8_t source_sha256[32];
    uint64_t owner_token;
    /* 当前几何在原片分辨率上的输出尺寸；忽略预览和导出 long_edge。 */
    uint32_t output_native_width, output_native_height;
} sony2fuji_hdr_image_pair_v1;

typedef struct sony2fuji_hdr_request_v1 {
    uint32_t version, struct_size, hdr_processing_version, intent;
    float exposure_ev, temperature, tint, contrast, highlights, shadows, saturation;
    float crop_x, crop_y, crop_width, crop_height;
    int32_t quarter_turns;
    uint32_t flip_horizontal, flip_vertical;
    float straighten_degrees, perspective_horizontal, perspective_vertical;
    uint32_t long_edge;
} sony2fuji_hdr_request_v1;

// base.version 仍为 1；base.struct_size 填整个 v2 的大小，传入 &base。
// black_point、white_point、curve_strength 均为 [-100,100]。自定义曲线使用归一化曝光档位。
typedef struct sony2fuji_hdr_request_v2 {
    sony2fuji_hdr_request_v1 base;
    float black_point, white_point, curve_strength;
    uint32_t reserved;
    sony2fuji_tone_curve_config curve;
} sony2fuji_hdr_request_v2;

// Pass &base.base. Set its processing version to 3 and its size to the complete v3 request.
// Initialize both nested configs. HSL lightness uses ±1 EV at full scale.
typedef struct sony2fuji_hdr_request_v3 {
    sony2fuji_hdr_request_v2 base;
    float vibrance;
    uint32_t reserved;
    sony2fuji_hsl_config hsl;
    sony2fuji_color_grading_config grading;
} sony2fuji_hdr_request_v3;

// Pass &base.base.base and set its processing version to 4 and size to sizeof(v4).
// A zero peak limit is unlimited. Nonzero values are stops above SDR reference white.
typedef struct sony2fuji_hdr_request_v4 {
    sony2fuji_hdr_request_v3 base;
    float peak_limit_ev;
    float sdr_exposure_ev, sdr_contrast, sdr_saturation;
} sony2fuji_hdr_request_v4;

// Pass &base.base.base.base with processing version 5 and size sizeof(v5).
// Effects use coordinates on the final oriented and resized canvas.
typedef struct sony2fuji_hdr_request_v5 {
    sony2fuji_hdr_request_v4 base;
    sony2fuji_photo_effects_config effects;
} sony2fuji_hdr_request_v5;

// Pass &base.base.base.base.base with processing version 6 and size sizeof(v6).
typedef struct sony2fuji_hdr_request_v6 {
    sony2fuji_hdr_request_v5 base;
    float sharpening; // 0..2
    float clarity, dehaze; // -1..1
    float denoise; // 0..1, rendered RGB
} sony2fuji_hdr_request_v6;

// Pass &base.base.base.base.base.base with processing version 7 and size sizeof(v7).
// Null path with a zero tail is neutral. A supplied UTF-8 path must match the
// full lowercase hex SHA-256 returned by sony2fuji_hdr_probe_look.
typedef struct sony2fuji_hdr_request_v7 {
    sony2fuji_hdr_request_v6 base;
    const char* look_path;
    float look_strength; // 0..2
    uint32_t reserved;
    char look_sha256[65];
} sony2fuji_hdr_request_v7;

// Processing version 8; master remains in the v2 base. No session curve state is inherited.
// Channels map normalized -8..+8 exposure stops after the master luminance curve.
typedef struct sony2fuji_hdr_request_v8 {
    sony2fuji_hdr_request_v7 base;
    sony2fuji_tone_curve_config channels[3]; // red, green, blue
} sony2fuji_hdr_request_v8;

typedef struct sony2fuji_hdr_look_info_v1 {
    uint32_t version, struct_size, grid_size, reserved;
    float domain_min[3], domain_max[3];
    char sha256[65];
} sony2fuji_hdr_look_info_v1;

typedef struct sony2fuji_hdr_export_config_v1 {
    uint32_t version, struct_size;
    uint32_t jpeg_quality, base_color, metadata_policy;
    const char* metadata_source_path;
    uint8_t source_sha256[32];
} sony2fuji_hdr_export_config_v1;

typedef struct sony2fuji_hdr_sdr_export_config_v1 {
    uint32_t version, struct_size;
    uint32_t output_format, quality;
    const char* metadata_source_path;
    uint8_t source_sha256[32];
} sony2fuji_hdr_sdr_export_config_v1;

// 独立的完整来源接口，不借用 HDRImagePair 的 FINAL/owner 语义。
// read_rows 按 HDR(1)、SDR(0) 顺序，各从第 0 行连续读取已定向 RGB32F；
// output 为核心提供的 width*count*3 个 float。回调只在当前线程同步执行，不可抛异常。
// finish_decode 在两份呈现读取完成后调用，供调用方释放解码资源并复核来源。
// 任何失败后调用方仍须销毁自己的 context；不得把预览或不完整画布接到此入口。
typedef sony2fuji_status (*sony2fuji_hdr_read_rows_callback)(void* context, uint32_t hdr,
    uint32_t first_row, uint32_t row_count, float* output);
typedef sony2fuji_status (*sony2fuji_hdr_finish_decode_callback)(void* context);
typedef struct sony2fuji_hdr_stream_source_v1 {
    uint32_t version, struct_size;
    uint32_t native_width, native_height, orientation_applied, source_intent;
    uint64_t decode_revision;
    const char* decoder_identifier;
    uint8_t source_sha256[32];
    void* context;
    sony2fuji_hdr_read_rows_callback read_rows;
    sony2fuji_hdr_finish_decode_callback finish_decode;
    sony2fuji_cancel_callback is_cancelled;
} sony2fuji_hdr_stream_source_v1;

typedef struct sony2fuji_hdr_stream_result_v1 {
    uint32_t version, struct_size;
    uint32_t width, height, native_width, native_height, output_native_width, output_native_height;
    uint64_t decode_revision;
    float source_headroom, edited_headroom; // SDR-only 输出的 edited_headroom 为 0。
} sony2fuji_hdr_stream_result_v1;

enum { SONY2FUJI_HDR_METADATA_ISO_XMP = 1, SONY2FUJI_HDR_METADATA_ISO = 2 };

// 所有结构先清零、填写 version=1/struct_size。请求温度默认 6500，crop 为 0/0/1/1。
// 输出必须为空；核心只写已知前缀，扩展尾部保持不变。调用方串行使用 session。
// 输入仅借用；输出不得修改 owner_token/内部指针或单独 free。release 可重复调用。
// probe 返回 UNSUPPORTED/NOT_HDR 才表示普通 JPEG/HEIF；损坏或不支持的 HDR 不能回落为 SDR 导入。
sony2fuji_status sony2fuji_hdr_probe(const char* path, sony2fuji_hdr_source_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_probe_look(const char* path, sony2fuji_hdr_look_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_decode(const char* path, const sony2fuji_hdr_decode_options_v1* options,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic);
// Explicit camera RAW development. Probe inspects the header only and does not hash
// or unpack the file. Decode returns the oriented canvas and the source digest.
// Pass the base of sony2fuji_hdr_camera_source_info_v1 to also get sensor capabilities.
sony2fuji_status sony2fuji_hdr_probe_camera_raw(const char* path, sony2fuji_hdr_source_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
// Compile only the D65 camera matrices and model identity. The caller owns the
// blob and releases it with sony2fuji_release_blob.
sony2fuji_status sony2fuji_compile_hdr_camera_dcp(const void* data, size_t size_bytes,
    sony2fuji_blob* out_blob, sony2fuji_dcp_error* out_reason);
sony2fuji_status sony2fuji_hdr_probe_camera_profile(const char* path, sony2fuji_hdr_camera_profile_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
// PREVIEW requires a positive long edge. An optional session supplies cancellation
// and the GPU policy. Release the result with sony2fuji_hdr_release_pair.
sony2fuji_status sony2fuji_hdr_decode_camera_raw(sony2fuji_session* session, const char* path,
    const sony2fuji_hdr_decode_options_v1* options, sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_decode_camera_raw_with_development(sony2fuji_session* session, const char* path,
    const sony2fuji_hdr_decode_options_v1* options, const sony2fuji_hdr_camera_development_v1* development,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic);
// Explicit opt-in for calibrated Bayer sources. Configure a hardware AI session
// with sony2fuji_session_set_ai_denoise before calling either function. Preparation
// writes a separate RAW-only cache; decoding consumes it without running inference.
// The GPU availability query does not validate the model package or source.
int32_t sony2fuji_hdr_camera_ai_available(void);
// The 64-digit key identifies the source, model, hardware runtime and Bayer
// protocol. The caller supplies at least 65 bytes; a key does not imply readiness.
sony2fuji_status sony2fuji_hdr_camera_ai_key(sony2fuji_session* session, const char* path,
    char* key, uint32_t capacity, sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_prepare_camera_raw_ai(sony2fuji_session* session, const char* path,
    sony2fuji_ai_progress_callback progress, void* context, sony2fuji_hdr_diagnostic_v1* diagnostic);
// HDR AI accepts camera development v1 with FBDD off. A missing cache returns AI_NOT_READY.
sony2fuji_status sony2fuji_hdr_decode_camera_raw_with_ai(sony2fuji_session* session, const char* path,
    const sony2fuji_hdr_decode_options_v1* options, const sony2fuji_hdr_camera_development_v1* development,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic);
// 显式 ProRAW 路径，DNG SDK 显影配置 v2；PREVIEW 的 long_edge 为 1...2048。
// temporary_root 是现有可写缓存目录；成功、失败和取消均回收本次解码文件。
sony2fuji_status sony2fuji_hdr_probe_proraw(const char* path, sony2fuji_hdr_source_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_decode_proraw(sony2fuji_session* session, const char* path,
    const sony2fuji_hdr_decode_options_v1* options, const char* temporary_root,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic);
// 完整来源由原生后端分块读取；config 的路径和 SHA 必须对应冻结的原片。
sony2fuji_status sony2fuji_hdr_export_proraw(sony2fuji_session* session, const char* source_path,
    const sony2fuji_hdr_request_v1* request, const sony2fuji_hdr_export_config_v1* config,
    uint32_t keep_hdr, const char* temporary_root, const char* path,
    sony2fuji_hdr_stream_result_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic);
// 只计算已定向原片的几何输出尺寸，不解码或分配像素；失败时保留两个输出值。
sony2fuji_status sony2fuji_hdr_geometry_size(uint32_t native_width, uint32_t native_height,
    const sony2fuji_hdr_request_v1* request, uint32_t* width, uint32_t* height,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_render(sony2fuji_session* session, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_request_v1* request, sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
// 捕获几何调整后的 HDR，在自然饱和度之后、HSL/分级/外观之前取样。
// 使用 sony2fuji_hsl_probe_sample/destroy；RGB 为扩展线性 sRGB，
// hsl[2] 为有界坐标 Y/(1+Y)，不修改来源或渲染结果。
sony2fuji_status sony2fuji_hdr_create_hsl_probe(sony2fuji_session* session, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_request_v1* request, uint64_t source_revision, uint64_t request_revision,
    sony2fuji_hsl_probe** out_probe, sony2fuji_hdr_diagnostic_v1* diagnostic);
// 对长边不超过 2048 的源主图按相对白平衡测光，返回绝对曝光值。失败保留 exposure_ev。
sony2fuji_status sony2fuji_hdr_estimate_auto_exposure(const sony2fuji_hdr_image_pair_v1* source,
    float temperature, float tint, float* exposure_ev, sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_export_jpeg(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_export_config_v1* config, const char* path, sony2fuji_hdr_diagnostic_v1* diagnostic);
// Adaptive HDR HEIF with an 8-bit SDR primary image and ISO gain map.
// The same export config uses SONY2FUJI_HDR_METADATA_ISO for this container.
// Apple availability requires a successful in-memory encode and gain-map readback on the current runtime.
uint32_t sony2fuji_hdr_heif_export_available(void);
sony2fuji_status sony2fuji_hdr_export_heif(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_export_config_v1* config, const char* path, sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_export_sdr(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_sdr_export_config_v1* config, const char* path, sony2fuji_hdr_diagnostic_v1* diagnostic);
// 跨平台流式 JPEG 导出。keep_hdr=1 为 ISO/XMP HDR JPEG，0 为 sRGB SDR JPEG。
// config 必须指定冻结的原片路径和 SHA-256；temporary_root 必须是可写现有目录。
// 先颜色、后几何、再 resize，完整成功后才原子替换单个目标。失败清空 result 并保留旧目标。
// session 提供 CPU/GPU policy 和取消回调；codec 内取消延迟到其返回后、发布之前生效。
sony2fuji_status sony2fuji_hdr_export_stream(sony2fuji_session* session,
    const sony2fuji_hdr_stream_source_v1* source, const sony2fuji_hdr_request_v1* request,
    const sony2fuji_hdr_export_config_v1* config, uint32_t keep_hdr, const char* temporary_root,
    const char* path, sony2fuji_hdr_stream_result_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic);
void sony2fuji_hdr_release_pair(sony2fuji_hdr_image_pair_v1* image);

#ifdef __cplusplus
}
#endif
