#include "RawMetadataBridge.h"

#include <cstring>
#include <string>

#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/raw_processor.h"

RawDimensions rawlab_get_raw_dimensions(const char *path) {
    RawDimensions dims = {0, 0};
    if (!path || path[0] == '\0') {
        return dims;
    }

    // 冻结的 sony2fuji_c.h 尚无原生尺寸查询 ABI，先以 header-only inspectFile 避免完整像素解包。
    sony2fuji::RAWProcessor processor;
    sony2fuji::ErrorCode result = processor.inspectFile(std::string(path));
    if (result != sony2fuji::ErrorCode::Success) {
        return dims;
    }

    dims.width = static_cast<uint32_t>(processor.getWidth());
    dims.height = static_cast<uint32_t>(processor.getHeight());
    return dims;
}

RawFileKind rawlab_probe_raw_file(const char *path) {
    if (!path || path[0] == '\0') {
        return RAWLAB_FILE_NOT_RAW;
    }

    sony2fuji_session *session = nullptr;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK || !session) {
        return RAWLAB_FILE_NOT_RAW;
    }
    sony2fuji_lens_report report = {};
    uint32_t count = 0;
    const sony2fuji_status status = sony2fuji_session_inspect_lens(session, path, &report, nullptr, 0, &count);
    sony2fuji_session_destroy(session);
    if (status != SONY2FUJI_STATUS_OK) {
        return RAWLAB_FILE_NOT_RAW;
    }
    return std::strcmp(report.camera_make, "Sony") == 0 || std::strcmp(report.camera_make, "SONY") == 0
        ? RAWLAB_FILE_SONY_RAW : RAWLAB_FILE_RAW;
}
