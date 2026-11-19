#pragma once
#include "core/pixel_buffer.h"
#include <string>

namespace sony2fuji {
std::string compareLUTPreviews(const PixelBufferView& candidate, const PixelBufferView& reference,
    const std::string& conditions);
}
