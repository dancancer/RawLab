#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <array>
#include <cstdint>
#include <vector>

namespace sony2fuji {

struct ImageStats {
    std::array<uint32_t, 768> histogram{};
    uint32_t shadows = 0;
    uint32_t highlights = 0;
    std::vector<uint8_t> clipping;
};

bool computeImageStatsCPU(const sony2fuji_buffer& buffer, ImageStats& output, bool includeClipping = true);
bool computeImageStatsMetal(const sony2fuji_buffer& buffer, ImageStats& output);

} // namespace sony2fuji
