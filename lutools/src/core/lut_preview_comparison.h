#pragma once
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <string>

namespace sony2fuji {
std::string compareLUTPreviews(const sony2fuji_buffer& candidate, const sony2fuji_buffer& reference,
    const std::string& conditions);
}
