#pragma once

#include "sony2fuji/ffi/sony2fuji_c.h"
#include "nlohmann/json.hpp"
#include <string>

namespace sony2fuji {

struct RawInfoResult {
    sony2fuji_status status = SONY2FUJI_STATUS_OK;
    std::string message;
    nlohmann::json result = nullptr;
};

// Identification metadata only: no unpack, demosaic or final-size prediction.
RawInfoResult inspectRawInfo(const std::string& absoluteUTF8Path);

} // namespace sony2fuji
