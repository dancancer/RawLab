#pragma once
#include "../../third_party/nlohmann/json.hpp"
#include <set>
#include <stdexcept>

namespace sony2fuji {
inline nlohmann::json parseLUTJSON(const std::string& text) {
    bool duplicate = false;
    std::vector<std::set<std::string>> objects;
    auto value = nlohmann::json::parse(text, [&](int, nlohmann::json::parse_event_t event, nlohmann::json& item) {
        using Event = nlohmann::json::parse_event_t;
        if (event == Event::object_start) objects.emplace_back();
        else if (event == Event::object_end) objects.pop_back();
        else if (event == Event::key && !objects.back().insert(item.get<std::string>()).second) duplicate = true;
        return true;
    });
    if (duplicate) throw std::invalid_argument("Duplicate LUT metadata fields");
    return value;
}
}
