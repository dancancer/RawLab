#pragma once
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <stdexcept>
#include <string>

namespace rawlab {

inline constexpr const char* kNeutralRecipeProbeParamsJson =
    "{\"schema_version\":5,"
    "\"processing\":{\"family\":\"rawlab\",\"version\":2,\"quality\":\"standard\"},"
    "\"input\":{\"path\":\"probe.raw\",\"type\":\"raw\"},"
    "\"edits\":{"
    "\"exposure\":{\"mode\":\"scene\",\"ev\":0.0,\"brightness\":1.0},"
    "\"white_balance\":{\"mode\":\"camera\"},"
    "\"look\":{\"path\":null,\"strength\":1.0},"
    "\"detail\":{\"sharpening\":0.0}},"
    "\"output\":{\"path\":\"probe.png\",\"format\":\"png\",\"size\":{\"mode\":\"native\"}}}";

class RecipeProbeStageScope {
    sony2fuji_session* session;
    std::string savedParamsJson;
    bool active = false;
public:
    RecipeProbeStageScope(sony2fuji_session* session, std::string savedParams)
        : session(session), savedParamsJson(std::move(savedParams)) {
        if (sony2fuji_apply_params(session, kNeutralRecipeProbeParamsJson) != SONY2FUJI_STATUS_OK) {
            throw std::runtime_error("Cannot clear recipe probe stages");
        }
        active = true;
    }
    RecipeProbeStageScope(const RecipeProbeStageScope&) = delete;
    RecipeProbeStageScope& operator=(const RecipeProbeStageScope&) = delete;
    ~RecipeProbeStageScope() noexcept {
        if (active && !savedParamsJson.empty()) {
            (void)sony2fuji_apply_params(session, savedParamsJson.c_str());
        }
    }
};

} // namespace rawlab
