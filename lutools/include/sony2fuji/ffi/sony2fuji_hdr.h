#pragma once

#include "sony2fuji_c.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SONY2FUJI_HDR_VERSION 1u
#define SONY2FUJI_HDR_PROCESSING_VERSION 1u

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
    SONY2FUJI_HDR_REASON_NOT_HDR = 16
};
enum {
    SONY2FUJI_HDR_FIELD_NONE = 0, SONY2FUJI_HDR_FIELD_SOURCE = 1,
    SONY2FUJI_HDR_FIELD_HDR_BUFFER = 2, SONY2FUJI_HDR_FIELD_SDR_BUFFER = 3,
    SONY2FUJI_HDR_FIELD_REQUEST = 4, SONY2FUJI_HDR_FIELD_RESULT = 5,
    SONY2FUJI_HDR_FIELD_SESSION = 6, SONY2FUJI_HDR_FIELD_PATH = 7,
    SONY2FUJI_HDR_FIELD_EXPORT = 8, SONY2FUJI_HDR_FIELD_DIAGNOSTIC = 9
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

typedef struct sony2fuji_hdr_decode_options_v1 {
    uint32_t version, struct_size;
    uint32_t intent, long_edge;
} sony2fuji_hdr_decode_options_v1;

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

enum { SONY2FUJI_HDR_METADATA_ISO_XMP = 1 };

// 所有结构先清零、填写 version=1/struct_size。请求温度默认 6500，crop 为 0/0/1/1。
// 输出必须为空；核心只写已知前缀，扩展尾部保持不变。调用方串行使用 session。
// 输入仅借用；输出不得修改 owner_token/内部指针或单独 free。release 可重复调用。
// probe 返回 UNSUPPORTED/NOT_HDR 才表示普通 JPEG/HEIF；损坏或不支持的 HDR 不能回落为 SDR 导入。
sony2fuji_status sony2fuji_hdr_probe(const char* path, sony2fuji_hdr_source_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_decode(const char* path, const sony2fuji_hdr_decode_options_v1* options,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic);
// 只计算已定向原片的几何输出尺寸，不解码或分配像素；失败时保留两个输出值。
sony2fuji_status sony2fuji_hdr_geometry_size(uint32_t native_width, uint32_t native_height,
    const sony2fuji_hdr_request_v1* request, uint32_t* width, uint32_t* height,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_render(sony2fuji_session* session, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_request_v1* request, sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_export_jpeg(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_export_config_v1* config, const char* path, sony2fuji_hdr_diagnostic_v1* diagnostic);
sony2fuji_status sony2fuji_hdr_export_sdr(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_sdr_export_config_v1* config, const char* path, sony2fuji_hdr_diagnostic_v1* diagnostic);
void sony2fuji_hdr_release_pair(sony2fuji_hdr_image_pair_v1* image);

#ifdef __cplusplus
}
#endif
