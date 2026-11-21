#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace sony2fuji::ai {

struct DirectMLAdapter {
    int index = -1;
};

inline DirectMLAdapter findDirectMLAdapter(const std::string& = {}) {
    return {};
}

inline std::string directMLDevicesJSON() {
    return "{\"version\":1,\"devices\":[],\"recommended_id\":\"\"}";
}

} // namespace sony2fuji::ai
