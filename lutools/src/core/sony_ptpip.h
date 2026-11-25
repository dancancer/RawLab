#pragma once

#include "sony2fuji/ffi/sony2fuji_c.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace sony2fuji::sony {

inline constexpr uint64_t kPtpipDataLimit = SONY2FUJI_SONY_PTPIP_DATA_LIMIT;
inline constexpr size_t kSlotDatesLimit = SONY2FUJI_SONY_SLOT_DATES_LIMIT;
inline constexpr uint64_t kTapFocusTimeoutMs = SONY2FUJI_SONY_TAP_FOCUS_TIMEOUT_MS;

struct DeviceInfo {
    std::string manufacturer;
    std::string model;
    std::string firmware;
    std::string serial;
    std::vector<uint16_t> operations;
};

struct RemoteDescriptor {
    uint16_t version = 0;
    int32_t enum_tables = 1;
    std::vector<uint16_t> properties;
    std::vector<uint16_t> controls;
};

struct PropertyEntry {
    sony2fuji_sony_property_info info{};
    std::string text_value;
    std::vector<int64_t> choices;
};

struct PropertyTable {
    std::vector<PropertyEntry> entries;
    const PropertyEntry* find(uint16_t code) const noexcept;
};

struct MobileAsset {
    sony2fuji_sony_mobile_asset_info info{};
    std::string name;
};

struct MobilePage {
    uint32_t entry_count = 0;
    uint64_t cursor = 0;
    std::vector<MobileAsset> assets;
};

struct LegacyObject {
    sony2fuji_sony_legacy_object_info info{};
    std::string name;
    std::string created;
    std::string modified;
};

// PTP/IP framing
sony2fuji_status buildInitCommand(
    const uint8_t* guid16,
    std::string_view client_name,
    uint32_t protocol_version,
    std::vector<uint8_t>& out_packet
);
sony2fuji_status buildInitEvent(uint32_t connection_number, std::vector<uint8_t>& out_packet);
sony2fuji_status buildOpRequest(
    uint32_t data_phase,
    uint16_t op_code,
    uint32_t transaction_id,
    const uint32_t* params,
    uint32_t param_count,
    std::vector<uint8_t>& out_packet
);
sony2fuji_status buildStartData(
    uint32_t transaction_id,
    uint64_t total_bytes,
    std::vector<uint8_t>& out_packet
);
sony2fuji_status buildEndData(
    uint32_t transaction_id,
    const uint8_t* payload,
    size_t payload_len,
    std::vector<uint8_t>& out_packet
);
sony2fuji_status buildProbeResponse(std::vector<uint8_t>& out_packet);

sony2fuji_status parsePtpipHeader(
    const uint8_t* header8,
    size_t len,
    uint64_t max_payload_bytes,
    sony2fuji_sony_ptpip_header& out_header
) noexcept;
sony2fuji_status parseInitCmdAck(
    const uint8_t* payload,
    size_t len,
    uint32_t& out_connection_number
) noexcept;
sony2fuji_status parseStartData(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_start_data& out_start
) noexcept;
sony2fuji_status parseResponse(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_response& out_resp
) noexcept;
sony2fuji_status parseEvent(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_event& out_evt
) noexcept;

// Validation & credentials
sony2fuji_status parseWifiCredential(
    const uint8_t* data,
    size_t len,
    bool is_password,
    std::string& out_value
);
bool isValidPhotoFilename(std::string_view name) noexcept;
bool isPhotoFilename(std::string_view name) noexcept;
bool validatePhotoHeader(std::string_view name, const uint8_t* prefix, size_t prefix_len) noexcept;

// 0x1001, 0x9202, 0x9209, 0x923b, 0x923c, 0x1008
sony2fuji_status parseDeviceInfo(const uint8_t* data, size_t len, DeviceInfo& out_info);
sony2fuji_status parseRemoteDescriptor(const uint8_t* data, size_t len, RemoteDescriptor& out_desc);
sony2fuji_status parseProperties(const uint8_t* data, size_t len, int32_t enum_tables, PropertyTable& out_table);

bool propertyAccepts(
    const sony2fuji_sony_property_info& info,
    const int64_t* choices,
    uint32_t choice_count,
    int64_t value
) noexcept;
sony2fuji_status propertyOptions(
    const sony2fuji_sony_property_info& info,
    const int64_t* choices,
    uint32_t choice_count,
    bool only_settable,
    bool sort_unique,
    uint32_t max_range_count,
    std::vector<int64_t>& out_values
);

void focusIndication(const PropertyTable* table, int32_t& out_locked, int32_t& out_failed) noexcept;
bool canCancelTouchFocus(
    const PropertyTable* table,
    const uint16_t* controls,
    uint32_t control_count,
    const uint16_t* operations,
    uint32_t operation_count,
    bool remote_ready
) noexcept;
sony2fuji_status resolveFocusTarget(
    const PropertyTable* table,
    const uint16_t* controls,
    uint32_t control_count,
    const uint16_t* operations,
    uint32_t operation_count,
    bool remote_ready,
    sony2fuji_sony_focus_target& out_target,
    sony2fuji_sony_focus_unavailable_reason& out_reason
) noexcept;

sony2fuji_status parseSlotPhotoCount(const uint8_t* data, size_t len, uint32_t& out_count) noexcept;
sony2fuji_status parseMobilePage(const uint8_t* data, size_t len, MobilePage& out_page);
sony2fuji_status parseLegacyObject(const uint8_t* data, size_t len, LegacyObject& out_obj);

// Live-view bounds, metadata & 640x480 projection
sony2fuji_status parseLiveFrameBounds(
    const uint32_t fields4[4],
    uint64_t max_total_bytes,
    sony2fuji_sony_live_frame_bounds& out_bounds
) noexcept;
sony2fuji_status parseLiveViewFrames(
    const uint8_t* metadata,
    size_t len,
    std::vector<sony2fuji_sony_live_view_frame>& out_frames
);

bool focusPointFromTap(
    double tap_x,
    double tap_y,
    double container_width,
    double container_height,
    double image_width,
    double image_height,
    sony2fuji_sony_focus_tap_point& out_tap
) noexcept;
sony2fuji_status focusOverlayBox(
    const sony2fuji_sony_live_view_frame& frame,
    double left,
    double top,
    double fitted_width,
    double fitted_height,
    sony2fuji_sony_focus_overlay_box& out_box
) noexcept;
bool normalizedFocusSquareRatio(
    const sony2fuji_sony_live_view_frame& frame,
    double image_width,
    double image_height,
    double& out_ratio
) noexcept;
sony2fuji_status tapFocusSide(
    double fitted_width,
    double fitted_height,
    double min_default_px,
    double max_default_px,
    double min_learned_px,
    bool has_last_ratio,
    double last_ratio,
    double& out_side
) noexcept;

// Virtual-clock focus state machine
bool isValidFocusState(const sony2fuji_sony_focus_state* state) noexcept;
sony2fuji_status focusStateInit(sony2fuji_sony_focus_state& state) noexcept;
sony2fuji_status focusStateReset(sony2fuji_sony_focus_state& state, bool preserve_last_ratio) noexcept;
sony2fuji_status focusStateOnTap(
    sony2fuji_sony_focus_state& state,
    double u,
    double v,
    int32_t x,
    int32_t y,
    uint64_t now_ms
) noexcept;
sony2fuji_status focusStateOnCancelStart(sony2fuji_sony_focus_state& state) noexcept;
sony2fuji_status focusStateOnFocusFinished(
    sony2fuji_sony_focus_state& state,
    bool succeeded,
    bool focus_locked,
    uint64_t now_ms
) noexcept;
sony2fuji_status focusStateOnLiveFrame(
    sony2fuji_sony_focus_state& state,
    const sony2fuji_sony_live_view_frame* frames,
    uint32_t frame_count,
    double image_width,
    double image_height
) noexcept;
sony2fuji_status focusStateOnProperties(
    sony2fuji_sony_focus_state& state,
    bool can_cancel_touch_focus,
    bool props_focus_locked,
    bool props_focus_failed
) noexcept;
sony2fuji_status focusStateOnCaptureOrParamStart(sony2fuji_sony_focus_state& state) noexcept;
sony2fuji_status focusStateOnLiveChanged(sony2fuji_sony_focus_state& state, bool live_active) noexcept;
sony2fuji_status focusStateOnTick(sony2fuji_sony_focus_state& state, uint64_t now_ms) noexcept;
sony2fuji_status focusStateOnTimeout(
    sony2fuji_sony_focus_state& state,
    uint64_t generation,
    uint64_t now_ms
) noexcept;
sony2fuji_status focusStateResolveRender(
    const sony2fuji_sony_focus_state& state,
    double left,
    double top,
    double fitted_width,
    double fitted_height,
    double min_default_px,
    double max_default_px,
    double min_learned_px,
    sony2fuji_sony_focus_render_decision& out_decision
) noexcept;

} // namespace sony2fuji::sony
