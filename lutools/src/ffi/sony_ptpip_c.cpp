#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/sony_ptpip.h"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <string>
#include <vector>

struct sony2fuji_sony_device_info {
    sony2fuji::sony::DeviceInfo inner;
};

struct sony2fuji_sony_remote_descriptor {
    sony2fuji::sony::RemoteDescriptor inner;
};

struct sony2fuji_sony_property_table {
    sony2fuji::sony::PropertyTable inner;
};

struct sony2fuji_sony_mobile_page {
    sony2fuji::sony::MobilePage inner;
};

struct sony2fuji_sony_legacy_object {
    sony2fuji::sony::LegacyObject inner;
};

namespace {

static_assert(sizeof(sony2fuji_sony_ptpip_header) == 8, "ptpip_header size");
static_assert(offsetof(sony2fuji_sony_ptpip_header, packet_type) == 0, "ptpip_header.packet_type");
static_assert(offsetof(sony2fuji_sony_ptpip_header, payload_size) == 4, "ptpip_header.payload_size");

static_assert(sizeof(sony2fuji_sony_ptpip_start_data) == 16, "ptpip_start_data size");
static_assert(offsetof(sony2fuji_sony_ptpip_start_data, transaction_id) == 0, "ptpip_start_data.transaction_id");
static_assert(offsetof(sony2fuji_sony_ptpip_start_data, reserved0) == 4, "ptpip_start_data.reserved0");
static_assert(offsetof(sony2fuji_sony_ptpip_start_data, total_bytes) == 8, "ptpip_start_data.total_bytes");

static_assert(sizeof(sony2fuji_sony_ptpip_response) == 32, "ptpip_response size");
static_assert(offsetof(sony2fuji_sony_ptpip_response, response_code) == 0, "ptpip_response.response_code");
static_assert(offsetof(sony2fuji_sony_ptpip_response, reserved0) == 2, "ptpip_response.reserved0");
static_assert(offsetof(sony2fuji_sony_ptpip_response, transaction_id) == 4, "ptpip_response.transaction_id");
static_assert(offsetof(sony2fuji_sony_ptpip_response, param_count) == 8, "ptpip_response.param_count");
static_assert(offsetof(sony2fuji_sony_ptpip_response, params) == 12, "ptpip_response.params");

static_assert(sizeof(sony2fuji_sony_ptpip_event) == 24, "ptpip_event size");
static_assert(offsetof(sony2fuji_sony_ptpip_event, event_code) == 0, "ptpip_event.event_code");
static_assert(offsetof(sony2fuji_sony_ptpip_event, reserved0) == 2, "ptpip_event.reserved0");
static_assert(offsetof(sony2fuji_sony_ptpip_event, transaction_id) == 4, "ptpip_event.transaction_id");
static_assert(offsetof(sony2fuji_sony_ptpip_event, param_count) == 8, "ptpip_event.param_count");
static_assert(offsetof(sony2fuji_sony_ptpip_event, params) == 12, "ptpip_event.params");

static_assert(sizeof(sony2fuji_sony_property_info) == 56, "property_info size");
static_assert(offsetof(sony2fuji_sony_property_info, code) == 0, "property_info.code");
static_assert(offsetof(sony2fuji_sony_property_info, type) == 2, "property_info.type");
static_assert(offsetof(sony2fuji_sony_property_info, writable) == 4, "property_info.writable");
static_assert(offsetof(sony2fuji_sony_property_info, enabled) == 8, "property_info.enabled");
static_assert(offsetof(sony2fuji_sony_property_info, form) == 9, "property_info.form");
static_assert(offsetof(sony2fuji_sony_property_info, reserved0) == 10, "property_info.reserved0");
static_assert(offsetof(sony2fuji_sony_property_info, value_kind) == 12, "property_info.value_kind");
static_assert(offsetof(sony2fuji_sony_property_info, number_value) == 16, "property_info.number_value");
static_assert(offsetof(sony2fuji_sony_property_info, has_range) == 24, "property_info.has_range");
static_assert(offsetof(sony2fuji_sony_property_info, choice_count) == 28, "property_info.choice_count");
static_assert(offsetof(sony2fuji_sony_property_info, minimum) == 32, "property_info.minimum");
static_assert(offsetof(sony2fuji_sony_property_info, maximum) == 40, "property_info.maximum");
static_assert(offsetof(sony2fuji_sony_property_info, step) == 48, "property_info.step");

static_assert(sizeof(sony2fuji_sony_mobile_asset_info) == 24, "mobile_asset_info size");
static_assert(offsetof(sony2fuji_sony_mobile_asset_info, content) == 0, "mobile_asset_info.content");
static_assert(offsetof(sony2fuji_sony_mobile_asset_info, file) == 4, "mobile_asset_info.file");
static_assert(offsetof(sony2fuji_sony_mobile_asset_info, size) == 8, "mobile_asset_info.size");
static_assert(offsetof(sony2fuji_sony_mobile_asset_info, created) == 16, "mobile_asset_info.created");

static_assert(sizeof(sony2fuji_sony_legacy_object_info) == 16, "legacy_object_info size");
static_assert(offsetof(sony2fuji_sony_legacy_object_info, storage) == 0, "legacy_object_info.storage");
static_assert(offsetof(sony2fuji_sony_legacy_object_info, format) == 4, "legacy_object_info.format");
static_assert(offsetof(sony2fuji_sony_legacy_object_info, reserved0) == 6, "legacy_object_info.reserved0");
static_assert(offsetof(sony2fuji_sony_legacy_object_info, size) == 8, "legacy_object_info.size");

static_assert(sizeof(sony2fuji_sony_live_frame_bounds) == 24, "live_frame_bounds size");
static_assert(offsetof(sony2fuji_sony_live_frame_bounds, body_size) == 0, "live_frame_bounds.body_size");
static_assert(offsetof(sony2fuji_sony_live_frame_bounds, image_offset) == 4, "live_frame_bounds.image_offset");
static_assert(offsetof(sony2fuji_sony_live_frame_bounds, image_length) == 8, "live_frame_bounds.image_length");
static_assert(offsetof(sony2fuji_sony_live_frame_bounds, metadata_offset) == 12, "live_frame_bounds.metadata_offset");
static_assert(offsetof(sony2fuji_sony_live_frame_bounds, metadata_length) == 16, "live_frame_bounds.metadata_length");
static_assert(offsetof(sony2fuji_sony_live_frame_bounds, has_metadata) == 20, "live_frame_bounds.has_metadata");

static_assert(sizeof(sony2fuji_sony_live_view_frame) == 40, "live_view_frame size");
static_assert(offsetof(sony2fuji_sony_live_view_frame, kind) == 0, "live_view_frame.kind");
static_assert(offsetof(sony2fuji_sony_live_view_frame, focused) == 4, "live_view_frame.focused");
static_assert(offsetof(sony2fuji_sony_live_view_frame, cx) == 8, "live_view_frame.cx");
static_assert(offsetof(sony2fuji_sony_live_view_frame, cy) == 16, "live_view_frame.cy");
static_assert(offsetof(sony2fuji_sony_live_view_frame, width) == 24, "live_view_frame.width");
static_assert(offsetof(sony2fuji_sony_live_view_frame, height) == 32, "live_view_frame.height");

static_assert(sizeof(sony2fuji_sony_focus_tap_point) == 32, "focus_tap_point size");
static_assert(offsetof(sony2fuji_sony_focus_tap_point, u) == 0, "focus_tap_point.u");
static_assert(offsetof(sony2fuji_sony_focus_tap_point, v) == 8, "focus_tap_point.v");
static_assert(offsetof(sony2fuji_sony_focus_tap_point, x) == 16, "focus_tap_point.x");
static_assert(offsetof(sony2fuji_sony_focus_tap_point, y) == 20, "focus_tap_point.y");
static_assert(offsetof(sony2fuji_sony_focus_tap_point, packed) == 24, "focus_tap_point.packed");
static_assert(offsetof(sony2fuji_sony_focus_tap_point, reserved0) == 28, "focus_tap_point.reserved0");

static_assert(sizeof(sony2fuji_sony_focus_overlay_box) == 40, "focus_overlay_box size");
static_assert(offsetof(sony2fuji_sony_focus_overlay_box, x) == 0, "focus_overlay_box.x");
static_assert(offsetof(sony2fuji_sony_focus_overlay_box, y) == 8, "focus_overlay_box.y");
static_assert(offsetof(sony2fuji_sony_focus_overlay_box, width) == 16, "focus_overlay_box.width");
static_assert(offsetof(sony2fuji_sony_focus_overlay_box, height) == 24, "focus_overlay_box.height");
static_assert(offsetof(sony2fuji_sony_focus_overlay_box, is_normalized_square) == 32, "focus_overlay_box.is_normalized_square");
static_assert(offsetof(sony2fuji_sony_focus_overlay_box, focused) == 36, "focus_overlay_box.focused");

static_assert(sizeof(sony2fuji_sony_focus_state) == 88, "focus_state size");
static_assert(offsetof(sony2fuji_sony_focus_state, version) == 0, "focus_state.version");
static_assert(offsetof(sony2fuji_sony_focus_state, struct_size) == 4, "focus_state.struct_size");
static_assert(offsetof(sony2fuji_sony_focus_state, focus_busy) == 8, "focus_state.focus_busy");
static_assert(offsetof(sony2fuji_sony_focus_state, tap_active) == 12, "focus_state.tap_active");
static_assert(offsetof(sony2fuji_sony_focus_state, tap_generation) == 16, "focus_state.tap_generation");
static_assert(offsetof(sony2fuji_sony_focus_state, tap_u) == 24, "focus_state.tap_u");
static_assert(offsetof(sony2fuji_sony_focus_state, tap_v) == 32, "focus_state.tap_v");
static_assert(offsetof(sony2fuji_sony_focus_state, tap_x) == 40, "focus_state.tap_x");
static_assert(offsetof(sony2fuji_sony_focus_state, tap_y) == 44, "focus_state.tap_y");
static_assert(offsetof(sony2fuji_sony_focus_state, tap_deadline_ms) == 48, "focus_state.tap_deadline_ms");
static_assert(offsetof(sony2fuji_sony_focus_state, tap_focus_locked) == 56, "focus_state.tap_focus_locked");
static_assert(offsetof(sony2fuji_sony_focus_state, props_focus_locked) == 60, "focus_state.props_focus_locked");
static_assert(offsetof(sony2fuji_sony_focus_state, can_cancel_touch_focus) == 64, "focus_state.can_cancel_touch_focus");
static_assert(offsetof(sony2fuji_sony_focus_state, has_live_frames) == 68, "focus_state.has_live_frames");
static_assert(offsetof(sony2fuji_sony_focus_state, has_last_square_ratio) == 72, "focus_state.has_last_square_ratio");
static_assert(offsetof(sony2fuji_sony_focus_state, has_pending_deadline) == 76, "focus_state.has_pending_deadline");
static_assert(offsetof(sony2fuji_sony_focus_state, last_square_ratio) == 80, "focus_state.last_square_ratio");

static_assert(sizeof(sony2fuji_sony_focus_render_decision) == 48, "focus_render_decision size");
static_assert(offsetof(sony2fuji_sony_focus_render_decision, mode) == 0, "focus_render_decision.mode");
static_assert(offsetof(sony2fuji_sony_focus_render_decision, effective_focus_locked) == 4, "focus_render_decision.effective_focus_locked");
static_assert(offsetof(sony2fuji_sony_focus_render_decision, tap_box) == 8, "focus_render_decision.tap_box");

sony2fuji_status writeByteVector(
    const std::vector<uint8_t>& bytes,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
) noexcept {
    if (!out_len) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *out_len = bytes.size();
    if (!out_buf) {
        return capacity == 0 ? SONY2FUJI_STATUS_OK : SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (capacity < bytes.size()) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (!bytes.empty()) {
        std::memcpy(out_buf, bytes.data(), bytes.size());
    }
    return SONY2FUJI_STATUS_OK;
}

template <typename T>
sony2fuji_status writeTypedVector(
    const std::vector<T>& items,
    T* out_items,
    uint32_t capacity,
    uint32_t* out_count
) noexcept {
    if (!out_count) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (items.size() > std::numeric_limits<uint32_t>::max()) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const uint32_t total = static_cast<uint32_t>(items.size());
    *out_count = total;
    if (!out_items) {
        return capacity == 0 ? SONY2FUJI_STATUS_OK : SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (capacity < total) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (total > 0) {
        std::memcpy(out_items, items.data(), static_cast<size_t>(total) * sizeof(T));
    }
    return SONY2FUJI_STATUS_OK;
}

} // namespace

extern "C" {

sony2fuji_status sony2fuji_sony_ptpip_build_init_cmd(
    const uint8_t* guid16,
    const char* client_name,
    uint32_t protocol_version,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
) {
    if (out_len) *out_len = 0;
    if (!guid16 || !client_name || !out_len) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        std::vector<uint8_t> pkt;
        const sony2fuji_status st = sony2fuji::sony::buildInitCommand(guid16, client_name, protocol_version, pkt);
        if (st != SONY2FUJI_STATUS_OK) return st;
        return writeByteVector(pkt, out_buf, capacity, out_len);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_sony_ptpip_build_init_evt(
    uint32_t connection_number,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
) {
    if (out_len) *out_len = 0;
    if (!out_len) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        std::vector<uint8_t> pkt;
        const sony2fuji_status st = sony2fuji::sony::buildInitEvent(connection_number, pkt);
        if (st != SONY2FUJI_STATUS_OK) return st;
        return writeByteVector(pkt, out_buf, capacity, out_len);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_sony_ptpip_build_op_req(
    uint32_t data_phase,
    uint16_t op_code,
    uint32_t transaction_id,
    const uint32_t* params,
    uint32_t param_count,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
) {
    if (out_len) *out_len = 0;
    if (!out_len) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        std::vector<uint8_t> pkt;
        const sony2fuji_status st = sony2fuji::sony::buildOpRequest(
            data_phase, op_code, transaction_id, params, param_count, pkt);
        if (st != SONY2FUJI_STATUS_OK) return st;
        return writeByteVector(pkt, out_buf, capacity, out_len);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_sony_ptpip_build_start_data(
    uint32_t transaction_id,
    uint64_t total_bytes,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
) {
    if (out_len) *out_len = 0;
    if (!out_len) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        std::vector<uint8_t> pkt;
        const sony2fuji_status st = sony2fuji::sony::buildStartData(transaction_id, total_bytes, pkt);
        if (st != SONY2FUJI_STATUS_OK) return st;
        return writeByteVector(pkt, out_buf, capacity, out_len);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_sony_ptpip_build_end_data(
    uint32_t transaction_id,
    const uint8_t* payload,
    size_t payload_len,
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
) {
    if (out_len) *out_len = 0;
    if (!out_len) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        std::vector<uint8_t> pkt;
        const sony2fuji_status st = sony2fuji::sony::buildEndData(transaction_id, payload, payload_len, pkt);
        if (st != SONY2FUJI_STATUS_OK) return st;
        return writeByteVector(pkt, out_buf, capacity, out_len);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_sony_ptpip_build_probe_resp(
    uint8_t* out_buf,
    size_t capacity,
    size_t* out_len
) {
    if (out_len) *out_len = 0;
    if (!out_len) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        std::vector<uint8_t> pkt;
        const sony2fuji_status st = sony2fuji::sony::buildProbeResponse(pkt);
        if (st != SONY2FUJI_STATUS_OK) return st;
        return writeByteVector(pkt, out_buf, capacity, out_len);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_sony_ptpip_parse_header(
    const uint8_t* header8,
    size_t len,
    uint64_t max_payload_bytes,
    sony2fuji_sony_ptpip_header* out_header
) {
    if (!out_header) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::parsePtpipHeader(header8, len, max_payload_bytes, *out_header);
}

sony2fuji_status sony2fuji_sony_ptpip_parse_init_cmd_ack(
    const uint8_t* payload,
    size_t len,
    uint32_t* out_connection_number
) {
    if (!out_connection_number) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::parseInitCmdAck(payload, len, *out_connection_number);
}

sony2fuji_status sony2fuji_sony_ptpip_parse_start_data(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_start_data* out_start
) {
    if (!out_start) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::parseStartData(payload, len, *out_start);
}

sony2fuji_status sony2fuji_sony_ptpip_parse_response(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_response* out_resp
) {
    if (!out_resp) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::parseResponse(payload, len, *out_resp);
}

sony2fuji_status sony2fuji_sony_ptpip_parse_event(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_event* out_evt
) {
    if (!out_evt) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::parseEvent(payload, len, *out_evt);
}

sony2fuji_status sony2fuji_sony_parse_wifi_credential(
    const uint8_t* data,
    size_t len,
    int32_t is_password,
    char* out_buf,
    size_t capacity,
    size_t* out_len
) {
    if (out_len) *out_len = 0;
    if (!out_len) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        std::string value;
        const sony2fuji_status st = sony2fuji::sony::parseWifiCredential(data, len, is_password != 0, value);
        if (st != SONY2FUJI_STATUS_OK) return st;
        *out_len = value.size();
        if (!out_buf) {
            return capacity == 0 ? SONY2FUJI_STATUS_OK : SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        if (capacity < value.size() + 1u) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        std::memcpy(out_buf, value.data(), value.size());
        out_buf[value.size()] = '\0';
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

int32_t sony2fuji_sony_is_valid_photo_filename(const char* name) {
    if (!name) return 0;
    return sony2fuji::sony::isValidPhotoFilename(name) ? 1 : 0;
}

int32_t sony2fuji_sony_is_photo_filename(const char* name) {
    if (!name) return 0;
    return sony2fuji::sony::isPhotoFilename(name) ? 1 : 0;
}

int32_t sony2fuji_sony_validate_photo_header(
    const char* name,
    const uint8_t* prefix,
    size_t prefix_len
) {
    if (!name || !prefix) return 0;
    return sony2fuji::sony::validatePhotoHeader(name, prefix, prefix_len) ? 1 : 0;
}

sony2fuji_status sony2fuji_sony_parse_device_info(
    const uint8_t* data,
    size_t len,
    sony2fuji_sony_device_info** out_info
) {
    if (out_info) *out_info = nullptr;
    if (!out_info || (!data && len > 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        sony2fuji::sony::DeviceInfo parsed;
        const sony2fuji_status st = sony2fuji::sony::parseDeviceInfo(data, len, parsed);
        if (st != SONY2FUJI_STATUS_OK) return st;
        *out_info = new sony2fuji_sony_device_info{std::move(parsed)};
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

void sony2fuji_sony_device_info_free(sony2fuji_sony_device_info* info) {
    delete info;
}

const char* sony2fuji_sony_device_info_manufacturer(const sony2fuji_sony_device_info* info) {
    return info ? info->inner.manufacturer.c_str() : "";
}

const char* sony2fuji_sony_device_info_model(const sony2fuji_sony_device_info* info) {
    return info ? info->inner.model.c_str() : "";
}

const char* sony2fuji_sony_device_info_firmware(const sony2fuji_sony_device_info* info) {
    return info ? info->inner.firmware.c_str() : "";
}

const char* sony2fuji_sony_device_info_serial(const sony2fuji_sony_device_info* info) {
    return info ? info->inner.serial.c_str() : "";
}

sony2fuji_status sony2fuji_sony_device_info_operations(
    const sony2fuji_sony_device_info* info,
    uint16_t* out_ops,
    uint32_t capacity,
    uint32_t* out_count
) {
    if (out_count) *out_count = 0;
    if (!info || !out_count) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return writeTypedVector(info->inner.operations, out_ops, capacity, out_count);
}

sony2fuji_status sony2fuji_sony_parse_remote_descriptor(
    const uint8_t* data,
    size_t len,
    uint16_t* out_version,
    int32_t* out_enum_tables,
    sony2fuji_sony_remote_descriptor** out_desc
) {
    if (out_version) *out_version = 0;
    if (out_enum_tables) *out_enum_tables = 0;
    if (out_desc) *out_desc = nullptr;
    if (!out_version || !out_enum_tables || !out_desc || (!data && len > 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        sony2fuji::sony::RemoteDescriptor parsed;
        const sony2fuji_status st = sony2fuji::sony::parseRemoteDescriptor(data, len, parsed);
        if (st != SONY2FUJI_STATUS_OK) return st;
        *out_version = parsed.version;
        *out_enum_tables = parsed.enum_tables;
        *out_desc = new sony2fuji_sony_remote_descriptor{std::move(parsed)};
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

void sony2fuji_sony_remote_descriptor_free(sony2fuji_sony_remote_descriptor* desc) {
    delete desc;
}

sony2fuji_status sony2fuji_sony_remote_descriptor_properties(
    const sony2fuji_sony_remote_descriptor* desc,
    uint16_t* out_props,
    uint32_t capacity,
    uint32_t* out_count
) {
    if (out_count) *out_count = 0;
    if (!desc || !out_count) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return writeTypedVector(desc->inner.properties, out_props, capacity, out_count);
}

sony2fuji_status sony2fuji_sony_remote_descriptor_controls(
    const sony2fuji_sony_remote_descriptor* desc,
    uint16_t* out_controls,
    uint32_t capacity,
    uint32_t* out_count
) {
    if (out_count) *out_count = 0;
    if (!desc || !out_count) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return writeTypedVector(desc->inner.controls, out_controls, capacity, out_count);
}

sony2fuji_status sony2fuji_sony_parse_properties(
    const uint8_t* data,
    size_t len,
    int32_t enum_tables,
    sony2fuji_sony_property_table** out_table
) {
    if (out_table) *out_table = nullptr;
    if (!out_table || (!data && len > 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        sony2fuji::sony::PropertyTable parsed;
        const sony2fuji_status st = sony2fuji::sony::parseProperties(data, len, enum_tables, parsed);
        if (st != SONY2FUJI_STATUS_OK) return st;
        *out_table = new sony2fuji_sony_property_table{std::move(parsed)};
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

void sony2fuji_sony_property_table_free(sony2fuji_sony_property_table* table) {
    delete table;
}

uint32_t sony2fuji_sony_property_table_count(const sony2fuji_sony_property_table* table) {
    if (!table) return 0;
    return static_cast<uint32_t>(table->inner.entries.size());
}

sony2fuji_status sony2fuji_sony_property_table_get_at(
    const sony2fuji_sony_property_table* table,
    uint32_t index,
    sony2fuji_sony_property_info* out_info
) {
    if (out_info) *out_info = {};
    if (!table || !out_info || index >= table->inner.entries.size()) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *out_info = table->inner.entries[index].info;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_sony_property_table_find(
    const sony2fuji_sony_property_table* table,
    uint16_t code,
    sony2fuji_sony_property_info* out_info
) {
    if (out_info) *out_info = {};
    if (!table || !out_info) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const sony2fuji::sony::PropertyEntry* found = table->inner.find(code);
    if (!found) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }
    *out_info = found->info;
    return SONY2FUJI_STATUS_OK;
}

const char* sony2fuji_sony_property_table_text_at(
    const sony2fuji_sony_property_table* table,
    uint32_t index
) {
    if (!table || index >= table->inner.entries.size()) {
        return "";
    }
    const auto& entry = table->inner.entries[index];
    if (entry.info.value_kind != SONY2FUJI_SONY_PROP_TEXT) {
        return "";
    }
    return entry.text_value.c_str();
}

sony2fuji_status sony2fuji_sony_property_table_choices_at(
    const sony2fuji_sony_property_table* table,
    uint32_t index,
    int64_t* out_choices,
    uint32_t capacity,
    uint32_t* out_count
) {
    if (out_count) *out_count = 0;
    if (!table || !out_count || index >= table->inner.entries.size()) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return writeTypedVector(table->inner.entries[index].choices, out_choices, capacity, out_count);
}

int32_t sony2fuji_sony_property_accepts(
    const sony2fuji_sony_property_info* info,
    const int64_t* choices,
    uint32_t choice_count,
    int64_t value
) {
    if (!info) return 0;
    return sony2fuji::sony::propertyAccepts(*info, choices, choice_count, value) ? 1 : 0;
}

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
) {
    if (out_count) *out_count = 0;
    if (!info || !out_count) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        std::vector<int64_t> values;
        const sony2fuji_status st = sony2fuji::sony::propertyOptions(
            *info, choices, choice_count, only_settable != 0, sort_unique != 0, max_range_count, values);
        if (st != SONY2FUJI_STATUS_OK) return st;
        return writeTypedVector(values, out_values, capacity, out_count);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

void sony2fuji_sony_property_table_focus_indication(
    const sony2fuji_sony_property_table* table,
    int32_t* out_locked,
    int32_t* out_failed
) {
    int32_t locked = 0;
    int32_t failed = 0;
    sony2fuji::sony::focusIndication(table ? &table->inner : nullptr, locked, failed);
    if (out_locked) *out_locked = locked;
    if (out_failed) *out_failed = failed;
}

int32_t sony2fuji_sony_property_table_can_cancel_touch_focus(
    const sony2fuji_sony_property_table* table,
    const uint16_t* controls,
    uint32_t control_count,
    const uint16_t* operations,
    uint32_t operation_count,
    int32_t remote_ready
) {
    return sony2fuji::sony::canCancelTouchFocus(
               table ? &table->inner : nullptr, controls, control_count, operations, operation_count, remote_ready != 0)
               ? 1
               : 0;
}

sony2fuji_status sony2fuji_sony_property_table_resolve_focus_target(
    const sony2fuji_sony_property_table* table,
    const uint16_t* controls,
    uint32_t control_count,
    const uint16_t* operations,
    uint32_t operation_count,
    int32_t remote_ready,
    sony2fuji_sony_focus_target* out_target,
    sony2fuji_sony_focus_unavailable_reason* out_reason
) {
    if (!out_target || !out_reason) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::resolveFocusTarget(
        table ? &table->inner : nullptr,
        controls,
        control_count,
        operations,
        operation_count,
        remote_ready != 0,
        *out_target,
        *out_reason);
}

sony2fuji_status sony2fuji_sony_parse_slot_photo_count(
    const uint8_t* data,
    size_t len,
    uint32_t* out_count
) {
    if (!out_count) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::parseSlotPhotoCount(data, len, *out_count);
}

sony2fuji_status sony2fuji_sony_parse_mobile_page(
    const uint8_t* data,
    size_t len,
    sony2fuji_sony_mobile_page** out_page
) {
    if (out_page) *out_page = nullptr;
    if (!out_page || (!data && len > 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        sony2fuji::sony::MobilePage parsed;
        const sony2fuji_status st = sony2fuji::sony::parseMobilePage(data, len, parsed);
        if (st != SONY2FUJI_STATUS_OK) return st;
        *out_page = new sony2fuji_sony_mobile_page{std::move(parsed)};
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

void sony2fuji_sony_mobile_page_free(sony2fuji_sony_mobile_page* page) {
    delete page;
}

uint32_t sony2fuji_sony_mobile_page_entry_count(const sony2fuji_sony_mobile_page* page) {
    return page ? page->inner.entry_count : 0;
}

uint64_t sony2fuji_sony_mobile_page_cursor(const sony2fuji_sony_mobile_page* page) {
    return page ? page->inner.cursor : 0;
}

uint32_t sony2fuji_sony_mobile_page_asset_count(const sony2fuji_sony_mobile_page* page) {
    return page ? static_cast<uint32_t>(page->inner.assets.size()) : 0;
}

sony2fuji_status sony2fuji_sony_mobile_page_asset_at(
    const sony2fuji_sony_mobile_page* page,
    uint32_t index,
    sony2fuji_sony_mobile_asset_info* out_info,
    const char** out_name
) {
    if (out_info) *out_info = {};
    if (out_name) *out_name = "";
    if (!page || !out_info || !out_name || index >= page->inner.assets.size()) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const auto& asset = page->inner.assets[index];
    *out_info = asset.info;
    *out_name = asset.name.c_str();
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_sony_parse_legacy_object(
    const uint8_t* data,
    size_t len,
    sony2fuji_sony_legacy_object** out_obj
) {
    if (out_obj) *out_obj = nullptr;
    if (!out_obj || (!data && len > 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        sony2fuji::sony::LegacyObject parsed;
        const sony2fuji_status st = sony2fuji::sony::parseLegacyObject(data, len, parsed);
        if (st != SONY2FUJI_STATUS_OK) return st;
        *out_obj = new sony2fuji_sony_legacy_object{std::move(parsed)};
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

void sony2fuji_sony_legacy_object_free(sony2fuji_sony_legacy_object* obj) {
    delete obj;
}

sony2fuji_status sony2fuji_sony_legacy_object_get(
    const sony2fuji_sony_legacy_object* obj,
    sony2fuji_sony_legacy_object_info* out_info,
    const char** out_name,
    const char** out_created,
    const char** out_modified
) {
    if (out_info) *out_info = {};
    if (out_name) *out_name = "";
    if (out_created) *out_created = "";
    if (out_modified) *out_modified = "";
    if (!obj || !out_info || !out_name || !out_created || !out_modified) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *out_info = obj->inner.info;
    *out_name = obj->inner.name.c_str();
    *out_created = obj->inner.created.c_str();
    *out_modified = obj->inner.modified.c_str();
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_sony_parse_live_frame_bounds(
    const uint32_t fields4[4],
    uint64_t max_total_bytes,
    sony2fuji_sony_live_frame_bounds* out_bounds
) {
    if (!out_bounds) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::parseLiveFrameBounds(fields4, max_total_bytes, *out_bounds);
}

sony2fuji_status sony2fuji_sony_parse_live_view_frames(
    const uint8_t* metadata,
    size_t len,
    sony2fuji_sony_live_view_frame* out_frames,
    uint32_t capacity,
    uint32_t* out_count
) {
    if (out_count) *out_count = 0;
    if (!out_count) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        std::vector<sony2fuji_sony_live_view_frame> frames;
        const sony2fuji_status st = sony2fuji::sony::parseLiveViewFrames(metadata, len, frames);
        if (st != SONY2FUJI_STATUS_OK) return st;
        return writeTypedVector(frames, out_frames, capacity, out_count);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_sony_focus_point_from_tap(
    double tap_x,
    double tap_y,
    double container_width,
    double container_height,
    double image_width,
    double image_height,
    int32_t* out_valid,
    sony2fuji_sony_focus_tap_point* out_tap
) {
    if (out_valid) *out_valid = 0;
    if (out_tap) *out_tap = {};
    if (!out_valid || !out_tap) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji_sony_focus_tap_point tap{};
    const bool valid = sony2fuji::sony::focusPointFromTap(
        tap_x, tap_y, container_width, container_height, image_width, image_height, tap);
    *out_valid = valid ? 1 : 0;
    if (valid) {
        *out_tap = tap;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_sony_compute_focus_overlay_box(
    const sony2fuji_sony_live_view_frame* frame,
    double left,
    double top,
    double fitted_width,
    double fitted_height,
    sony2fuji_sony_focus_overlay_box* out_box
) {
    if (!frame || !out_box) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::focusOverlayBox(*frame, left, top, fitted_width, fitted_height, *out_box);
}

sony2fuji_status sony2fuji_sony_normalized_focus_square_ratio(
    const sony2fuji_sony_live_view_frame* frame,
    double image_width,
    double image_height,
    int32_t* out_valid,
    double* out_ratio
) {
    if (out_valid) *out_valid = 0;
    if (out_ratio) *out_ratio = 0.0;
    if (!frame || !out_valid || !out_ratio) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    double ratio = 0.0;
    const bool valid = sony2fuji::sony::normalizedFocusSquareRatio(*frame, image_width, image_height, ratio);
    *out_valid = valid ? 1 : 0;
    if (valid) {
        *out_ratio = ratio;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_sony_tap_focus_side(
    double fitted_width,
    double fitted_height,
    double min_default_px,
    double max_default_px,
    double min_learned_px,
    int32_t has_last_ratio,
    double last_ratio,
    double* out_side
) {
    if (!out_side) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return sony2fuji::sony::tapFocusSide(
        fitted_width,
        fitted_height,
        min_default_px,
        max_default_px,
        min_learned_px,
        has_last_ratio != 0,
        last_ratio,
        *out_side);
}

sony2fuji_status sony2fuji_sony_focus_state_init(sony2fuji_sony_focus_state* state) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateInit(*state);
}

sony2fuji_status sony2fuji_sony_focus_state_reset(
    sony2fuji_sony_focus_state* state,
    int32_t preserve_last_ratio
) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateReset(*state, preserve_last_ratio != 0);
}

sony2fuji_status sony2fuji_sony_focus_state_on_tap(
    sony2fuji_sony_focus_state* state,
    double u,
    double v,
    int32_t x,
    int32_t y,
    uint64_t now_ms
) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateOnTap(*state, u, v, x, y, now_ms);
}

sony2fuji_status sony2fuji_sony_focus_state_on_cancel_start(sony2fuji_sony_focus_state* state) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateOnCancelStart(*state);
}

sony2fuji_status sony2fuji_sony_focus_state_on_focus_finished(
    sony2fuji_sony_focus_state* state,
    int32_t succeeded,
    int32_t focus_locked,
    uint64_t now_ms
) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateOnFocusFinished(*state, succeeded != 0, focus_locked != 0, now_ms);
}

sony2fuji_status sony2fuji_sony_focus_state_on_live_frame(
    sony2fuji_sony_focus_state* state,
    const sony2fuji_sony_live_view_frame* frames,
    uint32_t frame_count,
    double image_width,
    double image_height
) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateOnLiveFrame(*state, frames, frame_count, image_width, image_height);
}

sony2fuji_status sony2fuji_sony_focus_state_on_properties(
    sony2fuji_sony_focus_state* state,
    int32_t can_cancel_touch_focus,
    int32_t props_focus_locked,
    int32_t props_focus_failed
) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateOnProperties(
        *state, can_cancel_touch_focus != 0, props_focus_locked != 0, props_focus_failed != 0);
}

sony2fuji_status sony2fuji_sony_focus_state_on_capture_or_param_start(sony2fuji_sony_focus_state* state) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateOnCaptureOrParamStart(*state);
}

sony2fuji_status sony2fuji_sony_focus_state_on_live_changed(
    sony2fuji_sony_focus_state* state,
    int32_t live_active
) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateOnLiveChanged(*state, live_active != 0);
}

sony2fuji_status sony2fuji_sony_focus_state_on_tick(
    sony2fuji_sony_focus_state* state,
    uint64_t now_ms
) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateOnTick(*state, now_ms);
}

sony2fuji_status sony2fuji_sony_focus_state_on_timeout(
    sony2fuji_sony_focus_state* state,
    uint64_t generation,
    uint64_t now_ms
) {
    if (!state) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateOnTimeout(*state, generation, now_ms);
}

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
) {
    if (!state || !out_decision) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return sony2fuji::sony::focusStateResolveRender(
        *state,
        left,
        top,
        fitted_width,
        fitted_height,
        min_default_px,
        max_default_px,
        min_learned_px,
        *out_decision);
}

} // extern "C"
