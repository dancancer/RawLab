#pragma once

#include "sony2fuji/raw_processor.h"

#include <cstdint>
#include <string>

namespace sony2fuji {

bool buildRawSourceIdentityKey(
    const char* inputPathStr,
    bool legacySonyCrop,
    std::string& outBaseKey
);

ProbeSizeResult probeInputHeaderSize(
    const char* inputPath,
    bool legacySonyCrop,
    X3fMode x3fMode,
    uint32_t& outWidth,
    uint32_t& outHeight
);

} // namespace sony2fuji
